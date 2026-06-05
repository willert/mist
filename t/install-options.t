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

ARTIFACT_CARRIES_SYMLINK_ACTIVATION: {
  # Step-1 restructure: per-perl wrapper bodies, atomic symlink activation and
  # the --build-only flag. These reach the committed installer only through
  # `mist compile`, so they double as the drift guard for this changeset.
  like $src, qr/sub _activate_symlink/,
    'committed mpan-install carries the atomic symlink-activation helper';
  like $src, qr/mist-run-\$arch_path/,
    'committed mpan-install builds per-perl wrapper bodies (mist-run-<ver>-<arch>)';
  like $src, qr/\bbuild-only\b/,
    'committed mpan-install carries the --build-only option';
}

HEAD_READABLE_VERSION_MARKER: {
  # Not a drift check (those are the greps above) - this guards the nudge-infra
  # invariant that compile stamps a parseable version marker near the top of
  # every installer, for all time. Structure only: it exists, parses, and is
  # head-readable - never a specific version value (that would re-conflate it
  # with the change-specific greps and go stale every release).
  my @head = ( split /\n/, $src )[ 0 .. 4 ];
  my ( $line ) = grep { defined && /App::Mist version\s+\d/ } @head;
  ok $line,
    'mpan-install carries a head-readable version marker (for the staleness nudge)';

  my ( $version ) = ( $line // '' ) =~ /App::Mist version\s+(\d+(?:\.\d+)*)/;
  like $version // '', qr/\A\d+(?:\.\d+)*\z/,
    'the version marker parses to a dotted version number';
}

done_testing;
