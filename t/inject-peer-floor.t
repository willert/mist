#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

use File::Temp qw/ tempdir /;
use File::Spec;

# A bare `mist inject --from <peer> Module` should pull the peer's version rather
# than silently resolving to this project's own copy. _peer_floor implements that:
# it rewrites a bare module target into a >= floor at the peer's indexed version,
# and leaves explicit specs / tarballs / paths alone. Run under ./mist-run prove
# (loads App::Mist and the vendored index reader; builds a tiny real mirror).
eval { require App::Mist::Command::inject; require MistTest::Mirror; 1 }
  or plan skip_all => "cannot load inject command / mirror helper: $@";

sub floor { App::Mist::Command::inject::_peer_floor( @_ ) }

my $tmp  = tempdir( 'mist-peerfloor-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $peer = MistTest::Mirror::make_mirror(
  File::Spec->catdir( $tmp, 'peer' ), [ 'Acme::MistFloor' => '0.02' ] );

BARE_TARGET_IS_FLOORED_TO_PEER_VERSION: {
  is floor( 'Acme::MistFloor', [ $peer ] ), 'Acme::MistFloor~0.02',
    'a bare module is pinned to the peer version as a floor';
}

EXPLICIT_SPECS_PASS_THROUGH: {
  is floor( 'Acme::MistFloor@0.01', [ $peer ] ), 'Acme::MistFloor@0.01',
    'an @ version is left untouched';
  is floor( 'Acme::MistFloor~1.0', [ $peer ] ), 'Acme::MistFloor~1.0',
    'a ~ range is left untouched';
  is floor( 'AUTHOR/Acme-MistFloor-0.02.tar.gz', [ $peer ] ),
    'AUTHOR/Acme-MistFloor-0.02.tar.gz', 'an author/path tarball is left untouched';
  is floor( './local.tar.gz', [ $peer ] ), './local.tar.gz',
    'a local path is left untouched';
}

BARE_TARGET_ABSENT_FROM_PEER_FAILS_LOUD: {
  ok !eval { floor( 'Acme::NotInPeer', [ $peer ] ); 1 },
    'a bare target not in any peer mirror is a loud failure, not a silent no-op';
  like $@, qr/not in any peer mpan-dist/, 'and the error says so';
}

HIGHEST_ACROSS_PEERS_WINS: {
  my $older = MistTest::Mirror::make_mirror(
    File::Spec->catdir( $tmp, 'older' ), [ 'Acme::MistFloor' => '0.01' ] );
  # peers listed older-then-newer; the floor should still be the highest (0.02)
  is floor( 'Acme::MistFloor', [ $older, $peer ] ), 'Acme::MistFloor~0.02',
    'with multiple peers the highest version is chosen as the floor';
}

done_testing;
