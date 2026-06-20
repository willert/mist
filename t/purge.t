#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Temp qw/ tempdir /;
use File::Spec;
use File::Path qw/ mkpath /;

# Loading the command pulls in App::Mist, whose BEGIN needs this repo's perl5 env
# for the running perl (run this under ./mist-run prove). Skip cleanly otherwise.
eval { require App::Mist::Command::purge; 1 }
  or plan skip_all => "cannot load App::Mist::Command::purge: $@";

my $arch  = 'perl-5.20.3-x86_64-linux';
my $arch2 = 'perl-5.38.0-x86_64-linux';

# --- _generations_to_purge: the pure classifier -----------------------------

sub purge_names { App::Mist::Command::purge::_generations_to_purge( @_ ) }

{
  my @names = (
    "$arch-1", "$arch-2", "$arch-3",
    "$arch-2-build",      # stale interrupted build
    "$arch-stable",       # named branch
    "$arch-experiment",   # named branch
  );
  my %active = ( "$arch-3" => 1 );

  is_deeply [ sort { $a cmp $b } purge_names( \@names, \%active, 0 ) ],
    [ sort "$arch-1", "$arch-2", "$arch-2-build" ],
    'default keeps active + named branches, removes other numbered gens and stale -build';

  is_deeply [ sort { $a cmp $b } purge_names( \@names, \%active, 1 ) ],
    [ sort "$arch-1", "$arch-2", "$arch-2-build", "$arch-experiment", "$arch-stable" ],
    '--include-branches also sweeps non-active named branches';
}

is_deeply [ purge_names( [ "$arch-1" ], { "$arch-1" => 1 }, 0 ) ], [],
  'an active generation is never removed even when auto-numbered';

is_deeply
  [ sort { $a cmp $b } purge_names(
      [ "$arch-1", "$arch-2", "$arch2-1", "$arch2-2" ],
      { "$arch-2" => 1, "$arch2-2" => 1 }, 0 ) ],
  [ sort "$arch-1", "$arch2-1" ],
  'all-perls: each arch keeps its active gen, older numbered ones in both go';

# --- _purge_generations: scan + delete against a real tree -------------------

# Run a coderef with the command's chatter swallowed, returning its result list.
sub quietly (&) {
  my $code = shift;
  local *STDOUT;
  open STDOUT, '>', \my $sink or die "redirect STDOUT: $!";
  return $code->();
}

sub make_gen {
  my ( $gens, $name ) = @_;
  my $dir = File::Spec->catdir( $gens, $name );
  mkpath $dir;
  open my $fh, '>', File::Spec->catfile( $dir, 'FILE' ) or die $!;
  print $fh "content\n";
  return $dir;
}

# build perl5/generations/ with an active selector, run the purge, assert
sub build_tree {
  my $proj  = tempdir( 'mist-purge-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  my $perl5 = File::Spec->catdir( $proj, 'perl5' );
  my $gens  = File::Spec->catdir( $perl5, 'generations' );
  mkpath $gens;
  make_gen( $gens, $_ ) for "$arch-1", "$arch-2", "$arch-3",
    "$arch-2-build", "$arch-stable";
  symlink "generations/$arch-3", File::Spec->catdir( $perl5, $arch )
    or die "selector symlink: $!";
  return ( $perl5, $gens );
}

{
  my ( $perl5, $gens ) = build_tree();

  my @would = quietly { App::Mist::Command::purge::_purge_generations(
    $perl5, dry_run => 1 ) };
  is_deeply [ sort @would ], [ sort "$arch-1", "$arch-2", "$arch-2-build" ],
    'dry-run reports the gens it would remove';
  ok -d File::Spec->catdir( $gens, "$arch-1" ), 'dry-run deletes nothing';

  my @removed = quietly { App::Mist::Command::purge::_purge_generations(
    $perl5, dry_run => 0 ) };
  is_deeply [ sort @removed ], [ sort "$arch-1", "$arch-2", "$arch-2-build" ],
    'live run removes the same set';
  ok ! -e File::Spec->catdir( $gens, "$arch-1" ),     'gen 1 removed';
  ok ! -e File::Spec->catdir( $gens, "$arch-2" ),     'gen 2 removed';
  ok ! -e File::Spec->catdir( $gens, "$arch-2-build" ), 'stale -build removed';
  ok   -d File::Spec->catdir( $gens, "$arch-3" ),     'active generation kept';
  ok   -d File::Spec->catdir( $gens, "$arch-stable" ), 'named branch kept';
}

{
  # --include-branches sweeps the named branch too
  my ( $perl5, $gens ) = build_tree();
  my @would = quietly { App::Mist::Command::purge::_purge_generations(
    $perl5, dry_run => 1, include_branches => 1 ) };
  ok( ( grep { $_ eq "$arch-stable" } @would ),
    '--include-branches lists the non-active named branch' );
}

{
  # multiple perls: each arch's active selector protects its own generation
  my $proj  = tempdir( 'mist-purge-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  my $perl5 = File::Spec->catdir( $proj, 'perl5' );
  my $gens  = File::Spec->catdir( $perl5, 'generations' );
  mkpath $gens;
  make_gen( $gens, $_ ) for "$arch-1", "$arch-2", "$arch2-1", "$arch2-2";
  symlink "generations/$arch-2",  File::Spec->catdir( $perl5, $arch )  or die $!;
  symlink "generations/$arch2-2", File::Spec->catdir( $perl5, $arch2 ) or die $!;

  my @removed = quietly { App::Mist::Command::purge::_purge_generations(
    $perl5, dry_run => 0 ) };
  is_deeply [ sort @removed ], [ sort "$arch-1", "$arch2-1" ],
    'all-perls live run keeps each active gen, removes the older ones';
  ok -d File::Spec->catdir( $gens, "$arch-2" ),  'arch 1 active kept';
  ok -d File::Spec->catdir( $gens, "$arch2-2" ), 'arch 2 active kept';
}

{
  # --perlbrew scopes the sweep to one perl version; the other is untouched
  my $proj  = tempdir( 'mist-purge-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  my $perl5 = File::Spec->catdir( $proj, 'perl5' );
  my $gens  = File::Spec->catdir( $perl5, 'generations' );
  mkpath $gens;
  make_gen( $gens, $_ ) for "$arch-1", "$arch-2", "$arch2-1", "$arch2-2";
  symlink "generations/$arch-2",  File::Spec->catdir( $perl5, $arch )  or die $!;
  symlink "generations/$arch2-2", File::Spec->catdir( $perl5, $arch2 ) or die $!;

  my @removed = quietly { App::Mist::Command::purge::_purge_generations(
    $perl5, dry_run => 0, perlbrew => '5.20.3' ) };
  is_deeply [ @removed ], [ "$arch-1" ],
    '--perlbrew scopes the purge to just that perl version';
  ok -d File::Spec->catdir( $gens, "$arch2-1" ),
    'the other perl version is left untouched (even its superseded gens)';
  ok -d File::Spec->catdir( $gens, "$arch2-2" ), 'including its active gen';
  ok -d File::Spec->catdir( $gens, "$arch-2" ),  'the targeted active gen is kept';
}

{
  # no generations/ dir at all: graceful no-op, no die
  my $proj  = tempdir( 'mist-purge-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  my $perl5 = File::Spec->catdir( $proj, 'perl5' );
  mkpath $perl5;
  my @removed = quietly { App::Mist::Command::purge::_purge_generations(
    $perl5, dry_run => 0 ) };
  is_deeply [ @removed ], [], 'no generations dir -> nothing removed, no error';
}

done_testing;
