#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use File::Spec;
use lib File::Spec->catdir( $FindBin::Bin, File::Spec->updir, 'lib' );

use Mist::Signals ();

sub restore_capturing_warnings {
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  my @reset = Mist::Signals::restore_inherited_ignores( 'mist-test' );
  return ( \@reset, \@warnings );
}

BOTH_IGNORED: {
  local $SIG{INT}  = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{HUP}  = 'IGNORE';
  my ( $reset, $warnings ) = restore_capturing_warnings();

  is_deeply $reset, [qw/ INT QUIT /], 'both inherited ignores are reset';
  is $SIG{INT},  'DEFAULT', 'SIGINT is back to the default';
  is $SIG{QUIT}, 'DEFAULT', 'SIGQUIT is back to the default';
  is $SIG{HUP},  'IGNORE',  'SIGHUP is left ignored (nohup means it)';
  is scalar @$warnings, 1, 'one notice';
  like $warnings->[0], qr/^mist-test: SIGINT and SIGQUIT arrived ignored/,
    'naming the program and both signals';
  like $warnings->[0], qr/receive them\.$/m, 'in the plural';
}

ONE_IGNORED: {
  local $SIG{INT}  = 'IGNORE';
  local $SIG{QUIT} = 'DEFAULT';
  my ( $reset, $warnings ) = restore_capturing_warnings();

  is_deeply $reset, [qw/ INT /], 'only the ignored signal is reset';
  like $warnings->[0], qr/: SIGINT arrived ignored/, 'the notice names it alone';
  like $warnings->[0], qr/receive it\.$/m, 'in the singular';
}

NOTHING_IGNORED: {
  my $handler = sub { };
  local $SIG{INT}  = $handler;
  local $SIG{QUIT} = 'DEFAULT';
  my ( $reset, $warnings ) = restore_capturing_warnings();

  is_deeply $reset, [], 'nothing to reset';
  is_deeply $warnings, [], 'and no notice';
  is $SIG{INT}, $handler, 'an installed handler is left alone';
}

# The real thing: a non-interactive sh starts `cmd &` with SIGINT/SIGQUIT
# ignored, and only the reset makes a grandchild see the default again.
my $report = q{print defined $SIG{INT} ? $SIG{INT} : q{default}};
my $perl   = $^X;
my $lib    = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir, 'lib' ) );

# Runs @cmd as `sh -c '"$@" & wait $!'`, stderr folded into stdout; list form,
# so no argument passes through shell quoting.
sub in_background {
  my ( @cmd ) = @_;
  open my $fh, '-|', 'sh', '-c', '"$@" 2>&1 & wait $!', 'sh', @cmd
    or die "sh: $!";
  local $/;
  my $out = <$fh>;
  close $fh;
  return defined $out ? $out : '';
}

SKIP: {
  my $baseline = in_background( $perl, '-e', $report );
  skip "this sh does not ignore SIGINT in background jobs (got '$baseline')", 2
    unless $baseline eq 'IGNORE';
  pass 'precondition: a background job of sh inherits SIGINT ignored';

  my $reset_then_exec = q{use Mist::Signals ();}
    . q{ local $SIG{__WARN__} = sub {};}
    . q{ Mist::Signals::restore_inherited_ignores( q{t} );}
    . qq{ exec \$^X, q{-e}, q{$report}};
  is in_background( $perl, "-I$lib", '-e', $reset_then_exec ), 'default',
    'after the reset, an exec\'d child sees the default disposition';
}

# The CLI resets at the top of App::Mist::run, before any command can fork.
SKIP: {
  my $mist = do { my $p = `command -v mist 2>/dev/null`; chomp $p; $p };
  skip 'mist not on PATH', 2 unless length $mist and -x $mist;

  # mist must run in its own perl context, not the pinned env of ./mist-run
  local %ENV = %ENV;
  delete @ENV{qw/
    PERL5LIB PERL5OPT MIST_PERLBREW_VERSION MIST_APP_ROOT MIST_PERL5_LIBDIR
    PERLBREW_PERL PERL_LOCAL_LIB_ROOT PERL_MM_OPT PERL_MB_OPT
  /};

  my $background = in_background( $mist, '--version' );
  like $background, qr/^mist: SIGINT and SIGQUIT arrived ignored/m,
    'mist started as a background job says it restored the default';

  my $foreground = `'$mist' --version 2>&1`;
  unlike $foreground, qr/arrived ignored/, 'a foreground mist stays quiet';
}

done_testing;
