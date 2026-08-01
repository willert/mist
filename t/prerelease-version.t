#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use version 0.77 ();

# The version arithmetic of the prerelease cycle. These three properties are
# what the whole scheme rests on, so they are asserted directly rather than
# through a release run:
#
#   a prerelease sorts ABOVE the version it was cut from,
#   BELOW the release it leads to,
#   and therefore cannot satisfy a requirement for that release.

eval { require Minilla::Release::BumpPrerelease; 1 }
  or plan skip_all => "cannot load BumpPrerelease: $@";
eval { require Minilla::Release::BumpVersionSmart; 1 }
  or plan skip_all => "cannot load BumpVersionSmart: $@";

my $next    = \&Minilla::Release::BumpPrerelease::next_prerelease;
my $promote = \&Minilla::Release::BumpVersionSmart::_promote;

ADVANCING: {
  is $next->('0.52'),    '0.52_01', 'a stable version gains a trial component';
  is $next->('0.52_01'), '0.52_02', '...which then advances';
  is $next->('0.52_09'), '0.52_10', '...across the decade boundary';
  isnt $next->('0.52_01'), $next->('0.52'),
    'no two iterations share a version, which is the point';
}

PROMOTING: {
  is $promote->('0.52_02'), '0.53',
    'a release drops the trial component rather than advancing it';
  is $promote->('0.52_01'), '0.53', '...from anywhere in the line';
  isnt $promote->('0.52_02'), $next->('0.52_02'),
    'promoting is not the same as another prerelease';
}

ORDERING: {
  # The reason the counter hangs off the current version instead of the target.
  my @line = ( '0.52', $next->('0.52'), $next->( $next->('0.52') ) );
  my $rel  = $promote->( $line[-1] );

  for my $i ( 1 .. $#line ) {
    # Parenthesised: `ok version->parse(...)` would parse as `version->ok(...)`.
    ok( version->parse( $line[$i] ) > version->parse( $line[ $i - 1 ] ),
        "$line[$i] sorts above $line[$i-1]" );
  }
  ok( version->parse( $rel ) > version->parse( $line[-1] ),
      "the release $rel sorts above every prerelease leading to it" );
}

FLOOR_REFUSES_A_PRERELEASE: {
  # The safety property: a consumer requiring the release must not accept a
  # prerelease of it. This is what would break if the counter hung off the
  # target version (0.53_01 sorts ABOVE 0.53).
  my $trial   = $next->('0.52');
  my $release = $promote->( $trial );

  ok( version->parse( $trial ) < version->parse( $release ),
      "$trial does not meet a requirement for $release" );

  ok( version->parse( "${release}_01" ) > version->parse( $release ),
      "...whereas ${release}_01 would exceed it, which is why that spelling is wrong" );
}

TRIAL_VERSIONS_ARE_RECOGNISABLE: {
  # Everything downstream keys on is_alpha - the doctor check, the compile-time
  # warning - so the versions this produces have to answer to it.
  ok( version->parse( $next->('0.52') )->is_alpha,
      'a prerelease reports itself as a trial release' );
  ok( !version->parse( $promote->('0.52_01') )->is_alpha,
      'and a promoted release does not' );
}

done_testing;
