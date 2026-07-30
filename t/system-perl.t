#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use File::Spec;
use File::Temp qw/ tempdir /;

# --system-perl builds against the perl already on the machine and manages only
# the library tree. Two halves are worth pinning without a perlbrew, an
# installer or a container:
#
#   _resolve_perl_version - the precedence that decides whether any perl is
#     managed at all. Everything else in perlbrew.pm short-circuits on its undef.
#   the marker            - the host-local record that makes the choice outlast
#     the run that made it, which is what stops a later plain ./mpan-install
#     from reverting a deploy box to the mistfile's pinned perl.
#
# Loading perlbrew.pm standalone runs its load-time @ARGV parse; harmless with
# no flags set, and the same require t/switch-verdict.t relies on.

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
require File::Spec->catfile( $repo, qw/ lib Mist Script perlbrew.pm / );

my $resolve = \&Mist::Script::perl::_resolve_perl_version;

PRECEDENCE: {
  is $resolve->( default => '5.20.3' ), '5.20.3',
    "the mistfile's pinned version is used when nothing overrides it";

  is $resolve->( explicit => '5.42.2', default => '5.20.3' ), '5.42.2',
    '--perlbrew outranks the pin';

  is $resolve->( env => '5.38.0', default => '5.20.3' ), '5.38.0',
    'a parent process that already selected a perl outranks the pin';

  is $resolve->( explicit => '5.42.2', env => '5.38.0', default => '5.20.3' ),
    '5.42.2', '...and the explicit flag outranks that in turn';

  is $resolve->(), undef,
    'no pin and no flags means no perl is managed at all';
}

SYSTEM_IS_THE_OPT_OUT: {
  # Every perlbrew step in the module opens with `return unless $pb_version`, so
  # resolving to undef is precisely "no perlbrew lookup, no re-exec, no switch
  # guard" - which is why --system-perl is silent rather than specially quiet.
  is $resolve->( explicit => 'system', default => '5.20.3' ), undef,
    '--system-perl overrides the pin and manages no perl';

  is $resolve->( persisted => 'system', default => '5.20.3' ), undef,
    'a persisted choice also overrides the pin - the box wins on the box';

  is $resolve->( explicit => '5.42.2', persisted => 'system' ), '5.42.2',
    '...but an explicit --perlbrew still wins over it, to hand the perl back';

  is $resolve->( env => '5.38.0', persisted => 'system' ), '5.38.0',
    'and so does an externally selected perl, so a re-exec is never undone';
}

MARKER_ROUND_TRIP: {
  my $root = tempdir( 'mist-system-perl-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  local $ENV{MIST_APP_ROOT} = $root;

  my $marker = Mist::Script::perl::_system_perl_marker();
  is $marker, File::Spec->catfile( $root, 'perl5', '.mist-system-perl' ),
    'the marker lives under perl5/, which is install output and never committed';

  ok ! Mist::Script::perl::_system_perl_persisted(),
    'a fresh checkout has no persisted choice';

  # perl5/ does not exist yet on a first install; recording must not depend on
  # the installer having got there first.
  Mist::Script::perl::_persist_system_perl( 'system' );
  ok Mist::Script::perl::_system_perl_persisted(),
    '--system-perl records the choice, creating perl5/ if needed';

  like slurp( $marker ), qr/mpan-install --system-perl/,
    '...in a file that says what it is and how to undo it';

  Mist::Script::perl::_persist_system_perl( '5.42.2' );
  ok ! Mist::Script::perl::_system_perl_persisted(),
    'choosing a perlbrew version hands the interpreter back and clears it';

  # Idempotent: a plain run must not clear a choice it was not asked about.
  Mist::Script::perl::_persist_system_perl( 'system' );
  Mist::Script::perl::_persist_system_perl( 'system' );
  ok Mist::Script::perl::_system_perl_persisted(),
    'recording twice is harmless';
}

sub slurp {
  my ( $file ) = @_;
  open my $fh, '<', $file or return '';
  local $/;
  return <$fh>;
}

done_testing;
