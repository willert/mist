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
    [ 'perl=s'    => 'check against this perl binary (default: /usr/bin/perl)' ],
    [ 'verbose|v' => 'list every module rather than grouping them' ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;

  my $target = $opt->perl || '/usr/bin/perl';
  die "$0: no such perl: $target\n" unless -x $target;

  my @problems = _ex_core_gap( $ctx, $target );

  if ( not @problems ) {
    printf "No ex-core gap against %s.\n", $target;
    return;
  }

  printf <<'REPORT', scalar @problems, $Config{version}, _version_of( $target ), $target;
%d module(s) are core in this project's perl (%s) but not in %s, and are
not vendored in mpan-dist. A build under %s would have to find them
somewhere else - which, without --system-perl's isolation, means silently
binding to whatever the distribution happens to package.

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

# Modules core in the perl this project pins but not in $target_perl, minus
# whatever mpan-dist already vendors. mist runs under the pinned perl, so the
# near side is just this process; the far side has to be asked, because a perl's
# bundled Module::CoreList only knows perls up to its own release - the 5.20.3
# copy mist itself runs under stops at 5.23.2 and cannot answer for 5.38 at all.
sub _ex_core_gap {
  my ( $ctx, $target_perl ) = @_;

  my $here  = $Module::CoreList::version{ $] + 0 } || {};
  my %there = map { $_ => 1 } _core_modules_of( $target_perl );
  return () unless %there;   # nothing to compare against; say nothing

  my $vendored = _indexed_modules( $ctx );

  return sort grep { not $there{ $_ } and not $vendored->{ $_ } } keys %$here;
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
