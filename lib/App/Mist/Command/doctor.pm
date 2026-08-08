package App::Mist::Command::doctor;
# ABSTRACT: check the project for build pitfalls before they bite

use 5.010;

use App::Mist -command;

use Config;
use Module::CoreList;
use Module::CPANfile;
use Module::Metadata;
use version 0.77 ();

use Mist::CPAN::PackageIndex ();
use Mist::Role::CPAN::PackageIndex ();

# Releases known to break a mirror-only install in ways the resulting error does
# not explain. One line per entry; the point of having it here rather than in
# prose is that nobody has to remember it.
#
# Read against the *indexed* version, never the tarballs on disk: a superseded
# tarball no index entry points at cannot be resolved and so cannot bite, and
# mirrors accumulate those routinely.
our @KNOWN_BAD = (
  {
    module => 'Term::Table',
    below  => '0.019',
    what   => 'declares a use cycle with Test-Simple',
    why    => <<'WHY',
  Term::Table was split out of Test2-Suite, and Test2::Suite was later merged
  into Test-Simple - which left the two declaring each other. Releases before
  0.019 carry that cycle. Resolving it mirror-only does not fail in a way that
  names the cause.
WHY
    fix    => 'mist inject Term::Table~0.019   (or newer)',
  },
  {
    module     => 'Module::CPANTS::Analyse',
    below      => '1.03',
    above_perl => '5.20.3',
    what       => 'fails its own test suite',
    why        => <<'WHY',
  t/analyse/manifest.t builds a fixture distribution containing a symlink with
  an absolute target, and Archive::Tar's secure extract refuses that on perls
  newer than 5.20.3. The assertion then never sees the symlink it is looking
  for and fails. That takes Test::Kwalitee with it, and anything declaring
  Test::Kwalitee among its author-test prereqs - Plack::Middleware::XSRFBlock,
  for one. Nothing in the resulting cascade mentions Archive::Tar.
WHY
    fix        => 'mist inject Module::CPANTS::Analyse~1.03   (carries the test patch)',
  },
  {
    module     => 'Variable::Magic',
    below      => '0.63',
    above_perl => '5.37.2',
    what       => 'fails its op-info test',
    why        => <<'WHY',
  Perl 5.37.3 introduced the OP_PADSV_STORE optimization; t/18-opinfo.t in
  releases before 0.63 expects the sassign op that optimization replaces.
  The failure takes B::Hooks::EndOfScope, namespace::clean and the whole
  Moose stack down with it, and none of the bail-outs name Variable::Magic
  as the root.
WHY
    fix        => 'mist inject Variable::Magic~0.63   (or newer; 0.64 verified)',
  },
  {
    module     => 'Test::Without::Module',
    below      => '0.21',
    above_perl => '5.20.3',
    what       => 'fails its error-message self-test',
    why        => <<'WHY',
  The "Can't locate" diagnostic changed shape ("@INC contains:" became
  "@INC entries checked:" when a hook sits in @INC); 0.21's changelog names
  the 5.38 wording explicitly. Blocks Clone::Choose, Hash::Merge and
  DBIx::Class behind it.
WHY
    fix        => 'mist inject Test::Without::Module~0.21   (or newer; 0.23 verified)',
  },
  {
    module     => 'Test::Trap',
    below      => 'v0.3.5',
    above_perl => '5.20.3',
    what       => 'fails its own test suite',
    why        => <<'WHY',
  v0.3.5's changelog: "No changes to the libraries, just to the tests. Perl
  best practices form a moving target" - bareword filehandles and the
  empty-string untaint change (RT #143716). Blocks MooseX::Getopt and
  Catalyst::Runtime behind it.
WHY
    fix        => 'mist inject Test::Trap~v0.3.5',
  },
  {
    module     => 'Moose',
    below      => '2.4000',
    above_perl => '5.20.3',
    what       => 'fails one warning-text test',
    why        => <<'WHY',
  t/basics/require_superclasses.t expects the old wording of the
  unresolvable-@ISA warning; 5.38 says "While trying to resolve method
  call..." instead. One subtest out of seventeen thousand, and the whole
  Moose ecosystem refuses to install over it. The first release with the
  updated expectation was not pinned down; 2.4000 is verified good and
  deployed on the estate.
WHY
    fix        => 'mist inject --from <sibling> Moose   (2.4000 vendored in erb)',
  },
  {
    module     => 'Devel::Declare',
    below      => '0.006022',
    above_perl => '5.31.6',
    what       => 'does not compile at all',
    why        => <<'WHY',
  stolen_chunk_of_toke.c uses perl API macros (isALNUM_utf8,
  isIDFIRST_lazy_if, is_utf8_mark) that perl 5.31.7 removed. 0.006020 took
  the fix upstream; 0.006022 is the stable release carrying it, and the
  dist's last release. Know before injecting it: every release that DOES
  compile there (0.006020+) silently loses declarators whenever use utf8
  is in scope - a one-token bug in S_scan_word's UTF-8 branch, unreported
  and unfixed upstream, dormant since 2019. There is no good Devel::Declare
  on a modern perl. The estate's actual exit is Mason 2.9901, which moved
  the method keyword to Function::Parameters and dropped this dist from
  the closure entirely.
WHY
    fix        => 'mist merge <path-to-perl-mason>   (Mason 2.9901; do not chase Devel::Declare versions)',
  },
  {
    module     => 'thanks',
    below      => '0.006',
    above_perl => '5.20.3',
    what       => 'fails its own test suite, distro-dependently',
    why        => <<'WHY',
  The dist blocks module loading by seeding %INC, and its tests assert the
  block works on strict itself. Modern perls load strict regardless - and
  so do distro-patched builds of older ones: Ubuntu's 5.38.2 fails the
  suite where a perlbrew 5.38.2 of the same version passes, so a green
  local side-build proves nothing for the deploy box. Reaches closures as
  a test-phase dependency of MooseX::ErsatzMethod - or as a fossil
  `prepend 'thanks'` in a merge block whose sibling dropped that dep long
  ago, which is how sig-cms met it. Last release 2013; below 0.006 means
  every release that exists.
WHY
    fix        => "drop the stale prepend (re-merge the sibling); notest 'thanks' only while one remains",
  },
  {
    module     => 'PPI',
    below      => '1.291',
    above_perl => '5.20.3',
    what       => 'fails its number-literal tests',
    why        => <<'WHY',
  Tests around bare 0b/0x literals expect an older tokenizer error shape.
  The first fixed release was not pinned down; 1.291 is verified good and
  deployed on the estate. Blocks Exparse::Interpreter::Core behind it.
WHY
    fix        => 'mist inject --from <sibling> PPI   (1.291 vendored in erb)',
  },
);

# A perl version as a comparable number: 5.38.2 -> 5.038002, the shape
# %Module::CoreList::version is keyed by.
sub _numeric_perl {
  my ( $spec ) = @_;
  return undef unless defined $spec and length $spec;
  return $spec if $spec =~ /\A\d+\.\d{6}\z/;
  my @part = grep { length } split /[._v]+/, $spec;
  return undef unless @part >= 2;
  return sprintf '%d.%03d%03d', $part[0], $part[1], ( $part[2] || 0 );
}

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
  $found += _report_foreign_resolution_of_vendored_dists( $ctx );
  $found += _report_unset_module_maker( $ctx );
  $found += _report_unsatisfiable_declarations( $ctx );
  $found += _report_bare_underscore_version( $ctx );
  $found += _report_vendored_prerelease( $ctx );
  $found += _report_undeclared_merges( $ctx );
  $found += _report_unreadable_modules( $ctx );
  $found += _report_known_bad_versions( $ctx, $label );

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

# What the cpanfile asks for, against what the mirror can actually hand over. A
# mirror-only install has no fallback, so a declaration the mirror cannot honour
# is fatal - but it fails as a cpanm resolution error, which names the module and
# not the reason.
#
# Malformed names are checked first and separately, because they otherwise
# masquerade as the other two: `requires 'String::Truncate ';` reads as a missing
# distribution when the distribution is right there and it is the name that is
# wrong.
sub _report_unsatisfiable_declarations {
  my ( $ctx ) = @_;

  my $prereqs = eval {
    Module::CPANfile->load( $ctx->cpanfile->stringify )
      ->prereqs->merged_requirements
  } or return 0;

  my $indexed = _indexed_versions( $ctx );
  my $core    = $Module::CoreList::version{ $] + 0 } || {};

  my ( @malformed, @absent, @below );
  for my $declared ( $prereqs->required_modules ) {
    next if $declared eq 'perl';

    ( my $module = $declared ) =~ s/\A\s+|\s+\z//g;
    if ( $module ne $declared ) {
      # Reported once, under the fault that is actually there. Carrying on would
      # also file it as absent or unsatisfiable, which is true of the malformed
      # name and useless: the thing to fix is the name, and what the mirror holds
      # cannot be judged until it is.
      push @malformed, $declared;
      next;
    }
    next unless length $module;

    my $want = $prereqs->requirements_for_module( $declared );

    if ( not exists $indexed->{ $module } ) {
      push @absent, $module unless exists $core->{ $module };
      next;
    }

    next unless defined $want and $want =~ /\d/;
    push @below, sprintf '%s wants %s, mirror indexes %s',
      $module, $want, $indexed->{ $module }
      unless eval { $prereqs->accepts_module( $declared, $indexed->{ $module } ) };
  }

  my $found = 0;

  if ( @malformed ) {
    printf "%d cpanfile entr%s carr%s stray whitespace in the module name:\n\n",
      scalar @malformed, ( @malformed == 1 ? 'y' : 'ies' ),
      ( @malformed == 1 ? 'ies' : 'y' );
    printf "  requires '%s';\n", $_ for @malformed;
    print <<'REPORT';

  The name is used verbatim, so it matches nothing in the index however well
  stocked the mirror is. Trim it.

REPORT
    $found++;
  }

  if ( @absent ) {
    printf "%d required module%s neither indexed by this mirror nor core here:\n\n",
      scalar @absent, ( @absent == 1 ? ' is' : 's are' );
    print "  $_\n" for @absent;
    print <<'REPORT';

  A mirror-only install has nowhere else to look, so this fails at resolution.
  Vendor them with `mist inject`, or drop the requirement.

REPORT
    $found++;
  }

  if ( @below ) {
    printf "%d cpanfile requirement%s the mirror cannot satisfy:\n\n",
      scalar @below, ( @below == 1 ? '' : 's' );
    print "  $_\n" for @below;
    print <<'REPORT';

  The floor was raised without the matching version being vendored - usually a
  `mist merge` or `mist inject` that did not follow the cpanfile edit.

REPORT
    $found++;
  }

  return $found;
}

sub _report_known_bad_versions {
  my ( $ctx, $target_version ) = @_;

  my $indexed = _indexed_versions( $ctx );
  my $found   = 0;

  for my $bad ( @KNOWN_BAD ) {
    my $have = $indexed->{ $bad->{module} };
    next unless defined $have;
    next unless Mist::Role::CPAN::PackageIndex::_version_cmp(
      $have, $bad->{below} ) < 0;

    # above_perl describes when an entry bites; it does not decide whether to
    # mention it. "This will cause problems later" is worth knowing the moment
    # someone is in the project, not only once they sit down to evaluate a newer
    # perl - so it is always reported, and the condition is stated instead.
    my $applicability = q{};
    if ( my $above = $bad->{above_perl} ) {
      my ( $target, $floor ) = map { _numeric_perl( $_ ) } $target_version, $above;
      my $crosses = defined $target && defined $floor && $target > $floor;
      $applicability = sprintf "  Bites on perls newer than %s%s\n", $above,
        ( defined $target
          ? ( $crosses ? " - including the $target_version asked about here."
                       : ", so not under the $target_version asked about here." )
          : '.' );
    }

    printf "%s %s is indexed, and %s below %s.\n\n%s%s\n  Fix: %s\n\n",
      $bad->{module}, $have, $bad->{what}, $bad->{below},
      $bad->{why}, $applicability, $bad->{fix};
    $found++;
  }

  return $found;
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

# An in-house dist and a CPAN release can share a name - deliberately so for a
# fork like Mason 2.99xx, whose version lane exists to win the index race. The
# alarm condition is the race going the other way: a package that a vendor/
# tarball provides resolving to an authors/id/ path means a foreign release
# outran the in-house one, and every cold build silently installs CPAN's bytes.
# Vendor-origin index entries carry ../../vendor/ paths, so origin is read from
# the index itself; the vendor directory listing supplies the dist names that
# count as ours.
sub _report_foreign_resolution_of_vendored_dists {
  my ( $ctx ) = @_;

  my $vendor = $ctx->mpan_dist->subdir('vendor');
  return 0 unless -d $vendor->stringify;

  my %ours;
  for my $child ( $vendor->children ) {
    next unless $child->basename =~ /^(.+)-[^-]+\.tar\.gz$/;
    push @{ $ours{ $1 } }, $child->basename;
  }
  return 0 unless %ours;

  my $index = Mist::CPAN::PackageIndex->new({ cpan_dist_root => $ctx->mpan_dist });
  my $entries = eval { $index->package_index->entries->get_hash } or return 0;

  my %foreign;
  for my $pkg ( keys %$entries ) {
    my ( $best_version, $best_entry );
    for my $version ( keys %{ $entries->{ $pkg } } ) {
      my $entry = $entries->{ $pkg }{ $version } or next;
      if ( not defined $best_version
        or Mist::Role::CPAN::PackageIndex::_version_cmp( $version, $best_version ) > 0 ) {
        ( $best_version, $best_entry ) = ( $version, $entry );
      }
    }
    my $path = eval { $best_entry->path } or next;
    next if $path =~ m{^\.\./\.\./vendor/};
    my ( $dist ) = $path =~ m{([^/]+)-[^-]+\.tar\.gz$} or next;
    $foreign{ $pkg } = { path => $path, dist => $dist, version => $best_version }
      if $ours{ $dist };
  }
  return 0 unless %foreign;

  printf "%d package%s of a vendored dist resolve%s to a CPAN tarball:\n\n",
    scalar keys %foreign, ( keys %foreign == 1 ? '' : 's' ),
    ( keys %foreign == 1 ? 's' : '' );
  for my $pkg ( sort keys %foreign ) {
    my $f = $foreign{ $pkg };
    printf "  %s %s <= %s  (vendor holds %s)\n",
      $pkg, $f->{version}, $f->{path}, join( ', ', @{ $ours{ $f->{dist} } } );
  }
  print <<'REPORT';

  The index prefers a foreign release over the in-house dist of the same name,
  so every cold build installs CPAN's bytes instead of ours. For a fork on a
  2.99xx-style version lane this means an upstream release outran the lane.
  Fix: remove the stray tarball from authors/ (or vendor a higher in-house
  version), then re-run `mist index`.

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

# Whether the release will be able to read this project's modules at all.
#
# Deliberately not a reimplementation: this asks Module::Metadata, which is the
# same scanner Minilla runs over lib/ via ->provides when it builds the dist
# metadata. The rule is subtle enough that a local copy would drift - POD is
# skipped, a comment evals as a no-op, and the scan stops at the first genuine
# declaration, so only a module carrying none of its own can be caught out by a
# string or heredoc that mentions the version variable and an equals sign.
#
# Worth catching here because the release hits it *after* the version bump has
# been written to disk, so the failure lands mid-pipeline on a dirty tree.
sub _unreadable_modules {
  my ( $ctx ) = @_;

  my $lib = $ctx->project_root->subdir( 'lib' );
  return () unless -d "$lib";

  my @broken;
  $lib->recurse( callback => sub {
    my ( $file ) = @_;
    return if $file->is_dir or $file !~ m{\.pm\z};
    my $error;
    {
      local $SIG{__WARN__} = sub { $error ||= $_[0] };
      eval { Module::Metadata->new_from_file( "$file" ); 1 } and return;
      $error ||= $@;
    }
    $error =~ s/\s+\z//;
    $error = ( split /\n/, $error )[0] // 'unparseable';
    push @broken, [ $file->relative( $ctx->project_root ), $error ];
  } );
  return @broken;
}

sub _report_unreadable_modules {
  my ( $ctx ) = @_;
  my @broken = _unreadable_modules( $ctx ) or return 0;

  printf "%d module%s Module::Metadata cannot read:\n\n", scalar @broken,
    ( @broken == 1 ? ' that' : 's that' );
  printf "  %s\n    %s\n", @$_ for @broken;
  print <<'REPORT';

  Minilla runs this same scanner over lib/ to build the dist metadata, so a
  release fails here - and it fails *after* the version bump has been written,
  leaving a dirty tree mid-pipeline.

  The usual cause is a string or heredoc that mentions the version variable
  followed by an equals sign, in a module that declares no version of its own:
  the scanner keeps looking for a declaration and evaluates that line as code.
  POD and comments are safe, so move the text into either, reword it, or give
  the module a version of its own.

REPORT
  return 1;
}

# Top-level merge blocks in the mistfile. Nested blocks - a sibling's own merges,
# folded in when it was merged - are indented, and are not this project's
# relationship to declare.
sub _merged_dists {
  my ( $ctx ) = @_;
  my $mistfile = $ctx->project_root->file( 'mistfile' );
  return () unless -f -r "$mistfile";
  return map { m{\A\#\#\# <<<\[([^\]]+)\]} ? $1 : () } $mistfile->slurp( chomp => 1 );
}

# Which merged distributions nothing in the cpanfile names.
#
# The block name is only used to LOCATE the distribution in the index; the
# verdict is always taken from the modules that distribution provides. Block
# names are labels and several in this estate do not match their module's
# casing, so judging on them reported six projects that were perfectly fine.
# A block whose distribution cannot be found is skipped rather than guessed at.
sub _undeclared_merges {
  my ( $ctx ) = @_;

  my @blocks = _merged_dists( $ctx ) or return ();

  my $index = Mist::CPAN::PackageIndex->new({ cpan_dist_root => $ctx->mpan_dist });
  my $entries = eval { $index->package_index->entries->get_hash } or return ();

  my %provides;   # tarball basename (lc) -> [ packages ]
  for my $pkg ( keys %$entries ) {
    for my $v ( keys %{ $entries->{ $pkg } } ) {
      my $entry = $entries->{ $pkg }{ $v } or next;
      my $path  = eval { $entry->path } or next;
      my ( $file ) = $path =~ m{([^/]+)\z} or next;
      push @{ $provides{ lc $file } }, $pkg;
    }
  }

  my $cpanfile = $ctx->project_root->file( 'cpanfile' );
  return () unless -f -r "$cpanfile";
  my %named = eval {
    map { $_ => 1 } Module::CPANfile->load( "$cpanfile" )
                      ->prereqs->merged_requirements->required_modules;
  } or return ();   # a malformed cpanfile is reported by its own check

  my @undeclared;
  for my $block ( @blocks ) {
    ( my $dist_name = lc $block ) =~ s/::/-/g;
    my @pkgs = map { @{ $provides{ $_ } } }
               grep { m{\A\Q$dist_name\E-[0-9]} } keys %provides;
    next unless @pkgs;                        # not in this mirror; nothing to judge
    next if grep { $named{ $_ } } @pkgs;      # any provided module named is enough
    push @undeclared, $block;
  }
  return @undeclared;
}

sub _report_undeclared_merges {
  my ( $ctx ) = @_;
  my @undeclared = _undeclared_merges( $ctx ) or return 0;

  printf "%d merged distribution%s named in cpanfile:\n\n", scalar @undeclared,
    ( @undeclared == 1 ? ' is not' : 's are not' );
  print "  $_\n" for @undeclared;
  print <<'REPORT';

  `./mpan-install` only ever reaches a distribution the cpanfile names. cpanm
  re-resolves a module it is *named* against the index, but one reached
  transitively is measured against its parent's declared floor - and an
  installed copy that satisfies that floor is never compared against the index
  at all. So merging one of these vendors it and installs nothing: the merge
  appears to work, and the version in `perl5/` never moves.

  Add a `requires` line for whichever module the project actually uses. No
  version is needed - naming it is what makes cpanm resolve it. `mist upgrade`
  is the other way there, since it names every laggard explicitly rather than
  relying on declarations.

REPORT
  return 1;
}

# Is this index path a trial distribution - one `mist prerelease` produced?
#
# Keyed on the DISTRIBUTION version from the tarball name, never on the package
# versions inside it. Plenty of stable CPAN releases ship modules carrying
# underscore versions: measured across the estate, matching package versions
# reported 7 of 31 projects, almost all of them healthy - Net::SFTP::Foreign
# ships submodules at 1.68_05 inside a stable 1.93 tarball, and
# ExtUtils::Installed, B::Utils and FindBin::libs do the same. Keying on the
# distribution takes it to the projects actually holding a trial build.
sub _is_trial_distribution {
  my ( $path ) = @_;
  my ( $file ) = ( $path // '' ) =~ m{([^/]+)\z} or return 0;
  my ( $dist_version ) = $file =~ m{-([^-]+)\.tar\.gz\z} or return 0;
  return eval { version->parse( $dist_version )->is_alpha } ? 1 : 0;
}

# A prerelease is indistinguishable from a real release once it is vendored: an
# ordinary tarball with an ordinary index entry. The discipline of not committing
# one is otherwise carried entirely by whoever remembers, and the moment that
# memory is worth least is exactly when a consumer is close to its first deploy.
sub _report_vendored_prerelease {
  my ( $ctx ) = @_;

  my $index = Mist::CPAN::PackageIndex->new({ cpan_dist_root => $ctx->mpan_dist });
  my $entries = eval { $index->package_index->entries->get_hash } or return 0;

  my %trial;
  for my $pkg ( keys %$entries ) {
    for my $v ( keys %{ $entries->{ $pkg } } ) {
      my $entry = $entries->{ $pkg }{ $v } or next;
      my $path  = eval { $entry->path } or next;
      $trial{ ( $path =~ m{([^/]+)\z} )[0] } = 1 if _is_trial_distribution( $path );
    }
  }
  return 0 unless %trial;

  printf "%d vendored distribution%s:\n\n", scalar keys %trial,
    ( keys %trial == 1 ? ' is a trial release' : 's are trial releases' );
  print "  $_\n" for sort keys %trial;
  print <<'REPORT';

  `mist prerelease` versions exist to hand a change to a sibling before it is
  released. Once vendored they are ordinary tarballs, so nothing but this check
  tells one from a real release - and committing mpan-dist would ship it.
  Re-merge once the provider has been released, or discard the vendored trial.

REPORT
  return 1;
}

# Underscores are digit separators in Perl numeric literals and are discarded, so
# an unquoted declaration of 0.52_01 is really the ordinary decimal 0.5201.
#
# Note the phrasing of this check's *strings*: they never spell out an
# assignment to the version variable. This module declares no version of its
# own, so Module::Metadata->provides - which Minilla runs over lib/ at release
# time - keeps scanning for one and evals the first line carrying that variable
# and an equals sign. Comments like this one are safe (they eval as a no-op) and
# so is POD, which is skipped; a format string or heredoc body is code.
# Whoever wrote it meant a trial release and silently did not get one: is_alpha is
# false, nothing downstream can tell it from a stable release, and every guard
# keying on pre-release status quietly does nothing. Quoting the value is the
# whole fix.
#
# Only an underscore *after* the decimal point is reported. One in the integer
# part is the ordinary thousands separator (1_000), where discarding it is
# exactly what was meant.
sub _report_bare_underscore_version {
  my ( $ctx ) = @_;

  my $lib = $ctx->project_root->subdir( 'lib' );
  return 0 unless -d "$lib";

  my @found;
  $lib->recurse( callback => sub {
    my ( $file ) = @_;
    return if $file->is_dir or $file !~ m{\.pm\z};
    my @lines = eval { $file->slurp( chomp => 1 ) } or return;
    my $in_pod = 0;
    for my $n ( 0 .. $#lines ) {
      my $line = $lines[ $n ];
      # Prose about this problem quotes the broken form by definition - this
      # check's own comment did, and it reported itself on the first real run.
      if ( $line =~ m{\A=cut\b} )    { $in_pod = 0; next }
      if ( $line =~ m{\A=[a-zA-Z]} ) { $in_pod = 1; next }
      next if $in_pod;

      # A quoted value cannot match: the character class admits no quote.
      $line =~ m{ \$VERSION \s* = \s* ( v? [0-9] [0-9_.]* ) \s* ; }x or next;
      my ( $literal, $at ) = ( $1, $-[0] );   # $-[0] before any further match
      next unless $literal =~ m{ \. [0-9]* _ }x;
      next if index( substr( $line, 0, $at ), '#' ) >= 0;
      push @found, [ $file->relative( $ctx->project_root ), $n + 1, $literal ];
    }
  } );
  return 0 unless @found;

  printf "%d version declaration%s an unquoted underscore:\n\n",
    scalar @found, ( @found == 1 ? ' uses' : 's use' );
  for my $hit ( @found ) {
    my ( $where, $line, $literal ) = @$hit;
    ( my $actual = $literal ) =~ s/_//g;
    printf "  %s:%d  declared %s, compiles to %s\n",
      $where, $line, $literal, $actual;
  }
  print <<'REPORT';

  Perl reads underscores in numeric literals as digit separators and discards
  them, so this is not a trial release - it is an ordinary version, and
  version->is_alpha says so. Nothing downstream can distinguish it from a
  stable release. Quote the value to get the trial release that was meant, or
  drop the underscore to get the number.

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
# module => the single version the index resolves to. mist's reindex is
# highest-version-wins, so there is normally one; if an incremental add ever left
# two, take the highest, which is what a resolver would reach.
sub _indexed_versions {
  my ( $ctx ) = @_;
  my $index = Mist::CPAN::PackageIndex->new({ cpan_dist_root => $ctx->mpan_dist });
  my $entries = eval { $index->package_index->entries->get_hash } or return {};

  my %version;
  for my $pkg ( keys %$entries ) {
    for my $v ( keys %{ $entries->{ $pkg } } ) {
      next unless defined $v and length $v and $v ne 'undef';
      $version{ $pkg } = $v
        if not defined $version{ $pkg }
        or Mist::Role::CPAN::PackageIndex::_version_cmp( $v, $version{ $pkg } ) > 0;
    }
  }
  return \%version;
}

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
