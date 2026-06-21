#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

use File::Temp qw/ tempdir /;
use File::Spec;

# The load-bearing assumption behind `inject --full-dependency-tree`: under
# `--mirror-only --cascade-search`, cpanm resolves a requirement to the version
# in the FIRST mirror whose copy satisfies it - so listing a peer's mirror before
# the project's own raises a shared dep to the peer's version, and listing it
# after never could. This pins that behaviour directly against two hermetic
# mirrors holding the same module at different versions; if a cpanm upgrade ever
# changes it, the failure points here rather than at the whole bundle pipeline.
#
# Run under the project env (./mist-run prove): it needs the vendored indexer and
# a cpanm. Builds real (tiny) dists, so it also needs a working toolchain.

eval { require MistTest::Mirror; 1 }
  or plan skip_all => "cannot load test mirror helper: $@";

require File::Which;
my $cpanm = File::Which::which( 'cpanm' )
  or plan skip_all => 'cpanm not on PATH';

my $tmp  = tempdir( 'mist-cascade-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
# Keep cpanm's work tree (HOME/.cpanm/work) inside the cleaned $tmp instead of
# polluting the real ~/.cpanm.
local $ENV{HOME} = $tmp;
my $high = MistTest::Mirror::make_mirror(
  File::Spec->catdir( $tmp, 'high' ), [ 'Acme::MistCascade' => '0.02' ] );
my $low  = MistTest::Mirror::make_mirror(
  File::Spec->catdir( $tmp, 'low' ),  [ 'Acme::MistCascade' => '0.01' ] );

# Install Acme::MistCascade with the two mirrors in the given order and report
# the version that actually landed. Bare requirement, so BOTH mirrors satisfy it
# and only the order decides which is taken.
sub resolved_version {
  my ( $first, $second ) = @_;
  my $lib = tempdir( 'mist-cascade-lib-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

  my @cmd = (
    $cpanm,
    '--quiet', '--notest',
    '--local-lib-contained' => $lib,
    '--mirror' => MistTest::Mirror::url( $first ),
    '--mirror' => MistTest::Mirror::url( $second ),
    '--mirror-only', '--cascade-search',
    'Acme::MistCascade',
  );
  my $rc = system { $cmd[0] } @cmd;
  return "(install failed, rc=$rc)" unless $rc == 0;

  my $pm = File::Spec->catfile(
    $lib, qw/ lib perl5 Acme MistCascade.pm / );
  open my $fh, '<', $pm or return "(not installed)";
  while ( my $line = <$fh> ) {
    return $1 if $line =~ /\$VERSION\s*=\s*'([^']+)'/;
  }
  return "(no version)";
}

is resolved_version( $high, $low ), '0.02',
  'peer-first: the first mirror that satisfies wins, raising to its version';

is resolved_version( $low, $high ), '0.01',
  'order decides: a higher version in a later mirror does NOT win under cascade-search';

done_testing;
