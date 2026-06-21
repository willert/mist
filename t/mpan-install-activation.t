#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use File::Temp qw/ tempdir /;
use File::Spec;
use File::Path qw/ mkpath /;
use Cwd ();

# Exercises a real ./mpan-install end to end in throwaway sandboxes, fast and
# hermetic. Two off-switches keep it cheap without weakening it: a bare mistfile
# plus an empty cpanfile makes the cpanm call-stack empty (no closure build),
# and an `assert { die }` block is a deterministic mid-build failure injected
# after the stub is written but before activation. The activation / stub /
# atomicity logic in the install body runs in full regardless of either.
#
# The pinned perl is 5.20.3 - the one this repo already builds, so perlbrew has
# it. Installers are compiled from the current lib/ (never a checked-in
# fixture), so the harness always tests current code.

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );

my $mist = do { my $p = `command -v mist 2>/dev/null`; chomp $p; $p };
plan skip_all => 'mist not on PATH' unless length $mist and -x $mist;

my @built_perl = glob File::Spec->catdir( $repo, 'perl5', 'perl-5.20.3-*' );
plan skip_all => 'no built 5.20.3 env in this repo (need perlbrew 5.20.3)'
  unless @built_perl;

# the version-arch dir name this host builds, e.g. perl-5.20.3-x86_64-linux
# (filtering out a manual perl-5.20.3-*.bak sitting alongside it)
my ( $arch_name ) =
  grep { /perl-5\.20\.3-[^.]+$/ }
  map  { ( File::Spec->splitdir( $_ ) )[-1] } @built_perl;

my $mpan_dist = File::Spec->catdir( $repo, 'mpan-dist' );
plan skip_all => 'repo mpan-dist mirror missing' unless -d $mpan_dist;

# --- subprocess plumbing --------------------------------------------------

# Subprocesses (mist compile, ./mpan-install) must run in their own perl
# context, not whatever pinned env launched this test (e.g. ./mist-run prove).
# Clearing the pinning vars defuses the global-mist XS-mismatch trap and lets
# the installer's own perlbrew re-exec choose the perl.
my @PINNING = qw/
  PERL5LIB PERL5OPT MIST_PERLBREW_VERSION MIST_APP_ROOT MIST_PERL5_LIBDIR
  PERLBREW_PERL PERL_LOCAL_LIB_ROOT PERL_MM_OPT PERL_MB_OPT
/;

# Run a shell command line with the pinning vars stripped; returns the decoded
# exit code (-1 if the command could not be run at all).
sub clean_run {
  my ( $cmd ) = @_;
  local %ENV = %ENV;
  delete @ENV{ @PINNING };
  my $raw = system $cmd;
  return $raw == -1 ? -1 : ( $raw >> 8 );
}

sub _spew { my ( $f, $c ) = @_; open my $fh, '>', $f or die "$f: $!"; print $fh $c }
sub _slurp { my ( $f ) = @_; open my $fh, '<', $f or return ''; local $/; <$fh> }

# --- harness toolkit (reused by the later ladder steps) -------------------

# Compile a real installer from the given mistfile source and return its path.
# `cd $repo` so mist bootstraps this checkout's lib/ (the fatpacked install
# code), while -C points the compile at the throwaway project.
sub build_installer {
  my ( $mist_src ) = @_;
  my $proj = tempdir( 'mist-build-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  _spew( File::Spec->catfile( $proj, 'mistfile' ), $mist_src );
  _spew( File::Spec->catfile( $proj, 'cpanfile' ), '' );
  symlink $mpan_dist, File::Spec->catdir( $proj, 'mpan-dist' )
    or die "symlink mpan-dist: $!";
  my $log = File::Spec->catfile( $proj, 'compile.log' );
  my $rc  = clean_run( "cd $repo && $mist -C $proj compile >$log 2>&1" );
  my $installer = File::Spec->catfile( $proj, 'mpan-install' );
  die "compile failed (rc=$rc):\n" . _slurp( $log )
    unless $rc == 0 and -s $installer;
  return $installer;
}

# A throwaway dir holding a copy of the installer and the shared mirror, ready
# to run ./mpan-install in.
sub make_sandbox {
  my ( $installer ) = @_;
  my $dir = tempdir( 'mist-run-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  my $copy = File::Spec->catfile( $dir, 'mpan-install' );
  _spew( $copy, _slurp( $installer ) );
  chmod 0755, $copy;
  symlink $mpan_dist, File::Spec->catdir( $dir, 'mpan-dist' )
    or die "symlink mpan-dist: $!";
  return $dir;
}

# Run ./mpan-install in a sandbox, from inside it (real installs always run from
# the project root, and some paths - e.g. the --parent copy - are cwd-relative).
# STDIN is severed so the switch-guard sees a non-tty. Returns ( exit, output ).
sub run_install {
  my ( $dir, @args ) = @_;
  my $log = File::Spec->catfile( $dir, 'install.log' );
  my $exit = clean_run(
    "cd $dir && ./mpan-install @args >install.log 2>&1 </dev/null" );
  return ( $exit, _slurp( $log ) );
}

# Plant a pre-existing active selector pointing at a body for some other perl,
# so the install body sees a workdir already running a different version.
sub plant_selector {
  my ( $dir, $body_name ) = @_;
  my $bin = File::Spec->catdir( $dir, qw/ perl5 bin / );
  mkpath $bin;
  _spew( File::Spec->catfile( $bin, $body_name ), "#!/bin/bash\necho planted\n" );
  symlink $body_name, File::Spec->catfile( $bin, 'mist-run' )
    or die "plant selector: $!";
}

sub selector  { File::Spec->catfile( shift, qw/ perl5 bin mist-run / ) }
sub rc_alias  { File::Spec->catfile( shift, qw/ perl5 etc mist.mistrc / ) }

# the per-perl generation selector perl5/<arch_name> and the dir it resolves to
sub gen_link  { File::Spec->catdir( shift, 'perl5', $arch_name ) }
sub gen_dir   { my $b = shift; File::Spec->catdir( $b, 'perl5', readlink gen_link( $b ) ) }

my $FOREIGN = 'mist-run-perl-9.9.9-fakearch';   # a plausibly-other active perl

# --- compile the two installers the scenarios share -----------------------

my $installer_ok     = build_installer( "perl q{5.20.3};\n" );
my $installer_assert = build_installer(
  "perl q{5.20.3};\nassert { die qq{harness: injected failure\\n} };\n" );

# --- scenarios ------------------------------------------------------------

CLEAN_INSTALL_ACTIVATES: {
  my $box = make_sandbox( $installer_ok );
  my ( $exit, $out ) = run_install( $box );
  is $exit, 0, 'clean install exits 0' or diag $out;

  my $sel = selector( $box );
  ok -l $sel, 'perl5/bin/mist-run is a symlink (the selector)';
  my $target = readlink( $sel ) // '';
  like $target, qr/^mist-run-perl-5\.20\.3-/,
    "selector points at this perl's body";
  my $body = File::Spec->catfile( $box, 'perl5', 'bin', $target );
  ok( -f $body && -x $body, 'the body it points at exists and is executable' );

  my $alias = rc_alias( $box );
  ok -l $alias, 'mist.mistrc alias is a symlink';
  like readlink( $alias ) // '', qr/^mist\.mistrc-perl-5\.20\.3-/,
    "alias points at this perl's rc";

  ok -e File::Spec->catfile( $box, 'mist-run' ), 'root ./mist-run created';

  ok -l gen_link( $box ), 'the per-perl generation selector is a symlink';
  like readlink( gen_link( $box ) ) // '', qr{^generations/perl-5\.20\.3-},
    'it points at a generation under generations/';
  like readlink( gen_link( $box ) ) // '', qr{-\d+$},
    'the auto generation is numbered by a counter, not a -build dir';
  ok -d gen_dir( $box ), 'the generation it points at is a real directory';
  ok scalar( glob File::Spec->catfile( gen_dir( $box ), '.mist-built-*' ) ),
    'the generation carries a .mist-built-<ts> completion marker';

  is clean_run( "$sel perl -e 'exit 0'" ), 0,
    'the activated wrapper runs a command under its own env';
}

BUILD_ONLY_DOES_NOT_ACTIVATE: {
  my $box = make_sandbox( $installer_ok );
  my ( $exit, $out ) = run_install( $box, '--build-only' );
  is $exit, 0, '--build-only exits 0' or diag $out;

  my ( $body ) = glob File::Spec->catfile(
    $box, qw/ perl5 bin /, 'mist-run-perl-5.20.3-*' );
  ok( $body && -x $body, '--build-only still writes the per-perl body' );

  ok ! -e selector( $box ), '--build-only does not create the selector';
  ok ! -e rc_alias( $box ), '--build-only does not create the rc alias';
  ok ! -e File::Spec->catfile( $box, 'mist-run' ),
    '--build-only does not create root ./mist-run';

  ok -l gen_link( $box ),
    '--build-only still makes its generation current for this perl (no perl switch)';
}

BUILD_WORKSPACE_DETERMINISTIC_REBUILD_RESETS: {
  # cpanm's build HOME is a deterministic path (per project + perl + user) so it is
  # reused across runs rather than leaked fresh each time. A plain run reuses it; a
  # --rebuild resets it. Derive the same path install.pm computes (run_install
  # strips MIST_APP_ROOT, so the installer's $mist_home is the sandbox dir).
  my $box = make_sandbox( $installer_ok );
  ( my $key = lc Cwd::realpath( $box ) ) =~ s/\W/_/g;
  $key =~ s/\A_+//; $key =~ s/_+\z//;
  my $workspace = File::Spec->catdir(
    File::Spec->tmpdir, "mist-build-$<-$key-$arch_name" );

  my ( $e1, $o1 ) = run_install( $box );
  is $e1, 0, 'first install exits 0' or diag $o1;
  ok -d $workspace, 'build workspace created at the deterministic path';

  my $sentinel = File::Spec->catfile( $workspace, 'SENTINEL' );
  _spew( $sentinel, "keep\n" );

  run_install( $box );
  ok -e $sentinel, 'a plain re-run reuses the same workspace (sentinel survives)';

  run_install( $box, '--rebuild' );
  ok ! -e $sentinel, '--rebuild resets the workspace (sentinel gone)';
  ok -d $workspace, 'and the workspace is recreated';

  File::Path::rmtree( $workspace );   # deterministic dir is not auto-cleaned
}

FAILED_INSTALL_KEEPS_PRIOR_GENERATION: {
  # Step 3: a same-perl re-install builds an isolated generation and only swaps
  # the lib symlink on success. A mid-build failure must leave the prior
  # generation active and intact - and never a loud stub (that retired with the
  # in-place mutation it used to cover).
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'first install succeeds' );
  my $gen_a = readlink gen_link( $box );
  ok $gen_a, 'first install left an active generation';

  # swap in the failure-injecting installer and re-run (same perl)
  my $copy = File::Spec->catfile( $box, 'mpan-install' );
  _spew( $copy, _slurp( $installer_assert ) );
  chmod 0755, $copy;
  my ( $exit, $out ) = run_install( $box );
  isnt $exit, 0, 'the failing re-install exits non-zero';

  is readlink( gen_link( $box ) ), $gen_a,
    'the generation symlink still points at the prior generation';
  ok -d gen_dir( $box ), 'the prior generation is intact';

  ok scalar( glob "$box/perl5/generations/*-build" ),
    'the failed build leaves a self-labelling ...-build dir';
  ok ! -e File::Spec->catdir( $box, qw/ perl5 generations /, "${arch_name}-2" ),
    'and never a completed (promoted) generation from the failed build';

  my $sel = selector( $box );
  ok -l $sel, 'the selector is still a body symlink, not a regular-file stub';
  is clean_run( "$sel perl -e 'exit 0'" ), 0,
    'the prior environment still runs after the failed re-install';
}

RESUME_REUSES_FAILED_BUILD_DIR: {
  # A failed build leaves its ...-build dir; the next run resumes it (cpanm
  # continues where it stopped) instead of discarding the partial work - matching
  # a plain cpanm re-run and the pre-generation in-place build.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'first install ok (generation 1 active)' );

  # a build that fails partway, leaving a -build dir
  my $copy = File::Spec->catfile( $box, 'mpan-install' );
  _spew( $copy, _slurp( $installer_assert ) );
  chmod 0755, $copy;
  isnt( ( run_install( $box ) )[0], 0, 'second build fails, leaving a -build dir' );
  my ( $build ) = glob "$box/perl5/generations/*-build";
  ok $build, 'the failed build dir is present';
  _spew( File::Spec->catfile( $build, 'RESUME_TOKEN' ), "r\n" );

  # retry with a succeeding installer: it must build into the same -build dir
  _spew( $copy, _slurp( $installer_ok ) );
  chmod 0755, $copy;
  is( ( run_install( $box ) )[0], 0, 'the retry succeeds' );
  ok ! -e $build, 'the -build dir was promoted (renamed), not left behind';
  ok -e File::Spec->catfile( gen_dir( $box ), 'RESUME_TOKEN' ),
    'the retry resumed the failed -build dir (its token carried into the generation)';
}

NO_RESUME_DISCARDS_FAILED_BUILD_DIR: {
  # --no-resume is the opt-in clean-room rebuild: discard a leftover -build and
  # reseed from the parent instead of resuming the partial work (the inverse of
  # the resume default above).
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'first install ok' );

  my $copy = File::Spec->catfile( $box, 'mpan-install' );
  _spew( $copy, _slurp( $installer_assert ) );
  chmod 0755, $copy;
  isnt( ( run_install( $box ) )[0], 0, 'second build fails, leaving a -build dir' );
  my ( $build ) = glob "$box/perl5/generations/*-build";
  ok $build, 'the failed build dir is present';
  _spew( File::Spec->catfile( $build, 'STALE_TOKEN' ), "x\n" );

  _spew( $copy, _slurp( $installer_ok ) );
  chmod 0755, $copy;
  is( ( run_install( $box, '--no-resume' ) )[0], 0, 'the --no-resume retry succeeds' );
  ok ! -e File::Spec->catfile( gen_dir( $box ), 'STALE_TOKEN' ),
    '--no-resume discarded the leftover -build and reseeded (stale token gone)';
}

REBUILD_SHEDS_CRUFT: {
  # --rebuild starts a fresh generation with no CoW seed: cpanm builds the whole
  # closure into an empty dir, so files orphaned across generations (a dropped dep
  # an additive seed would carry forward forever) do not survive. Atomicity keeps
  # the live env intact throughout - the clean slate has no exposure window.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'first install ok' );
  my $gen1 = gen_dir( $box );
  _spew( File::Spec->catfile( $gen1, 'CRUFT' ), "old\n" );

  is( ( run_install( $box, '--rebuild' ) )[0], 0, '--rebuild succeeds' );
  my $gen2 = gen_dir( $box );
  isnt $gen2, $gen1, '--rebuild made a new generation';
  ok ! -e File::Spec->catfile( $gen2, 'CRUFT' ),
    '--rebuild did not CoW-seed, so the parent cruft did not carry forward';
  ok -e File::Spec->catfile( $gen1, 'CRUFT' ),
    'the prior generation is untouched (the live env was safe during the rebuild)';
}

ATOMIC_FAILED_REBUILD_KEEPS_LIVE_WRAPPER: {
  # The body and rc are staged under *.new and renamed into place only on success,
  # so a failed --rebuild must leave the live perl5/bin/mist-run wrapper intact,
  # never truncated mid-build. NB a bare `$sel perl -e 0` check is too weak to
  # catch this - an emptied body is still a valid no-op bash script that exits 0 -
  # so assert the body file's contents survived.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'first install ok' );

  my $body = File::Spec->catfile( $box, qw/ perl5 bin /, "mist-run-$arch_name" );
  ok -s $body, 'the active install left a populated mist-run body';

  my $copy = File::Spec->catfile( $box, 'mpan-install' );
  _spew( $copy, _slurp( $installer_assert ) );
  chmod 0755, $copy;
  isnt( ( run_install( $box, '--rebuild' ) )[0], 0,
    'the --rebuild fails before promotion' );

  ok -s $body,
    'the live mist-run body survives the failed --rebuild (not truncated mid-build)';
  like _slurp( $body ), qr/mist_exec/,
    'and it is still the real wrapper, not an emptied file';
}

CONTINUE_LAST_BUILD_RESUMES_THE_PARTIAL: {
  # --continue-last-build resumes the existing -build in place (like the default
  # resume) - the explicit, named op for iterating on a broken closure build
  # without discarding what already built.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'first install ok' );

  my $copy = File::Spec->catfile( $box, 'mpan-install' );
  _spew( $copy, _slurp( $installer_assert ) );
  chmod 0755, $copy;
  isnt( ( run_install( $box, '--rebuild' ) )[0], 0,
    'a --rebuild fails, leaving a -build dir' );
  my ( $build ) = glob "$box/perl5/generations/*-build";
  ok $build, 'the failed build dir is present';
  _spew( File::Spec->catfile( $build, 'CONTINUE_TOKEN' ), "c\n" );

  _spew( $copy, _slurp( $installer_ok ) );
  chmod 0755, $copy;
  is( ( run_install( $box, '--continue-last-build' ) )[0], 0,
    '--continue-last-build succeeds' );
  ok -e File::Spec->catfile( gen_dir( $box ), 'CONTINUE_TOKEN' ),
    'it resumed the partial (the -build token carried into the promoted generation)';
}

CONTINUE_LAST_BUILD_REFUSES_WITHOUT_PARTIAL: {
  # Strict: with no in-progress -build to continue, it errors rather than silently
  # starting a fresh build.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'first install ok (promoted; no -build left)' );
  ok ! scalar( glob "$box/perl5/generations/*-build" ),
    'a successful install leaves no -build dir';

  my ( $exit, $out ) = run_install( $box, '--continue-last-build' );
  isnt $exit, 0, '--continue-last-build with nothing to continue exits non-zero';
  like $out, qr/No in-progress build to continue/, 'and says why';
}

CROSS_PERL_LEAVES_ACTIVE_SELECTOR_UNTOUCHED: {
  # A build for a perl other than the active one is isolated: it never stubs or
  # moves the live selector, so a failure leaves the active env exactly as it
  # was. --perlbrew is explicit, so it bypasses the switch-guard and the build
  # fails on its assert instead.
  my $box = make_sandbox( $installer_assert );
  plant_selector( $box, $FOREIGN );

  my ( $exit, $out ) = run_install( $box, '--perlbrew=5.20.3' );
  isnt $exit, 0, 'the cross-perl build still fails its assert';

  is readlink( selector( $box ) ) // '', $FOREIGN,
    'a failed cross-perl build never stubs or moves the live selector';
}

IMPLICIT_SWITCH_REFUSED_WITHOUT_TTY: {
  # Bare install onto a workdir whose active perl differs, STDIN not a tty: the
  # guard refuses before any file work or perlbrew re-exec.
  my $box = make_sandbox( $installer_ok );
  plant_selector( $box, $FOREIGN );

  my ( $exit, $out ) = run_install( $box );
  isnt $exit, 0, 'a bare implicit switch is refused (non-zero exit)';
  like $out, qr/refusing to implicitly switch perl/,
    'the refusal names the implicit-switch guard';
  is readlink( selector( $box ) ) // '', $FOREIGN,
    'the refused install leaves the live selector untouched';
}

BRANCH_ACTIVATES_NATIVELY: {
  # --branch names a generation; the generic per-perl dir points at it under
  # generations/. The target is relative to perl5/ (no perl5/ prefix), so it
  # resolves natively for the wrapper and local::lib, not only for readlink.
  my $box = make_sandbox( $installer_ok );
  my ( $exit, $out ) = run_install( $box, '--branch=base' );
  is $exit, 0, '--branch=base install exits 0' or diag $out;

  my $generic = gen_link( $box );
  ok -l $generic, 'the generic per-perl lib dir is a symlink (the generation selector)';
  my $target = readlink( $generic ) // '';
  like $target, qr{^generations/perl-5\.20\.3-.*-base$},
    'it targets the -base generation under generations/';
  unlike $target, qr{^/|^perl5/},
    'the target is relative and not perl5/-prefixed, so it resolves natively';
  ok -d $generic,
    'the generic symlink resolves to a real directory (not a dangling link)';
}

PARENT_BREAKS_PERLLOCAL_LINK: {
  # --parent seeds the new generation by hard-linking the parent's tree.
  # perllocal.pod is appended to in place, so a shared inode would let the child
  # install mutate the parent. The seed must break the link for that file.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box, '--branch=base' ) )[0], 0, 'base generation builds' );

  my ( $base ) = glob "$box/perl5/generations/perl-5.20.3-*-base";
  ok $base, 'base generation dir exists';
  my $pod_subdir = File::Spec->catdir( $base, qw/ lib perl5 / );
  mkpath $pod_subdir;
  my $base_pod = File::Spec->catfile( $pod_subdir, 'perllocal.pod' );
  _spew( $base_pod, "=head2 seeded by base\n" );
  my $base_shared = File::Spec->catfile( $pod_subdir, 'SHARED' );
  _spew( $base_shared, "shared\n" );

  is( ( run_install( $box, '--branch=child', '--parent=base' ) )[0], 0,
    'child generation builds from parent' );

  my ( $child ) = glob "$box/perl5/generations/perl-5.20.3-*-child";
  ok $child, 'child generation dir exists';
  my $child_pod = File::Spec->catfile( $child, qw/ lib perl5 perllocal.pod / );

  my $base_ino  = ( stat $base_pod )[1];
  my $child_ino = -e $child_pod ? ( stat $child_pod )[1] : 0;
  isnt $child_ino, $base_ino,
    'child perllocal.pod does not share the parent inode (append-leak broken)';

  # a normal file IS shared by the seed - that hard-link sharing is the CoW win,
  # and this guards against a silent regression to a full copy
  ok( ( stat File::Spec->catfile( $child, qw/ lib perl5 SHARED / ) )[3] >= 2,
    'a normal seeded file is hard-linked (shared inode) with the parent' );
}

NAMED_BRANCH_REINSTALL_SEEDS_FROM_ITSELF: {
  # A named generation is a stable, separately-named env. Re-installing it must
  # update *it* (seed from itself) and carry its accumulated state forward - even
  # when a different generation is currently active - not reseed it from whatever
  # happens to be active.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box, '--branch=spike' ) )[0], 0, 'spike builds' );
  is( ( run_install( $box ) )[0], 0, 'a default install makes a counter gen active' );

  # state that lives only in spike, planted after the counter gen was built (so it
  # cannot have leaked into the active gen via the seed)
  my $spike = File::Spec->catdir( $box, qw/ perl5 generations /, "${arch_name}-spike" );
  _spew( File::Spec->catfile( $spike, 'SPIKE_STATE' ), "s\n" );

  is( ( run_install( $box, '--branch=spike' ) )[0], 0, 'spike re-install ok' );
  ok -e File::Spec->catfile( $spike, 'SPIKE_STATE' ),
    'the re-install seeds spike from itself, not from the active counter gen';
}

TWO_GENERATIONS_SWAP_AND_ROLLBACK: {
  # The default path is implicitly CoW: each install builds a new generation
  # seeded from the active one and swaps the symlink. Old generations are kept,
  # so rollback is a single symlink repoint.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'first install ok' );
  my $gen_a = readlink gen_link( $box );
  like $gen_a, qr{^generations/}, 'generation A lives under generations/';
  my $gen_a_dir = File::Spec->catdir( $box, 'perl5', $gen_a );

  is( ( run_install( $box ) )[0], 0, 'second install ok' );
  my $gen_b = readlink gen_link( $box );
  isnt $gen_b, $gen_a, 'the second install swapped to a new generation';
  ok -d $gen_a_dir, 'generation A is kept (rollback target survives)';

  # a marker planted in A *after* B was built cannot have leaked into B via the seed
  _spew( File::Spec->catfile( $gen_a_dir, 'MARKER_A' ), "a\n" );
  ok ! -e File::Spec->catfile( $box, 'perl5', $arch_name, 'MARKER_A' ),
    'the active generic path resolves to B, which has no MARKER_A';

  # rollback = repoint the generation selector at A
  { my $g = gen_link( $box ); unlink $g; symlink $gen_a, $g or die "rollback: $!" }
  is readlink( gen_link( $box ) ), $gen_a, 'rolled back to generation A';
  ok -e File::Spec->catfile( $box, 'perl5', $arch_name, 'MARKER_A' ),
    'the generic path now resolves to A again (rollback took effect)';
}

MIGRATION_FROM_LEGACY_REALDIR: {
  # A project installed before generations has perl5/<arch> as a real directory.
  # The first generation-aware install seeds a generation from it (hard-link),
  # then converts the real dir into the generation symlink without losing data.
  my $box = make_sandbox( $installer_ok );
  my $legacy = File::Spec->catdir( $box, 'perl5', $arch_name );
  mkpath( File::Spec->catdir( $legacy, qw/ lib perl5 / ) );
  _spew( File::Spec->catfile( $legacy, 'LEGACY_MARKER' ), "legacy\n" );
  ok( -d $legacy && ! -l $legacy, 'legacy lib dir starts as a real directory' );

  my ( $exit, $out ) = run_install( $box );
  is $exit, 0, 'install over a legacy real dir succeeds' or diag $out;

  ok -l gen_link( $box ), 'the legacy real dir is now the generation symlink';
  like readlink( gen_link( $box ) ), qr{^generations/}, 'it points into generations/';
  ok -e File::Spec->catfile( $box, 'perl5', $arch_name, 'LEGACY_MARKER' ),
    'the migrated content survives via the new generation';
}

PURGE_REMOVES_SUPERSEDED_GENERATIONS: {
  # --purge cleans this perl's superseded generations after a successful install,
  # keeping the just-activated one. Three installs, the last with --purge.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'gen 1 ok' );
  is( ( run_install( $box ) )[0], 0, 'gen 2 ok' );

  my ( $exit, $out ) = run_install( $box, '--purge' );
  is $exit, 0, 'gen 3 install --purge exits 0' or diag $out;

  like readlink( gen_link( $box ) ), qr{-3\z}, 'the newest generation is active';
  ok -d gen_dir( $box ), 'the active generation is intact';

  my @left = glob File::Spec->catdir(
    $box, qw/ perl5 generations /, "${arch_name}-*" );
  is scalar( @left ), 1, '--purge left only the active generation' or diag "@left";
  like $left[0], qr{-3\z}, 'and it is the one just built';
}

PURGE_KEEPS_NAMED_BRANCHES: {
  # named generations are deliberate environments; --purge leaves them alone and
  # only sweeps the auto-numbered ones.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box, '--branch=stable' ) )[0], 0, 'stable branch built' );
  is( ( run_install( $box ) )[0], 0, 'a numbered generation built and active' );
  is( ( run_install( $box, '--purge' ) )[0], 0, 'next install --purge ok' );

  ok -d File::Spec->catdir( $box, qw/ perl5 generations /, "${arch_name}-stable" ),
    'the named branch survives --purge';
  ok ! -e File::Spec->catdir( $box, qw/ perl5 generations /, "${arch_name}-1" ),
    'the superseded numbered generation is purged';
}

PURGE_WITH_BUILD_ONLY_KEEPS_LIVE_AND_BUILT: {
  # --build-only --purge: the freshly built generation is not activated, so both
  # the live generation (still the previous one) and the just-built one must
  # survive, while an older superseded generation is still reclaimed.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box ) )[0], 0, 'gen 1 ok' );
  is( ( run_install( $box ) )[0], 0, 'gen 2 ok (live)' );
  my $live = readlink gen_link( $box );
  like $live, qr{-2\z}, 'generation 2 is the live one';

  my ( $exit, $out ) = run_install( $box, '--build-only', '--purge' );
  is $exit, 0, '--build-only --purge exits 0' or diag $out;

  is readlink( gen_link( $box ) ), $live,
    '--build-only leaves the live selector pointing at generation 2';
  ok -d File::Spec->catdir( $box, qw/ perl5 generations /, "${arch_name}-2" ),
    'the live generation survives the purge';
  ok -d File::Spec->catdir( $box, qw/ perl5 generations /, "${arch_name}-3" ),
    'the just-built (un-activated) generation survives the purge';
  ok ! -e File::Spec->catdir( $box, qw/ perl5 generations /, "${arch_name}-1" ),
    'the superseded generation 1 is reclaimed';
}

# The per-project workspace where ephemeral bundles live, derived the way the host
# (and App::Mist::Context) derive it: lc the realpath'd project root, \W -> _,
# trimmed, under <home>/.mist/<...>/bundles.
sub workspace_bundles {
  my ( $home, $project ) = @_;
  ( my $base = lc Cwd::realpath( $project ) ) =~ s/\W/_/g;
  $base =~ s/\A_+//;
  $base =~ s/_+\z//;
  return File::Spec->catdir( $home, '.mist', $base, 'bundles' );
}

BUNDLE_APPLIES_AS_A_GENERATION: {
  # --bundle resolves an ephemeral uuid bundle from the workspace, folds its floor
  # specs into a targeted install, and builds+activates a fresh generation. The
  # floor is a core module so no real build is needed; the resolution, workspace
  # derivation and generation activation are what this exercises.
  my $box  = make_sandbox( $installer_ok );
  my $home = File::Spec->catdir( $box, 'home' );
  my $uuid = 'aaaaaaaa-bbbb-cccc-dddd-000000000001';

  my $bundles = workspace_bundles( $home, $box );
  mkpath $bundles;
  _spew( File::Spec->catfile( $bundles, "$uuid.bundle" ), "Carp~0\n" );

  local $ENV{HOME} = $home;
  my ( $exit, $out ) = run_install( $box, '--bundle', $uuid );
  is $exit, 0, '--bundle apply exits 0' or diag $out;
  like $out, qr/Applying bundle \Q$uuid\E \(1 floors\)/,
    'the installer resolved the ephemeral bundle from the workspace';

  ok -l gen_link( $box ), 'a generation was activated';
  like readlink( gen_link( $box ) ) // '', qr{^generations/perl-5\.20\.3-.*-\d+$},
    'the bundle apply landed in a numbered generation';
}

BUNDLE_RESOLUTION_IS_GUARDED_AND_LOUD: {
  # A traversal id is rejected outright; a well-formed but unknown id fails loud
  # rather than silently installing nothing. Both abort before any generation is
  # promoted or activated.
  my $box = make_sandbox( $installer_ok );

  my ( $bad_exit, $bad_out ) = run_install( $box, '--bundle', '../escape' );
  isnt $bad_exit, 0, 'a traversal bundle id is rejected';
  like $bad_out, qr/Invalid bundle id/, 'and says why';

  my ( $miss_exit, $miss_out ) = run_install( $box, '--bundle', 'no-such-bundle' );
  isnt $miss_exit, 0, 'an unknown bundle id fails loud';
  like $miss_out, qr/No bundle 'no-such-bundle'/, 'and names the missing bundle';

  ok ! -e gen_link( $box ),
    'a failed bundle resolution activates no generation';
}

done_testing;
