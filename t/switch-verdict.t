#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use File::Spec;

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
my $perlbrew_pm = File::Spec->catfile(
  $repo, qw/ lib Mist Script perlbrew.pm / );

# _switch_verdict is pure (every input arrives as an argument); loading
# perlbrew.pm just to reach it runs its load-time @ARGV parse, harmless with no
# --perlbrew set. This is the same standalone-require the stdin test relies on.
require $perlbrew_pm;

my $verdict = \&Mist::Script::perl::_switch_verdict;

# The two short-circuits come first and outrank the active/target comparison.
is $verdict->( build_only => 1, explicit => 0,
               active => '5.20.3', target => '5.42.2', interactive => 1 ),
  'proceed', '--build-only never switches, even across a version change';

is $verdict->( build_only => 0, explicit => 1,
               active => '5.20.3', target => '5.42.2', interactive => 0 ),
  'proceed', 'explicit --perlbrew is its own confirmation (no prompt, no refuse)';

is $verdict->( build_only => 1, explicit => 0,
               active => '5.20.3', target => '5.42.2', interactive => 0 ),
  'proceed', '--build-only outranks a would-be non-interactive refusal';

# No active selector means a fresh workdir or an old single-file layout: there
# is nothing to switch away from, so first install is never guarded.
is $verdict->( build_only => 0, explicit => 0,
               active => undef, target => '5.20.3', interactive => 0 ),
  'proceed', 'a fresh workdir (no active selector) is never guarded';

is $verdict->( build_only => 0, explicit => 0,
               active => '5.20.3', target => '5.20.3', interactive => 0 ),
  'proceed', 'no switch when the target equals the active perl';

# Implicit switch (bare install onto a different perl) is the guarded case.
is $verdict->( build_only => 0, explicit => 0,
               active => '5.20.3', target => '5.42.2', interactive => 1 ),
  'confirm', 'implicit switch on a tty asks for confirmation';

is $verdict->( build_only => 0, explicit => 0,
               active => '5.20.3', target => '5.42.2', interactive => 0 ),
  'refuse', 'implicit switch without a tty is refused (deploy/CI safety)';

done_testing;
