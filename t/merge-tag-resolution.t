#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

# `mist merge` defaults to the sibling's newest stable release tag; --trial
# widens the pick to _NN prereleases and --release pins an exact version.
# _select_release_tag is the pure step: given the tag names reachable from the
# sibling's HEAD, decide which one gets built.
#
# The invariants under test: only version-shaped tags are visible at all,
# ordering and equality follow version.pm rather than string comparison (0.9
# beats 0.10, 0.52_01 sits between 0.52 and 0.53), and trial tags are
# unreachable without an explicit --trial or --release.

eval { require App::Mist::Command::merge; 1 }
  or plan skip_all => "cannot load App::Mist::Command::merge: $@";

sub pick { App::Mist::Command::merge::_select_release_tag( @_ ) }

my @estate = qw/ 0.51 0.52 0.52_01 0.52_02 release-checkpoint-0.41 wip /;

is( pick( \@estate )->{tag}, '0.52',
  'bare pick is the newest stable tag, trials skipped' );
ok( ! pick( \@estate )->{trial}, '...and it is not marked trial' );

is( pick( \@estate, trial => 1 )->{tag}, '0.52_02',
  '--trial picks the newest tag including prereleases' );
ok( pick( \@estate, trial => 1 )->{trial}, '...marked as trial' );

is( pick( [qw/ 0.53 0.52_02 /], trial => 1 )->{tag}, '0.53',
  'a stable release ends the trial line: 0.53 outranks 0.52_02' );

is( pick( \@estate, release => '0.52_01' )->{tag}, '0.52_01',
  '--release reaches an exact trial tag' );
is( pick( \@estate, release => '0.51' )->{tag}, '0.51',
  '--release reaches an older stable tag' );
is( pick( \@estate, release => '0.9' ), undef,
  '--release misses cleanly when no tag matches' );

is( pick( [qw/ v0.53 0.52 /] )->{tag}, 'v0.53',
  'v-prefixed tags are version-shaped too' );
is( pick( [qw/ v0.53 0.52 /], release => '0.53' )->{tag}, 'v0.53',
  '--release without the v prefix still finds a v-prefixed tag' );
is( pick( [qw/ 0.53 0.52 /], release => 'v0.53' )->{tag}, '0.53',
  '...and the other way around' );

is( pick( [qw/ 0.9 0.10 /] )->{tag}, '0.9',
  'ordering is version semantics, not string order: 0.9 > 0.10' );

is( pick( [] ), undef, 'no tags, no pick' );
is( pick( [qw/ release-checkpoint-0.41 wip /] ), undef,
  'non-version tags are invisible' );
is( pick( [qw/ 0.52_01 /] ), undef,
  'a bare pick never falls back to a trial tag' );
is( pick( [qw/ 0.52_01 /], trial => 1 )->{tag}, '0.52_01',
  '...but --trial reaches it' );

my $died = !eval { pick( 'not-a-ref' ); 1 };
ok( $died, 'a non-arrayref tag list is a refused contract violation' );

$died = !eval { pick( [qw/ 0.52 /], release => 'not.a.version' ); 1 };
ok( $died, 'an unparseable --release value dies instead of matching nothing' );

done_testing;
