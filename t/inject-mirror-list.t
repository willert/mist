#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

use File::Temp qw/ tempdir /;
use Path::Class qw/ dir /;

# inject / merge resolve from the project's OWN mpan-dist (prepended by the
# around-modifier) plus any explicit --from peers, and live CPAN unless pinned to
# the mirrors. A set $MIST_APP_ROOT - mist's own repo, or a leaked/stale value from
# a sourced env - must NOT slip an extra mirror into the list: that vestigial
# env-var mirror is what made inject's output look like it vendored into mist's own
# mpan-dist rather than this project's. Run under ./mist-run prove.
eval { require Mist::PackageManager::MPAN; 1 }
  or plan skip_all => "cannot load Mist::PackageManager::MPAN: $@";

sub pm {
  my %args = @_;
  my $root = dir( tempdir( 'mist-ml-XXXXXX', TMPDIR => 1, CLEANUP => 1 ) );
  return Mist::PackageManager::MPAN->new(
    project_root => $root,
    local_lib    => $root->subdir( 'local' ),
    %args,
  );
}

MIRROR_LIST_IGNORES_MIST_APP_ROOT: {
  local $ENV{MIST_APP_ROOT} = '/some/other/mist-root';
  my $m       = pm();
  my $root    = "" . $m->project_root;
  my @mirrors = $m->mirror_list;

  ok +( grep { index( $_, $root ) >= 0 } @mirrors ),
    "the project's own mpan-dist is in the mirror list";
  ok !( grep { index( $_, '/some/other/mist-root' ) >= 0 } @mirrors ),
    'a set MIST_APP_ROOT adds no mirror (the vestigial env-var mirror is gone)';
  ok +( grep { m{cpan\.org} } @mirrors ),
    'live CPAN is present by default';
}

MIRROR_ONLY_DROPS_CPAN_AND_STILL_IGNORES_MIST_APP_ROOT: {
  local $ENV{MIST_APP_ROOT} = '/some/other/mist-root';
  my @mirrors = pm( mirror_only => 1 )->mirror_list;

  ok !( grep { m{cpan\.org} } @mirrors ),
    'mirror_only drops live CPAN';
  ok !( grep { index( $_, '/some/other/mist-root' ) >= 0 } @mirrors ),
    'mirror_only still ignores MIST_APP_ROOT';
}

done_testing;
