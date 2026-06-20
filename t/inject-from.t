#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Temp qw/ tempdir /;
use Path::Class qw/ dir /;

# `mist inject --from <peer>` is wired by constructing the MPAN package manager
# with mirror_only and an added peer mirror (see App::Mist::Command::inject).
# These assertions lock the resulting cpanm option surface: peer-sourced,
# mirror-only, no live-CPAN fallback, project mirror consulted first. Run under
# the project env (./mist-run prove) - loading MPAN needs the vendored Moo stack.
eval { require Mist::PackageManager::MPAN; 1 }
  or plan skip_all => "cannot load Mist::PackageManager::MPAN: $@";

# MIST_APP_ROOT would add another file mirror via _build_mirror_list; drop it so
# the mirror list is just the project mirror (+ peer / cpan.org as applicable).
delete local $ENV{MIST_APP_ROOT};

my $tmp = dir( tempdir( 'mist-inject-from-XXXXXX', TMPDIR => 1, CLEANUP => 1 ) );

sub manager {
  Mist::PackageManager::MPAN->new({
    project_root => $tmp,
    local_lib    => $tmp->subdir( 'local-lib' ),
    workspace    => $tmp->subdir( 'workspace' ),
    @_,
  });
}

sub mirrors_of {
  my @opt = @_;
  return map { $opt[ $_ + 1 ] } grep { $opt[ $_ ] eq '--mirror' } 0 .. $#opt;
}

PLAIN_INJECT_REACHES_CPAN: {
  my @opt = manager()->cpanm_install_options;
  ok( ( grep { $_ eq 'http://www.cpan.org/' } @opt ),
    'a plain inject keeps cpan.org in the mirror list' );
  ok( !( grep { $_ eq '--mirror-only' } @opt ),
    'a plain inject is not mirror-only' );
}

INJECT_FROM_IS_PEER_SOURCED_AND_FAIL_LOUD: {
  my $peer = 'file:///some/peer/mpan-dist/';
  my $mgr  = manager( mirror_only => 1 );
  $mgr->add_mirror( $peer );
  my @opt = $mgr->cpanm_install_options;

  ok( ( grep { $_ eq '--mirror-only' } @opt ),
    '--from resolves mirror-only' );
  ok( ( grep { $_ eq '--cascade-search' } @opt ),
    '--from cascades through the mirror list' );
  ok( ( grep { $_ eq $peer } @opt ),
    'the peer mpan-dist is in the mirror list' );
  ok( !( grep { $_ eq 'http://www.cpan.org/' } @opt ),
    'no live-CPAN fallback under --from (the fail-loud contract)' );

  my @mirrors = mirrors_of( @opt );
  like "$mirrors[0]", qr{mpan-dist/?\z},
    "this project's own mpan-dist is consulted first";
  is "$mirrors[-1]", $peer,
    'the peer mirror is appended last, so it never downgrades a local version';
}

done_testing;
