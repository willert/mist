#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use Cwd qw/ getcwd /;
use FindBin ();
use File::Spec;
use File::Temp qw/ tempdir /;
use lib "$FindBin::Bin/lib";

# A tag merge holds its sibling checkout alive through a _CleanupGuard whose
# DESTROY runs `git worktree remove`. When `mist merge` dies, that DESTROY runs
# while the die unwinds, after perl has already settled on a non-zero exit
# status - and a system() in there overwrites $?, which is what perl exits
# with. A failed merge then exits 0 and a `mist merge ... || fail` loop sails
# on. Only a child process can observe this: the exit status is the product.

eval { require App::Mist::Command::merge; 1 }
  or plan skip_all => "cannot load App::Mist::Command::merge: $@";

my $dir    = tempdir( CLEANUP => 1 );
my $marker = "$dir/cleaned";

my $child = <<'CODE';
  require App::Mist::Command::merge;
  my ( $marker ) = @ARGV;
  sub execute {
    my $guard = App::Mist::Command::merge::_CleanupGuard->new( sub {
      system $^X, '-e', '0';
      open my $fh, '>', $marker or die "Can't touch $marker: $!";
    });
    die "Merging Some-Dist-0.01.tar.gz failed\n";
  }
  execute();
CODE

my @inc = map { File::Spec->rel2abs( $_ ) } grep { !ref } @INC;

# App::Mist finds its project root one level above FindBin's directory, which
# for a -e script is the cwd - so the child runs from t/, where a real mist
# script sits relative to the root.
my $status = do {
  my $cwd = getcwd;
  chdir $FindBin::Bin or die "Can't chdir to $FindBin::Bin: $!";
  open my $saved, '>&', \*STDERR or die "Can't dup STDERR: $!";
  open STDERR, '>', "$dir/stderr" or die "Can't redirect STDERR: $!";
  system $^X, ( map { "-I$_" } @inc ), '-e', $child, $marker;
  my $exit = $?;
  open STDERR, '>&', $saved or die "Can't restore STDERR: $!";
  chdir $cwd or die "Can't chdir back to $cwd: $!";
  $exit;
};

like( do { local ( @ARGV, $/ ) = "$dir/stderr"; <> }, qr/Some-Dist-0\.01.*failed/,
  'the child died with the merge failure' );
ok( -e $marker, 'the guard ran its cleanup while the die unwound' );
isnt( $status, 0, 'a die with a live cleanup guard still exits non-zero' )
  or diag sprintf 'child exited %d', $status >> 8;

done_testing;
