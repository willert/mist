#!/bin/env perl

use strict;
use Test::More;

use FindBin qw/ $RealBin /;
use File::Spec;

use Mist::Distribution;
use Mist::Environment;

SIMPLE: {
  my $env = Mist::Environment->new(
    File::Spec->catfile( $RealBin, qw/ share mistfile.simple/ )
  );

  my $dist = $env->parse;

  # note explain $dist;

  pass 'Parsing simple mistfile';
}

MERGEND: {
  my $env = Mist::Environment->new(
    File::Spec->catfile( $RealBin, qw/ share mistfile.merged/ )
  );

  my $dist = $env->parse;

  # note explain $dist;

  is_deeply [$dist->get_prepended_modules], [qw/Another::Module An::Module/],
    'Merged prepends'
}

done_testing;
