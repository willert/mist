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

# mpan-install is a committed build artifact in the source repo, not shipped in
# the dist tarball, so this drift guard only runs from the real checkout.
plan skip_all => 'no committed mpan-install here (a dist/clean-room build)'
  unless -f $installer;

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

ARTIFACT_CARRIES_SWITCH_GUARD: {
  # Step-1 switch-guard: reaches the committed installer only via `mist compile`.
  like $src, qr/sub _switch_verdict/,
    'committed mpan-install carries the implicit-switch decision sub';
  like $src, qr/switch to \$target/,
    'committed mpan-install carries the interactive switch prompt';
}

ARTIFACT_CARRIES_GENERATION_INSTALL: {
  # Step-3 default-path CoW generations; reach the committed installer only via
  # `mist compile`, so they double as this changeset's drift guard.
  like $src, qr/sub _activate_generation/,
    'committed mpan-install carries the generation-activation helper';
  like $src, qr/generations/,
    'committed mpan-install installs into a perl5/generations/ container';
  like $src, qr/\$\{gen_name\}-build/,
    'committed mpan-install builds under a -build suffix (promoted on success)';
  like $src, qr/\.mist-built-/,
    'committed mpan-install stamps a .mist-built-<ts> completion marker';
  like $src, qr/defined \$resume and not \$resume/,
    'committed mpan-install carries the --no-resume clean-rebuild discard';
  like $src, qr/\$rebuild or \$continue_last_build or -d \$LOCAL_LIB_DIR/,
    'committed mpan-install carries the --rebuild / --continue-last-build seed-skip';
  like $src, qr/Failed to seed generation from/,
    'committed mpan-install falls back to a copy where hard links are unsupported';
  like $src, qr/%04d%02d%02dT%02d%02d%02dZ/,
    'committed mpan-install timestamps the completion marker';
  like $src, qr/unlink \$_ if \$_ eq 'perllocal\.pod'/,
    'committed mpan-install breaks the perllocal.pod hard-link when seeding';

  # the same-perl loud stub retired once installs stopped mutating the active env
  unlike $src, qr/Mist environment not fully installed/,
    'committed mpan-install no longer writes the loud same-perl build stub';
}

ARTIFACT_CARRIES_CONTINUE_LAST_BUILD_AND_ATOMIC_WRAPPER: {
  # --continue-last-build (resume a broken closure build) and the body/rc
  # staged-rename fix (a failed build never truncates the live mist-run wrapper)
  # reach the committed installer only via `mist compile`, so they double as the
  # drift guard for this changeset.
  like $src, qr/continue-last-build/,
    'committed mpan-install carries the --continue-last-build option';
  like $src, qr/No in-progress build to continue/,
    'committed mpan-install carries the strict no-partial guard for it';
  like $src, qr/rename\( \$body_new, \$body_fn \)/,
    'committed mpan-install renames the staged body into place (atomic, not truncate-in-place)';
  like $src, qr/rename\( \$rc_new, \$rc_fn \)/,
    'committed mpan-install renames the staged rc into place';
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
