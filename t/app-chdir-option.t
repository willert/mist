#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Cwd ();
use File::Temp ();

# Loading App::Mist triggers its BEGIN, which resolves the project perl5/
# relative to $RealBin - absent in the clean-room dist work dir. Skip under
# RELEASE_TESTING (mist's own release dist-test); this runs normally via
# ./mist-run prove, and the helper it covers needs no install.
BEGIN {
  plan skip_all => 'needs the full mist install (perl5/); run via ./mist-run prove'
    if $ENV{RELEASE_TESTING};
}

use App::Mist;

# Pull leading -C options off a copy of argv; returns (\@paths, \@remaining).
sub split_argv {
  my @argv  = @_;
  my @paths = App::Mist->_shift_chdir_paths( \@argv );
  return ( \@paths, \@argv );
}

PARSING: {
  my ( $paths, $rest ) = split_argv(qw( compile ));
  is_deeply( $paths, [], 'no -C: nothing extracted' );
  is_deeply( $rest, [qw( compile )], 'argv left untouched' );

  ( $paths, $rest ) = split_argv( '-C', '/a', 'compile' );
  is_deeply( $paths, ['/a'], '-C <path> (two tokens)' );
  is_deeply( $rest, ['compile'], 'option consumed, command preserved' );

  ( $paths, $rest ) = split_argv( '-C/a', 'compile' );
  is_deeply( $paths, ['/a'], '-C<path> (attached)' );

  ( $paths, $rest ) = split_argv( '-C=/a', 'compile' );
  is_deeply( $paths, ['/a'], '-C=<path>' );

  ( $paths ) = split_argv( '-C', '/a', '-C', 'sub', 'compile' );
  is_deeply( $paths, [ '/a', 'sub' ], 'multiple -C extracted in order' );

  ( $paths, $rest ) = split_argv( 'run', '-C', '/a' );
  is_deeply( $paths, [], 'only leading -C are options' );
  is_deeply( $rest, [qw( run -C /a )], 'a -C after the command passes through' );

  ( $paths ) = split_argv( '-C', '', 'compile' );
  is_deeply( $paths, [''], '-C "" extracted as empty (run() skips the chdir)' );
}

MISSING_ARG: {
  my @argv = ('-C');
  my $ok = eval { App::Mist->_shift_chdir_paths( \@argv ); 1 };
  ok( !$ok, '-C with no path dies' );
  like( $@, qr/requires a path/, 'with a helpful message' );
}

CHDIR: {
  my $start = Cwd::getcwd();
  my $tmp   = File::Temp->newdir;
  my $real  = Cwd::realpath( "$tmp" );

  # Same extract-then-chdir that run() performs, without dispatching the app.
  my @argv = ( '-C', $real, 'lib_paths' );
  for my $path ( App::Mist->_shift_chdir_paths( \@argv ) ) {
    next unless length $path;
    chdir $path or die "chdir $path: $!";
  }
  is( Cwd::realpath( Cwd::getcwd() ), $real, '-C changes the working directory' );
  is_deeply( \@argv, ['lib_paths'], 'command survives the chdir extraction' );

  chdir $start or die "restore cwd: $!";
}

done_testing;
