#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

use Mist::Distribution;
use Mist::Environment;

# `mist init` is the build-master one-shot: it vendors every mistfile directive
# dist into mpan-dist so the host's ./mpan-install can build it. _injection_plan
# is the pure step that turns the parsed mistfile + raw cpanfile prereqs into the
# four inject lists; this pins that a ccflags dist is among them (the wiring that
# lets the host's own scheduled build of a ccflags dist resolve mirror-only rather
# than fail). The inject -> mpan-dist vendoring itself is covered end to end by
# t/bundle-lifecycle.t; here we only assert init plans to inject the right dists.
eval { require App::Mist::Command::init; 1 }
  or plan skip_all => "cannot load App::Mist::Command::init: $@";

sub plan_for {
  my ( $src, @prereqs ) = @_;
  my $dist = Mist::Environment->new->parse( source => $src );
  return App::Mist::Command::init::_injection_plan( $dist, @prereqs );
}

CCFLAGS_DIST_IS_PLANNED_FOR_INJECTION: {
  my $p = plan_for( 'ccflags q{Acme::Foo} => q{-DX};', 'Other::Prereq' );
  is_deeply $p->{ccflags}, [ 'Acme::Foo' ],
    'a ccflags-only dist is planned for injection into mpan-dist';
  is_deeply $p->{prereqs}, [ 'Other::Prereq' ],
    'an unrelated bulk prereq is left in the prereq list';
}

CCFLAGS_PREREQ_PICKS_UP_VERSION: {
  # A ccflags dist that is also a cpanfile prereq is dropped from the bulk list and
  # injected pinned to the prereq's version (no double inject, vendored at the pin).
  my $p = plan_for( 'ccflags q{Acme::Foo} => q{-DX};', 'Acme::Foo~2.0', 'Other' );
  is_deeply $p->{ccflags}, [ 'Acme::Foo~2.0' ],
    'a ccflags dist that is also a prereq picks up the prereq version';
  is_deeply $p->{prereqs}, [ 'Other' ],
    'and is removed from the bulk prereq list';
}

PREPEND_NOTEST_CCFLAGS_ALL_PLANNED: {
  my $p = plan_for(
    'prepend q{Pre::One}; notest q{No::Test}; ccflags q{Cc::Dist} => q{-g};',
    'Bulk::Dep' );
  is_deeply $p->{prepend}, [ 'Pre::One' ], 'prepend dist planned for injection';
  is_deeply $p->{notest},  [ 'No::Test' ], 'notest dist planned for injection';
  is_deeply $p->{ccflags}, [ 'Cc::Dist' ], 'ccflags dist planned for injection';
  is_deeply $p->{prereqs}, [ 'Bulk::Dep' ], 'unrelated bulk prereq stays';
}

EMPTY_MISTFILE_PLANS_ONLY_PREREQS: {
  my $p = plan_for( 'perl q{5.20.3};', 'Just::A::Prereq' );
  is_deeply $p->{prepend}, [], 'no prepend dists';
  is_deeply $p->{notest},  [], 'no notest dists';
  is_deeply $p->{ccflags}, [], 'no ccflags dists';
  is_deeply $p->{prereqs}, [ 'Just::A::Prereq' ], 'bulk prereq passes through';
}

done_testing;
