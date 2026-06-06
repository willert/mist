#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use File::Temp qw/ tempdir /;
use File::Spec;
use File::Path qw/ mkpath /;

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
}

FAILED_INSTALL_LEAVES_LOUD_STUB: {
  # Same-perl / fresh install: the selector is stubbed up front, so a mid-build
  # failure leaves an honest loud stub, never a wrapper over half-built libs.
  my $box = make_sandbox( $installer_assert );
  my ( $exit, $out ) = run_install( $box );
  isnt $exit, 0, 'an install that fails its assert exits non-zero';

  my $sel = selector( $box );
  ok( -e $sel && ! -l $sel,
    'selector is left a regular file (the stub), not a body symlink' );
  like _slurp( $sel ), qr/FATAL: Mist environment not fully installed/,
    'selector holds the loud FATAL stub after a mid-build failure';
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
  # --branch builds a named variant lib dir and points the generic per-perl dir
  # at it via a symlink. That symlink must be a real, natively-resolving link
  # (bare basename target) so the wrapper and local::lib follow it without help.
  my $box = make_sandbox( $installer_ok );
  my ( $exit, $out ) = run_install( $box, '--branch=base' );
  is $exit, 0, '--branch=base install exits 0' or diag $out;

  my ( $generic ) = grep { -l } glob "$box/perl5/perl-5.20.3-*";
  ok $generic, 'the generic per-perl lib dir is now a symlink (the selector)';
  my $target = readlink( $generic ) // '';
  unlike $target, qr{/},
    'branch symlink target is a bare basename, so it resolves natively';
  like $target, qr/^perl-5\.20\.3-.*-base$/, 'it targets the -base branch dir';
  ok -d $generic,
    'the generic symlink resolves to a real directory (not a dangling link)';
}

PARENT_BREAKS_PERLLOCAL_LINK: {
  # --parent seeds the new branch by hard-linking the parent's tree. perllocal.pod
  # is appended to in place, so a shared inode would let a child install mutate
  # the parent. The seed must break the link for that file.
  my $box = make_sandbox( $installer_ok );
  is( ( run_install( $box, '--branch=base' ) )[0], 0, 'base branch builds' );

  my ( $base ) = glob "$box/perl5/perl-5.20.3-*-base";
  ok $base, 'base branch dir exists';
  my $pod_subdir = File::Spec->catdir( $base, qw/ lib perl5 / );
  mkpath $pod_subdir;
  my $base_pod = File::Spec->catfile( $pod_subdir, 'perllocal.pod' );
  _spew( $base_pod, "=head2 seeded by base\n" );

  is( ( run_install( $box, '--branch=child', '--parent=base' ) )[0], 0,
    'child branch builds from parent' );

  my ( $child ) = glob "$box/perl5/perl-5.20.3-*-child";
  ok $child, 'child branch dir exists';
  my $child_pod = File::Spec->catfile( $child, qw/ lib perl5 perllocal.pod / );

  my $base_ino  = ( stat $base_pod )[1];
  my $child_ino = -e $child_pod ? ( stat $child_pod )[1] : 0;
  isnt $child_ino, $base_ino,
    'child perllocal.pod does not share the parent inode (append-leak broken)';
}

done_testing;
