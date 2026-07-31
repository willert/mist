package App::Mist::Command::doctor;
# ABSTRACT: check the project for build pitfalls before they bite

use 5.010;

use App::Mist -command;

use Config;
use Module::CoreList;

use Mist::CPAN::PackageIndex ();

sub usage_desc { '%c doctor %o' }

sub opt_spec {
  return (
    [ 'for=s'     => 'check against this perl version (e.g. 5.38.2), from the bundled Module::CoreList' ],
    [ 'perl=s'    => 'check against this perl binary instead (default: /usr/bin/perl)' ],
    [ 'verbose|v' => 'list every module rather than grouping them' ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;

  # --for consults the bundled Module::CoreList, so a perl need not be installed
  # here to be asked about - which is the usual case: the box you are deploying
  # to is not the box you are on. --perl asks a real binary, for a perl the
  # bundled table does not know yet.
  my ( $target, $label );
  if ( my $spec = $opt->for ) {
    die "$0: --for and --perl are alternatives, not a pair\n" if $opt->perl;
    $label = $spec;
  } else {
    $target = $opt->perl || '/usr/bin/perl';
    die "$0: no such perl: $target\n" unless -x $target;
    $label = _version_of( $target );
  }

  my $found = 0;
  $found += _report_stale_bin_layout( $ctx );
  $found += _report_index_gaps( $ctx );
  $found += _report_unset_module_maker( $ctx );

  my @problems = _ex_core_gap( $ctx, $target, $opt->for );

  if ( not @problems ) {
    printf "No ex-core gap against perl %s.\n", $label unless $found;
    return;
  }

  printf <<'REPORT', scalar @problems, $Config{version}, $label;
%d module(s) are core in this project's perl (%s) but not in perl %s, and
are not vendored in mpan-dist. A build there would have to find them somewhere
else - which, without --system-perl's isolation, means silently binding to
whatever the distribution happens to package.

REPORT

  if ( $opt->verbose ) {
    print "  $_\n" for @problems;
  } else {
    # Grouped by top-level namespace: the raw list is dominated by families like
    # Locale::Codes, where 27 entries say one thing. -v prints them all.
    my %group;
    for my $module ( @problems ) {
      my ( $top ) = split /::/, $module;
      push @{ $group{ $top } }, $module;
    }
    for my $top ( sort keys %group ) {
      my @m = @{ $group{ $top } };
      printf "  %-14s %2d  %s%s\n", $top, scalar @m,
        join( ', ', @m[ 0 .. ( @m > 3 ? 2 : $#m ) ] ),
        ( @m > 3 ? ', ...' : '' );
    }
    print "\n  (--verbose lists them individually)\n";
  }

  print <<'ADVICE';

They are absent because a project pinned to an older perl never had to vendor
them: the installer filters out whatever that perl already provides, so the gap
stays invisible until something builds on a newer one. Populate the mirror by
building once against a perl of the target vintage - `./mpan-install
--perlbrew=<version>`, or `--build-only` to leave the live environment alone -
and commit what lands in mpan-dist.
ADVICE

  return;
}

# perl5/bin/mist-run is a symlink into a per-perl wrapper. A plain file there is
# the pre-per-perl layout, left behind because `mist upgrade` deliberately does
# not regenerate the bin/etc layer - so a project whose only recent installs went
# through upgrade can carry a wrapper years older than its generations.
sub _report_stale_bin_layout {
  my ( $ctx ) = @_;
  my $selector = $ctx->perl5_base_lib->file(qw/ bin mist-run /);
  return 0 unless -e "$selector";
  return 0 if -l "$selector";

  print <<"REPORT";
perl5/bin/mist-run is a plain file, not a selector symlink.

  That is the layout from before per-perl wrappers. It still works, but the
  wrapper predates whatever built the current generations, so it can be missing
  fixes they assume. `mist upgrade` does not regenerate this layer by design;
  a plain ./mpan-install does.

REPORT
  return 1;
}

# An index entry whose tarball is gone is real corruption: a build resolving that
# module would be told where to find something that is not there. Superseded
# tarballs with no entry are the opposite and are normal, so they are not
# reported - `mist index` already accounts for those after a reindex.
sub _report_index_gaps {
  my ( $ctx ) = @_;

  my $index = Mist::CPAN::PackageIndex->new({ cpan_dist_root => $ctx->mpan_dist });
  my $entries = eval { $index->package_index->entries->get_hash } or return 0;

  my $authors = $ctx->mpan_dist->subdir(qw/ authors id /);
  my ( %missing, %seen_path );
  for my $pkg ( keys %$entries ) {
    for my $version ( keys %{ $entries->{ $pkg } } ) {
      my $entry = $entries->{ $pkg }{ $version } or next;
      my $path  = eval { $entry->path } or next;
      next if $seen_path{ $path }++;
      $missing{ $path } = 1 unless -e $authors->file( split m{/}, $path )->stringify;
    }
  }
  return 0 unless %missing;

  printf "%d index entr%s point at a tarball that is not there:\n\n",
    scalar keys %missing, ( keys %missing == 1 ? 'y' : 'ies' );
  print "  $_\n" for sort keys %missing;
  print <<'REPORT';

  A build resolving one of these is sent to a file that does not exist. Re-run
  `mist index` to rebuild the index from what the mirror actually holds, and
  re-vendor anything that turns out to be genuinely missing.

REPORT
  return 1;
}

# ModuleBuildTiny installs only script/ and dies at regeneration if bin/ exists -
# mid-release, after the version bump. Only worth reporting when both halves are
# true: the maker was never chosen, and the project has the directories the
# default refuses.
sub _report_unset_module_maker {
  my ( $ctx ) = @_;

  my $minil = $ctx->project_root->file( 'minil.toml' );
  return 0 unless -f "$minil";
  return 0 if $minil->slurp =~ m{^\s*module_maker}m;

  my @script_dirs = grep { -d $ctx->project_root->subdir( $_ )->stringify }
                    qw/ bin sbin /;
  return 0 unless @script_dirs;

  printf <<'REPORT', join( '/ and ', @script_dirs );
minil.toml sets no module_maker, and this project has %s/.

  Minilla then defaults to ModuleBuildTiny, which installs only script/ and
  refuses outright when bin/ is present ("Module::Build::Tiny doesn't install
  bin/ directory"). It refuses at *regeneration*, which runs mid-release after
  the version bump - so the failure lands on whoever next cuts a release, with a
  dirty tree. Set `module_maker = "ExtUtilsMakeMaker"` and regenerate.

REPORT
  return 1;
}

# Modules core in the perl this project pins but not in $target_perl, minus
# whatever mpan-dist already vendors. mist runs under the pinned perl, so the
# near side is just this process; the far side has to be asked, because a perl's
# bundled Module::CoreList only knows perls up to its own release - the 5.20.3
# copy mist itself runs under stops at 5.23.2 and cannot answer for 5.38 at all.
sub _ex_core_gap {
  my ( $ctx, $target_perl, $version_spec ) = @_;

  my $here  = $Module::CoreList::version{ $] + 0 } || {};
  my %there = map { $_ => 1 } defined $version_spec
    ? _core_modules_for_version( $version_spec )
    : _core_modules_of( $target_perl );
  return () unless %there;   # nothing to compare against; say nothing

  my $vendored = _indexed_modules( $ctx );

  return sort grep { not $there{ $_ } and not $vendored->{ $_ } } keys %$here;
}

# From the bundled table rather than a live perl. Accepts the shapes people
# actually write - 5.38, 5.38.2, 5.038002 - and refuses loudly rather than
# reporting an empty gap, which would read as "all clear".
sub _core_modules_for_version {
  my ( $spec ) = @_;

  my $key = _corelist_key( $spec ) or die <<"UNKNOWN";
$0: Module::CoreList $Module::CoreList::VERSION does not know perl $spec.

It knows up to @{[ (sort { $a <=> $b } keys %Module::CoreList::version)[-1] ]}.
For a newer perl, point --perl at an actual binary instead, or update the
vendored Module::CoreList.
UNKNOWN

  return keys %{ $Module::CoreList::version{ $key } || {} };
}

sub _corelist_key {
  my ( $spec ) = @_;
  return undef unless defined $spec and length $spec;
  return $spec if exists $Module::CoreList::version{ $spec };

  my @part = grep { length } split /[._v]+/, $spec;
  return undef unless @part >= 2;
  my $key = sprintf '%d.%03d%03d', $part[0], $part[1], ( $part[2] || 0 );
  return exists $Module::CoreList::version{ $key } ? $key : undef;
}

sub _core_modules_of {
  my ( $perl ) = @_;
  my @out = qx{ $perl -MModule::CoreList -e 'my \$h = \$Module::CoreList::version{ \$] + 0 } || {}; print "\$_\\n" for sort keys \%\$h' 2>/dev/null };
  chomp @out;
  return grep { length } @out;
}

sub _version_of {
  my ( $perl ) = @_;
  my ( $v ) = qx{ $perl -e 'printf "%vd", \$^V' 2>/dev/null };
  return $v || 'unknown';
}

# Every module name the project's own mirror indexes, so the report names only
# what is genuinely absent rather than everything that left core.
sub _indexed_modules {
  my ( $ctx ) = @_;
  my $index = Mist::CPAN::PackageIndex->new({ cpan_dist_root => $ctx->mpan_dist });
  my %seen;
  eval {
    my $entries = $index->package_index->entries->get_hash;
    %seen = map { $_ => 1 } keys %$entries;
    1;
  } or return {};
  return \%seen;
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::doctor - check the project for build pitfalls

=head1 SYNOPSIS

  mist doctor
  mist doctor --perl /usr/bin/perl
  mist doctor --perl /opt/perl5/perls/perl-5.42.2/bin/perl

=head1 DESCRIPTION

Reports problems that only surface when a project is built somewhere other than
where it usually is - the kind that are invisible while the pinned perl holds and
arrive all at once when it does not.

=head2 The ex-core gap

A project pinned to an old perl never has to vendor what that perl ships:
C<mpan-install> filters out anything the running perl already provides, so those
distributions never enter F<mpan-dist/>. Perl keeps evicting modules from core -
between 5.20.3 and 5.38 that is 76 of them, including C<CGI>, C<Module::Build>,
C<Pod::Parser> and the whole C<Locale::Codes> family - and each eviction turns a
module the mirror never needed into one it must supply.

Nothing goes wrong until someone builds on a newer perl. Then the modules are no
longer core, are not in the mirror, and have to come from somewhere. On a
distribution perl they usually can: Debian and its derivatives package most of
them, so the build quietly succeeds against F</usr/share/perl5> and produces an
environment that depends on system packages recorded in no F<cpanfile>, no
mirror, and no manifest. It fails later, elsewhere, without a clue pointing back.

C<doctor> compares what is core in this project's perl against what is core in
another one, subtracts what F<mpan-dist/> already carries, and reports the
remainder. Populating the mirror is a single build against a perl of the target
vintage - C<< ./mpan-install --perlbrew=<version> >>, or C<--build-only> to leave
the live environment untouched - after which the newly vendored tarballs are
committed like any other.

C<--system-perl> turns this class of problem from silent into loud, because it
keeps the distribution's own libraries out of the build; C<doctor> is how to see
it coming first.

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
