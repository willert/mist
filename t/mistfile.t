#!/bin/env perl

use strict;
use Test::More;

use FindBin qw/ $RealBin /;
use File::Spec;

use Mist::Distribution;
use Mist::Environment;

my $env = Mist::Environment->new(
  File::Spec->catfile( $RealBin, qw/ share mistfile.simple/ )
);

my $dist = $env->parse;

note explain $dist;

pass 'OK!';

done_testing;
