#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use FindBin ();
use File::Spec;

# install.pm computes the prepend and notest module lists once, from the
# mistfile compiled into the installer (DISTRIBUTION->distinfo), and guards
# each result:
#
#   our $PREPEND_DISTS   ||= eval {[ DISTRIBUTION->distinfo->get_prepended_modules ]};
#   die '$PREPEND_DISTS not set' . $@ unless $PREPEND_DISTS;
#
#   our $DONT_TEST_DISTS ||= eval {[ DISTRIBUTION->distinfo->get_modules_not_to_test ]};
#   die '$DONT_TEST_DISTS not set' . $@ unless $DONT_TEST_DISTS;
#
# Those two `die ... unless` lines are load-bearing and trivial to delete in a
# refactor. The contract they encode:
#
#   - The eval can only fail by DYING (a broken DISTRIBUTION). A mistfile that
#     legitimately declares nothing returns [] - a truthy arrayref - so the
#     guard passes and the install proceeds with no prepend/notest, correctly.
#   - On eval failure the result is undef (falsy), and the guard aborts with the
#     original $@ attached.
#
# If the guard were dropped, an eval failure would leave the list undef and the
# run would behave as though NO modules were prepended or marked notest -
# silently dropping every prepend and notest, including those folded in from
# merge blocks (see t/distribution-verbs.t), with no error. Computing these
# lists must stay fail-loud, never fail-empty. This pins that contract in both
# the source and the fatpacked installer.

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );

# Each list is computed under eval and then immediately guarded by die-unless;
# matching them together pins the adjacency (the die must guard THAT eval).
my $prepend_guard =
  qr/\$PREPEND_DISTS \|\|= eval \{\[ DISTRIBUTION->distinfo->get_prepended_modules \]\};\s+die '\$PREPEND_DISTS not set' \. \$\@ unless \$PREPEND_DISTS;/;

my $notest_guard =
  qr/\$DONT_TEST_DISTS \|\|= eval \{\[ DISTRIBUTION->distinfo->get_modules_not_to_test \]\};\s+die '\$DONT_TEST_DISTS not set' \. \$\@ unless \$DONT_TEST_DISTS;/;

sub slurp {
  my ( $path ) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  local $/;
  return <$fh>;
}

SOURCE_KEEPS_THE_FAIL_LOUD_GUARD: {
  # The source of truth ships in the dist, so this runs everywhere.
  my $src = slurp( File::Spec->catfile(
    $repo, qw/ lib Mist Script install.pm / ) );

  like $src, $prepend_guard,
    'install.pm aborts (does not silently empty) when the prepend list cannot be computed';
  like $src, $notest_guard,
    'install.pm aborts (does not silently empty) when the notest list cannot be computed';
}

ARTIFACT_CARRIES_THE_FAIL_LOUD_GUARD: {
  # The committed mpan-install is a build artifact, not shipped in the dist
  # tarball, so this only runs from the real checkout (cf. t/install-options.t).
  my $installer = File::Spec->catfile( $repo, 'mpan-install' );
  SKIP: {
    skip 'no committed mpan-install here (a dist/clean-room build)', 2
      unless -f $installer;

    my $src = slurp( $installer );
    like $src, $prepend_guard,
      'compile carried the prepend fail-loud guard into the fatpacked installer';
    like $src, $notest_guard,
      'compile carried the notest fail-loud guard into the fatpacked installer';
  }
}

done_testing;
