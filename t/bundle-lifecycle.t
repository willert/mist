#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

use File::Temp qw/ tempdir /;
use File::Spec;
use File::Path qw/ mkpath /;
use Cwd ();

# Full bundle-lifecycle smoker, end to end against real mist + ./mpan-install:
#
#   peer A vendors Acme::MistCascade 0.02 (the vetted version)
#   project B vendors only 0.01 (its own older copy)
#
#   produce: mist inject --from A --full-dependency-tree   -> ephemeral bundle
#   publish: mist bundle publish <uuid> --as cascade        -> committed mpan-dist
#   apply:   ./mpan-install --bundle cascade                -> a fresh generation
#
# The pivot assertion is that the produced bundle floors on the PEER's 0.02, not
# B's own 0.01 - i.e. the peer-first clean-room resolve really raised the version
# - and that 0.02 is what the applied environment ends up carrying. This is the
# coverage `inject --full-dependency-tree` otherwise lacks. Hermetic: a throwaway
# module, no network. Heavy (real perlbrew re-execs + builds); skips cleanly when
# the 5.20.3 env / mist / toolchain are absent.

eval { require MistTest::Mirror; 1 }
  or plan skip_all => "cannot load test mirror helper: $@";

my $repo = Cwd::realpath(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );

my $mist = do { my $p = `command -v mist 2>/dev/null`; chomp $p; $p };
plan skip_all => 'mist not on PATH' unless length $mist and -x $mist;

my @built = glob File::Spec->catdir( $repo, 'perl5', 'perl-5.20.3-*' );
plan skip_all => 'no built 5.20.3 env in this repo (need perlbrew 5.20.3)'
  unless @built;
my ( $arch ) =
  grep { /perl-5\.20\.3-[^.]+$/ }
  map  { ( File::Spec->splitdir( $_ ) )[-1] } @built;

# --- plumbing -------------------------------------------------------------

# Subprocesses must run in their own perl context, not whatever pinned env
# launched this test (./mist-run prove). Stripping the pinning vars defuses the
# global-mist XS-mismatch trap and lets the installer's perlbrew re-exec choose.
my @PINNING = qw/
  PERL5LIB PERL5OPT MIST_PERLBREW_VERSION MIST_APP_ROOT MIST_PERL5_LIBDIR
  PERLBREW_PERL PERL_LOCAL_LIB_ROOT PERL_MM_OPT PERL_MB_OPT
/;

# Run a shell line with the pinning vars stripped and HOME redirected (so the
# per-project workspace lands in the sandbox, never the real ~/.mist). Returns
# ( exit, combined output ).
sub run {
  my ( $home, $cmd ) = @_;
  local %ENV = %ENV;
  delete @ENV{ @PINNING };
  $ENV{HOME} = $home;
  my $out = `$cmd </dev/null 2>&1`;
  return ( $? >> 8, $out );
}

sub _spew { my ( $f, $c ) = @_; open my $fh, '>', $f or die "$f: $!"; print $fh $c }
sub _slurp { my ( $f ) = @_; open my $fh, '<', $f or return ''; local $/; <$fh> }

# The Context-derived workspace path for a project root under a given home.
sub workspace {
  my ( $home, $project ) = @_;
  ( my $base = lc Cwd::realpath( $project ) ) =~ s/\W/_/g;
  $base =~ s/\A_+//;
  $base =~ s/_+\z//;
  return File::Spec->catdir( $home, '.mist', $base );
}

# --- the three projects ---------------------------------------------------

my $root = tempdir( 'mist-lifecycle-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $A     = File::Spec->catdir( $root, 'peerA' );
my $B     = File::Spec->catdir( $root, 'projB' );
my $Bhome = File::Spec->catdir( $B, 'home' );
mkpath $_ for $A, $B, $Bhome;

# peer A: a faux-CPAN mirror holding the vetted (higher) version
MistTest::Mirror::make_mirror(
  File::Spec->catdir( $A, 'mpan-dist' ), [ 'Acme::MistCascade' => '0.02' ] );

# project B: a real mist project whose own mirror holds only the older version
_spew( File::Spec->catfile( $B, 'mistfile' ), "perl q{5.20.3};\n" );
_spew( File::Spec->catfile( $B, 'cpanfile' ), '' );
MistTest::Mirror::make_mirror(
  File::Spec->catdir( $B, 'mpan-dist' ), [ 'Acme::MistCascade' => '0.01' ] );

# --- produce --------------------------------------------------------------

# inject re-execs perlbrew via share/perlbrew-wrapper.bash, which requires
# MIST_APP_ROOT (mist itself does not set it before the exec - normally the
# sourced env does). Point it at the mist runtime ($repo) so the wrapper puts
# mist's lib and a cpanm on PATH; the target project is -C $B.
my ( $p_exit, $p_out ) = run( $Bhome,
  "cd $repo && MIST_APP_ROOT=$repo $mist -C $B inject --from $A --full-dependency-tree -n Acme::MistCascade" );
is $p_exit, 0, 'produce: inject --full-dependency-tree exits 0' or diag $p_out;

my ( $uuid ) = $p_out =~ m{--bundle\s+(\S+)};
ok $uuid, 'producer printed the apply line with a bundle id' or diag $p_out;

SKIP: {
  skip 'no bundle id produced', 3 unless $uuid;

  my $bundle_file = File::Spec->catfile(
    workspace( $Bhome, $B ), 'bundles', "$uuid.bundle" );
  ok -e $bundle_file, 'ephemeral bundle written under the redirected workspace'
    or diag "expected $bundle_file";

  like _slurp( $bundle_file ), qr/Acme::MistCascade~0\.02/,
    'producer floored on the PEER version 0.02 (peer-first clean-room resolve raised it)';

  ok scalar( glob File::Spec->catfile(
      $B, qw/ mpan-dist authors id /, '*', '*', '*', 'Acme-MistCascade-0.02.tar.gz' ) ),
    'producer vendored the peer tarball into the project mirror';
}

# --- publish --------------------------------------------------------------

SKIP: {
  skip 'no bundle id to publish', 3 unless $uuid;

  my ( $pub_exit, $pub_out ) = run( $Bhome,
    "cd $repo && $mist -C $B bundle publish $uuid --as cascade --description 'CVE smoke'" );
  is $pub_exit, 0, 'publish: mist bundle publish exits 0' or diag $pub_out;

  ok -e File::Spec->catfile( $B, qw/ mpan-dist bundles cascade.bundle / ),
    'published .bundle landed in the committed mirror';
  like _slurp( File::Spec->catfile( $B, qw/ mpan-dist bundles cascade.meta / ) ),
    qr/name: cascade/, 'published .meta records the name';
}

# --- apply ----------------------------------------------------------------

SKIP: {
  skip 'cannot apply without a published bundle', 3
    unless -e File::Spec->catfile( $B, qw/ mpan-dist bundles cascade.bundle / );

  my ( $c_exit, $c_out ) = run( $Bhome, "cd $repo && $mist -C $B compile" );
  is $c_exit, 0, 'compile B installer exits 0' or diag $c_out;

  my ( $a_exit, $a_out ) =
    run( $Bhome, "cd $B && ./mpan-install --bundle cascade" );
  is $a_exit, 0, 'apply: ./mpan-install --bundle cascade exits 0' or diag $a_out;

  my $pm = File::Spec->catfile(
    $B, 'perl5', $arch, qw/ lib perl5 Acme MistCascade.pm / );
  like _slurp( $pm ), qr/\$VERSION\s*=\s*'0\.02'/,
    'the applied environment carries the peer version 0.02, end to end'
    or diag "module at $pm:\n" . _slurp( $pm );
}

done_testing;
