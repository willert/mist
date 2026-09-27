package Mist::Signals;

# Signal dispositions a build must not inherit. POSIX starts every asynchronous
# list of a non-interactive shell (`cmd &` in a script, a detached remote job)
# with SIGINT and SIGQUIT ignored, and an ignored disposition survives exec -
# through the perlbrew re-exec, cpanm and make, down to a dist's test suite. A
# test that interrupts its own child (Test::TCP's t/05_sigint.t) then fails,
# and cpanm abandons every dist that depends on it: the symptom lands dozens of
# dists away from the cause and never names it. No build is backgrounded in
# order to ignore Ctrl-C, so the default is restored rather than the run
# refused.
#
# SIGHUP is deliberately left alone: nohup ignores it on purpose, so that a
# build survives the terminal that started it.
#
# Shared by ./mpan-install (fatpacked, like Mist::Generation) and the mist CLI,
# so it is held to the host's constraints: core only, no dependencies.

use strict;
use warnings;

our @RESTORED = qw/ INT QUIT /;

# Reset each inherited ignore to the default and warn once, naming the
# signals, when anything had to change. Returns the names that were reset.
sub restore_inherited_ignores {
  my ( $program ) = @_;

  my @reset;
  for my $name ( @RESTORED ) {
    next unless defined $SIG{ $name } and $SIG{ $name } eq 'IGNORE';
    $SIG{ $name } = 'DEFAULT';
    push @reset, $name;
  }
  return unless @reset;

  warn sprintf "%s: %s arrived ignored (inherited from a background job of a\n"
    . "non-interactive shell?); restored the default so builds and tests receive %s.\n",
    $program, join( ' and ', map { "SIG$_" } @reset ), @reset > 1 ? 'them' : 'it';
  return @reset;
}

1;
