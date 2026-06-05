#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use File::Spec;

# mpan-install is a fatpacked, committed build artifact: editing lib/ without
# re-running `mist compile` leaves it stale. These assertions guard that the
# install-option surface in the committed artifact tracks the source - the same
# source-vs-artifact-drift guard ARTIFACT_CARRIES_THE_FIX uses in
# t/script-perlbrew-stdin.t.

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
my $installer = File::Spec->catfile( $repo, 'mpan-install' );

my $src = do {
  open my $fh, '<', $installer or die "open mpan-install: $!";
  local $/; <$fh>;
};

ARTIFACT_DROPS_ALL_AVAILABLE_VERSIONS: {
  unlike $src, qr/all-available-versions/,
    'committed mpan-install no longer carries the --all-available-versions option';
  unlike $src, qr/finally re-run default so all symlinks/,
    'committed mpan-install no longer carries the all-versions reset-pass loop';
}

ARTIFACT_KEEPS_VERSION_LISTING_HELPER: {
  # list_available_perl_versions looks dead once the all-versions loop is gone,
  # but assert_availability_of_requested_perl_version still calls it. Guards
  # against over-removal.
  like $src, qr/sub list_available_perl_versions/,
    'list_available_perl_versions survives (still used by the availability check)';
}

done_testing;
