#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

use File::Temp qw/ tempdir /;
use File::Spec;

# `mist upgrade --from <peer>` raises this project's mpan-dist to the versions a
# peer has vendored. The decision is an index-to-index diff (never the mutable
# ./perl5): _read_index reads an mpan-dist's 02packages, _raise_plan computes the
# raise-only, intersection-only set. Run under ./mist-run prove (loads App::Mist
# and the vendored index reader; _read_index tests build a tiny real mirror).
eval { require App::Mist::Command::upgrade; require MistTest::Mirror; 1 }
  or plan skip_all => "cannot load upgrade command / mirror helper: $@";

sub read_index { App::Mist::Command::upgrade::_read_index( @_ ) }
sub raise_plan { App::Mist::Command::upgrade::_raise_plan( @_ ) }

# _vendor_raise prints index chatter (and an obsolete-tarball report) we don't
# want in TAP; run it with both streams to devnull.
sub vendor_raise {
  open my $saveout, '>&', \*STDOUT or die $!;
  open my $saveerr, '>&', \*STDERR or die $!;
  open STDOUT, '>', File::Spec->devnull or die $!;
  open STDERR, '>', File::Spec->devnull or die $!;
  App::Mist::Command::upgrade::_vendor_raise( @_ );
  open STDOUT, '>&', $saveout or die $!;
  open STDERR, '>&', $saveerr or die $!;
}

my $tmp = tempdir( 'mist-raiseplan-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

# ---- _read_index against a real mist-built mirror -------------------------
READ_INDEX: {
  my $mirror = MistTest::Mirror::make_mirror(
    File::Spec->catdir( $tmp, 'read' ),
    [ 'Acme::RaiseA' => '1.0' ],
    [ 'Acme::RaiseB' => '2.5' ],
  );
  my $idx = read_index( $mirror );

  is $idx->{'Acme::RaiseA'}{version}, '1.0',
    '_read_index reads the version from a real index';
  like $idx->{'Acme::RaiseA'}{path}, qr{Acme-RaiseA-1\.0\.tar\.gz$},
    '_read_index reads the dist path';
  ok exists $idx->{'Acme::RaiseB'}, '_read_index sees every package';

  my $missing = read_index(
    Path::Class::dir( File::Spec->catdir( $tmp, 'does-not-exist' ) ) );
  is_deeply $missing, {}, '_read_index of an absent mirror is empty, not fatal';
}

# ---- _raise_plan over two real mirrors ------------------------------------
REAL_TWO_MIRROR_DIFF: {
  my $mine = read_index( MistTest::Mirror::make_mirror(
    File::Spec->catdir( $tmp, 'mine' ), [ 'Acme::Up' => '1.0' ] ) );
  my $peer = read_index( MistTest::Mirror::make_mirror(
    File::Spec->catdir( $tmp, 'peer' ), [ 'Acme::Up' => '1.1' ] ) );

  my ( $raise, $amb, $tarball ) = raise_plan( $mine, $peer );
  is scalar @$raise, 1,            'peer ahead -> one raise';
  is $raise->[0][0], 'Acme::Up',   '  the right package';
  is $raise->[0][2], '1.1',        '  to the peer version';
  is scalar keys %$tarball, 1,     '  one tarball to copy';
  is scalar @$amb, 0,              '  nothing ambiguous';
}

# ---- _raise_plan decision edges (synthetic maps) --------------------------
RAISE_ONLY_NEVER_DOWNGRADE: {
  my $mine = { Foo => { version => '2.0', path => 'm/Foo-2.0.tar.gz' } };
  my $peer = { Foo => { version => '1.0', path => 'p/Foo-1.0.tar.gz' } };
  my ( $raise, $amb ) = raise_plan( $mine, $peer );
  is scalar @$raise, 0, 'peer behind -> no raise (never downgrade)';
  is scalar @$amb,   0, '  and not flagged ambiguous';
}

EQUAL_IS_NOOP: {
  my $mine = { Foo => { version => '1.0', path => 'm/Foo-1.0.tar.gz' } };
  my $peer = { Foo => { version => '1.0', path => 'p/Foo-1.0.tar.gz' } };
  my ( $raise, $amb ) = raise_plan( $mine, $peer );
  is scalar @$raise, 0, 'equal version -> no raise';
  is scalar @$amb,   0, 'equal strings -> not ambiguous';
}

POINT_RELEASE_ORDERING: {
  my $mine = { Foo => { version => '1.9',  path => 'm/Foo-1.9.tar.gz' } };
  my $peer = { Foo => { version => '1.10', path => 'p/Foo-1.10.tar.gz' } };
  my ( $raise ) = raise_plan( $mine, $peer );
  is scalar @$raise, 1,    '1.9 < 1.10 (point release) -> raise';
  is $raise->[0][2], '1.10', '  to 1.10';
}

AMBIGUOUS_DECIMAL_IS_SURFACED: {
  # The documented comparator edge: 0.05 and 0.5 collapse to equal. Must NOT be
  # a silent skip - it has to surface as ambiguous so a real raise is not lost.
  my $mine = { Foo => { version => '0.05', path => 'm/Foo-0.05.tar.gz' } };
  my $peer = { Foo => { version => '0.5',  path => 'p/Foo-0.5.tar.gz' } };
  my ( $raise, $amb ) = raise_plan( $mine, $peer );
  is scalar @$raise, 0, '0.05 vs 0.5 collapses -> not silently raised';
  is scalar @$amb,   1, '  surfaced as ambiguous instead';
  is $amb->[0][0], 'Foo', '  naming the package';
}

INTERSECTION_ONLY: {
  my $mine = { 'Only::Mine' => { version => '1.0', path => 'm/o.tar.gz' } };
  my $peer = { 'Only::Peer' => { version => '9.0', path => 'p/o.tar.gz' } };
  my ( $raise ) = raise_plan( $mine, $peer );
  is scalar @$raise, 0,
    'packages not present in both indexes are ignored (no adoption)';
}

DEDUP_TARBALL: {
  # Two packages provided by one peer tarball collapse to a single copy.
  my $mine = {
    'Dist::A' => { version => '1.0', path => 'm/Dist-1.0.tar.gz' },
    'Dist::B' => { version => '1.0', path => 'm/Dist-1.0.tar.gz' },
  };
  my $peer = {
    'Dist::A' => { version => '2.0', path => 'p/Dist-2.0.tar.gz' },
    'Dist::B' => { version => '2.0', path => 'p/Dist-2.0.tar.gz' },
  };
  my ( $raise, $amb, $tarball ) = raise_plan( $mine, $peer );
  is scalar @$raise, 2,        'both packages flagged to raise';
  is scalar keys %$tarball, 1, '  but deduped to one tarball copy';
}

# ---- _vendor_raise: copy + reindex end-to-end on real mirrors -------------
VENDOR_RAISE_END_TO_END: {
  my $mine_dir = Path::Class::dir( File::Spec->catdir( $tmp, 'vr-mine' ) );
  my $peer_dir = Path::Class::dir( File::Spec->catdir( $tmp, 'vr-peer' ) );
  MistTest::Mirror::make_mirror( $mine_dir, [ 'Acme::Vendor' => '1.0' ] );
  MistTest::Mirror::make_mirror( $peer_dir, [ 'Acme::Vendor' => '1.1' ] );

  my ( $raise, undef, $tarball ) =
    raise_plan( read_index( $mine_dir ), read_index( $peer_dir ) );
  is scalar @$raise, 1, 'plan finds the raise before vendoring';

  vendor_raise( $mine_dir, $peer_dir, $tarball );

  my $after = read_index( $mine_dir );
  is $after->{'Acme::Vendor'}{version}, '1.1',
    'after _vendor_raise, mine index points at the raised version';
  like $after->{'Acme::Vendor'}{path}, qr{Acme-Vendor-1\.1\.tar\.gz$},
    '  and at the copied-in tarball';
  ok -f $mine_dir->subdir(qw/ authors id /)->file( $after->{'Acme::Vendor'}{path} ),
    '  which physically exists under mine/authors/id';
}

done_testing;
