#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Path qw/ mkpath /;
use File::Spec;
use File::Temp qw/ tempdir /;

# Mist::Generation is the copy-on-write generation ladder, shared by ./mpan-install
# (fatpacked) and by the build-master commands that move the live environment
# forward. It is deliberately core-only, so it loads without the project env.
#
# t/mpan-install-activation.t covers the ladder through real installs; this covers
# the decisions directly - the counter, the seed-parent precedence, and the
# promote/activate mechanics - which a full install can only exercise one path of
# at a time.
require_ok( 'Mist::Generation' );

my $tmp  = tempdir( 'mist-generation-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $arch = 'perl-5.20.3-x86_64-linux';

# Whether this filesystem can hard-link, so the copy-on-write assertion can be
# skipped rather than failed where it is impossible.
my $can_link = do {
  my $a = File::Spec->catfile( $tmp, 'probe' );
  open my $fh, '>', $a or die $!; close $fh;
  my $ok = link $a, File::Spec->catfile( $tmp, 'probe2' );
  unlink $a, File::Spec->catfile( $tmp, 'probe2' );
  $ok;
};

# A fresh perl5/ tree per scenario, so the cases cannot leak into each other.
my $box = 0;
sub sandbox {
  my $base = File::Spec->catdir( $tmp, 'box' . ++$box, 'perl5' );
  mkpath( File::Spec->catdir( $base, 'generations' ) );
  return $base;
}

sub touch {
  my ( @path ) = @_;
  my $file = File::Spec->catfile( @path );
  mkpath( ( File::Spec->splitpath( $file ) )[1] );
  open my $fh, '>', $file or die "$file: $!";
  print $fh "x\n";
  close $fh;
  return $file;
}

# seed() reports to STDOUT; keep that off the TAP stream and assert on it instead.
sub quietly {
  my ( $code ) = @_;
  my $out = '';
  open my $saved, '>&STDOUT' or die "save STDOUT: $!";
  close STDOUT;
  open STDOUT, '>', \$out or die "capture STDOUT: $!";
  my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
  close STDOUT;
  open STDOUT, '>&', $saved or die "restore STDOUT: $!";
  die $err if defined $err;
  return $out;
}

ARCH_PATH_AND_PATHS: {
  is( Mist::Generation::arch_path( '5.20.3', 'x86_64-linux' ), $arch,
    'arch_path is perl-<version>-<archname>' );
  is( Mist::Generation::container( 'perl5' ),
    File::Spec->catdir( 'perl5', 'generations' ), 'generations container' );
  is( Mist::Generation::build_dir( 'gens', "$arch-4" ), "gens/$arch-4-build",
    'a build carries the -build suffix' );
  is( Mist::Generation::final_dir( 'gens', "$arch-4" ), "gens/$arch-4",
    'and is promoted to the bare name' );
}

NEXT_NAME_COUNTS_COMPLETED_GENERATIONS: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );

  is( Mist::Generation::next_name( container => $gens, arch_path => $arch ),
    "$arch-1", 'first generation is 1' );

  mkpath( File::Spec->catdir( $gens, "$arch-$_" ) ) for 1, 3;
  is( Mist::Generation::next_name( container => $gens, arch_path => $arch ),
    "$arch-4", 'the counter is one past the highest, not a gap-filler' );

  # An interrupted build must not consume a number: the counter is what makes a
  # re-run land on the same -build dir and resume it.
  mkpath( File::Spec->catdir( $gens, "$arch-9-build" ) );
  is( Mist::Generation::next_name( container => $gens, arch_path => $arch ),
    "$arch-4", 'a leftover -build dir does not raise the counter' );

  # Another perl's generations are a different series entirely.
  mkpath( File::Spec->catdir( $gens, 'perl-5.38.0-x86_64-linux-7' ) );
  is( Mist::Generation::next_name( container => $gens, arch_path => $arch ),
    "$arch-4", "another perl's generations do not raise this counter" );

  is( Mist::Generation::next_name(
      container => $gens, arch_path => $arch, branch => 'wip' ),
    "$arch-wip", 'a named branch bypasses the counter' );
}

SEED_SOURCE_PRECEDENCE: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );
  mkpath( File::Spec->catdir( $gens, "$arch-1" ) );
  mkpath( File::Spec->catdir( $gens, "$arch-2" ) );
  mkpath( File::Spec->catdir( $gens, "$arch-wip" ) );

  my %common = (
    perl5_base => $base, container => $gens,
    arch_path => $arch, gen_name => "$arch-3",
  );

  is( Mist::Generation::seed_source( %common, parent => '1' ),
    File::Spec->catdir( $gens, "$arch-1" ),
    'an explicit parent wins' );

  eval { Mist::Generation::seed_source( %common, parent => 'nope' ) };
  like( $@, qr/Parent generation .* doesn't exist/,
    'a missing explicit parent is a loud failure, not a silent fallback' );

  is( Mist::Generation::seed_source(
      %common, gen_name => "$arch-wip", branch => 'wip' ),
    File::Spec->catdir( $gens, "$arch-wip" ),
    'reinstalling a named branch seeds from that branch itself' );

  # No selector yet: a first install has nothing to inherit.
  is( Mist::Generation::seed_source( %common ), undef,
    'with no selector and no legacy dir there is nothing to seed from' );

  # The normal case: the selector symlink names the active generation.
  symlink( File::Spec->catdir( 'generations', "$arch-2" ),
    File::Spec->catdir( $base, $arch ) )
    or plan skip_all => 'cannot create symlinks here';
  is( Mist::Generation::seed_source( %common ),
    File::Spec->catdir( $base, 'generations', "$arch-2" ),
    'otherwise the generation the selector points at' );
}

SEED_SOURCE_MIGRATES_A_LEGACY_LIB_DIR: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );
  # Pre-ladder layout: perl5/<arch_path> is a real directory, not a selector.
  mkpath( File::Spec->catdir( $base, $arch ) );

  is( Mist::Generation::seed_source(
      perl5_base => $base, container => $gens,
      arch_path  => $arch, gen_name  => "$arch-1" ),
    File::Spec->catdir( $base, $arch ),
    'a legacy real lib dir is seeded from in place' );
}

STAGE_SEEDS_COPY_ON_WRITE: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );
  my $live = File::Spec->catdir( $gens, "$arch-1" );
  my $installed = touch( $live, 'lib', 'perl5', 'Installed.pm' );
  touch( $live, 'lib', 'perl5', 'x86_64-linux', 'perllocal.pod' );
  touch( $live, '.mist-built-20260101T000000Z' );
  symlink( File::Spec->catdir( 'generations', "$arch-1" ),
    File::Spec->catdir( $base, $arch ) ) or die "symlink: $!";

  my $build = Mist::Generation::build_dir( $gens, "$arch-2" );
  my $said  = quietly( sub {
    Mist::Generation::stage(
      build_dir  => $build,      perl5_base => $base,
      container  => $gens,       arch_path  => $arch,
      gen_name   => "$arch-2",
    );
  });

  like( $said, qr/Seeding generation \Q$arch-2\E from/, 'the seed is announced' );
  ok( -f File::Spec->catfile( $build, 'lib', 'perl5', 'Installed.pm' ),
    'the build dir inherits the live generation' );

  SKIP: {
    skip 'no hard links on this filesystem', 1 unless $can_link;
    my @a = stat $installed;
    my @b = stat File::Spec->catfile( $build, 'lib', 'perl5', 'Installed.pm' );
    is( "$b[0]:$b[1]", "$a[0]:$a[1]", 'inherited files share inodes, not bytes' );
  }

  # The two things written in place rather than installed anew: left hard-linked,
  # perllocal's append would reach into the live generation and the inherited
  # marker would misreport when this generation was built.
  ok( ! -e File::Spec->catfile(
      $build, 'lib', 'perl5', 'x86_64-linux', 'perllocal.pod' ),
    'perllocal.pod is not inherited' );
  is_deeply( [ glob File::Spec->catfile( $build, '.mist-built-*' ) ], [],
    "the parent's build marker is not inherited" );
}

STAGE_RETRY_POLICY: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );
  my $live = File::Spec->catdir( $gens, "$arch-1" );
  touch( $live, 'lib', 'perl5', 'Installed.pm' );
  symlink( File::Spec->catdir( 'generations', "$arch-1" ),
    File::Spec->catdir( $base, $arch ) ) or die "symlink: $!";

  my $build = Mist::Generation::build_dir( $gens, "$arch-2" );
  my %common = (
    build_dir  => $build, perl5_base => $base,
    container  => $gens,  arch_path  => $arch, gen_name => "$arch-2",
  );

  # A leftover partial is resumed as-is: whatever already built is kept.
  mkpath( $build );
  my $partial = touch( $build, 'half-built' );
  quietly( sub { Mist::Generation::stage( %common ) } );
  ok( -f $partial, 'an existing build dir is resumed, not reseeded' );
  ok( ! -e File::Spec->catfile( $build, 'lib', 'perl5', 'Installed.pm' ),
    '...and is not re-seeded over' );

  # --no-resume: discard the partial and seed again.
  quietly( sub { Mist::Generation::stage( %common, discard => 1 ) } );
  ok( ! -e $partial, 'discard drops the partial' );
  ok( -f File::Spec->catfile( $build, 'lib', 'perl5', 'Installed.pm' ),
    '...and reseeds from the live generation' );

  # --rebuild: discard and skip the seed, so the build is a true clean room.
  quietly( sub {
    Mist::Generation::stage( %common, discard => 1, no_seed => 1 ) } );
  ok( ! -e File::Spec->catfile( $build, 'lib', 'perl5', 'Installed.pm' ),
    'no_seed leaves an empty clean room' );
}

PROMOTE_STAMPS_AND_RENAMES: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );
  my $build = Mist::Generation::build_dir( $gens, "$arch-2" );
  touch( $build, 'lib', 'perl5', 'Installed.pm' );
  touch( $build, '.mist-built-20200101T000000Z' );   # inherited via a seed

  my $final = Mist::Generation::promote(
    build_dir => $build,
    final     => Mist::Generation::final_dir( $gens, "$arch-2" ),
  );

  is( $final, File::Spec->catdir( $gens, "$arch-2" ), 'promote returns the final path' );
  ok( ! -e $build, 'the -build dir is gone' );
  ok( -f File::Spec->catfile( $final, 'lib', 'perl5', 'Installed.pm' ),
    'the tree moved with it' );

  my @marker = glob File::Spec->catfile( $final, '.mist-built-*' );
  is( scalar @marker, 1, 'exactly one build marker' );
  unlike( $marker[0], qr/20200101T000000Z/,
    'the inherited marker is replaced, so it dates this generation' );
}

PROMOTE_REPLACES_A_NAMED_GENERATION: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );
  my $existing = File::Spec->catdir( $gens, "$arch-wip" );
  my $old = touch( $existing, 'old-content' );
  # Model what is actually on disk: EUMM installs modules read-only. A writable
  # fixture would let the reclaim pass here while reclaiming nothing in reality.
  chmod 0444, $old;
  chmod 0555, $existing;
  my $build = Mist::Generation::build_dir( $gens, "$arch-wip" );
  touch( $build, 'new-content' );

  Mist::Generation::promote(
    build_dir => $build, final => $existing, branch => 'wip' );

  ok( -f File::Spec->catfile( $existing, 'new-content' ),
    'a named-branch reinstall replaces the named generation' );
  ok( ! -f File::Spec->catfile( $existing, 'old-content' ),
    '...with the new build, not a merge of both' );
  is_deeply( [ glob File::Spec->catfile( $gens, '*.superseded-*' ) ], [],
    'and the superseded copy is reclaimed' );
}

ACTIVATE: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );
  mkpath( File::Spec->catdir( $gens, "$arch-1" ) );
  my $generic = File::Spec->catdir( $base, $arch );
  my $rel     = File::Spec->catdir( 'generations', "$arch-1" );

  Mist::Generation::activate( $generic, $rel );
  ok( -l $generic, 'activation makes the selector a symlink' );
  is( readlink $generic, $rel, '...pointing at the generation, relative to perl5/' );

  my $stamp = File::Spec->catfile( $base, 'etc', 'mist.active-generation' );
  my $read_stamp = sub {
    open my $fh, '<', $stamp or return undef; local $/; <$fh> };
  is( $read_stamp->(), "$rel\n",
    'activation writes the stamp restarters watch, naming the generation' );

  # A swap is just a repoint, which is what makes rollback free.
  mkpath( File::Spec->catdir( $gens, "$arch-2" ) );
  my $rel2 = File::Spec->catdir( 'generations', "$arch-2" );
  Mist::Generation::activate( $generic, $rel2 );
  is( readlink $generic, $rel2, 'a later generation is activated by repointing' );
  is( $read_stamp->(), "$rel2\n", 'the stamp follows the swap' );

  # An in-place change (mist local) stamps without passing a generation name:
  # the name is read from the selector, the mtime bump is the signal.
  unlink $stamp;
  Mist::Generation::stamp_active_generation( $generic );
  is( $read_stamp->(), "$rel2\n",
    'a bare stamp call reads the active generation from the selector' );
}

ACTIVATE_MIGRATES_A_LEGACY_LIB_DIR: {
  my $base = sandbox();
  my $gens = Mist::Generation::container( $base );
  mkpath( File::Spec->catdir( $gens, "$arch-1" ) );
  my $generic = File::Spec->catdir( $base, $arch );
  mkpath( $generic );                       # pre-ladder real directory
  my $legacy = touch( $generic, 'legacy-file' );
  # Read-only, as every EUMM-installed module is. This is the fixture detail that
  # decides whether the reclaim is real: File::Path's safe mode skips anything the
  # process cannot write, so a writable fixture passes while the live migration
  # leaves the whole tree behind.
  chmod 0444, $legacy;
  chmod 0555, $generic;

  Mist::Generation::activate(
    $generic, File::Spec->catdir( 'generations', "$arch-1" ) );

  ok( -l $generic, 'a legacy real lib dir becomes a selector symlink' );
  is_deeply( [ glob "${generic}.legacy-*" ], [],
    'and the read-only old directory entry is still fully reclaimed' );
  ok( -f File::Spec->catfile( $base, 'etc', 'mist.active-generation' ),
    'the migration path also writes the activation stamp' );
}

ACTIVATE_REFUSES_WHAT_IT_CANNOT_CLASSIFY: {
  my $base = sandbox();
  my $generic = File::Spec->catdir( $base, $arch );
  touch( $generic );   # a plain file where the selector belongs

  eval { Mist::Generation::activate( $generic, 'generations/whatever' ) };
  like( $@, qr/neither a symlink nor a directory/,
    'a selector path that is neither link nor dir is refused, not clobbered' );
}

done_testing;
