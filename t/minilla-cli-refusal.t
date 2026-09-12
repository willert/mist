#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Capture::Tiny qw/ capture /;

use Minilla::Logger ();
use Mist::Minilla::CLI ();

# Minilla::CLI->run swallows Minilla::Error::CommandExit - the exception every
# refusing release step throws through errorf - so a caller embedding Minilla
# sees success after "Unknown local files" or a wrong release branch, and goes
# on: a dry-run stamped its candidate and printed "validated" after the
# untracked-files check had refused. Mist::Minilla::CLI::run_command turns the
# refusal into a die and leaves every other exception alone.

# Command classes defined here rather than loaded from disk; the %INC entries
# satisfy use_module.
{
  package Minilla::CLI::Refusing;
  sub run { Minilla::Logger::errorf( "Unknown local files:\n%s\n", 'stray.txt' ) }

  package Minilla::CLI::Crashing;
  sub run { die "boom\n" }

  package Minilla::CLI::Passing;
  our @seen;
  our $auto_install;
  sub run {
    my ( $class, @args ) = @_;
    @seen         = @args;
    $auto_install = $Minilla::AUTO_INSTALL;
    return 'ignored';
  }
}
$INC{"Minilla/CLI/$_.pm"} = __FILE__ for qw/ Refusing Crashing Passing /;

REFUSAL_IS_AN_ERROR: {
  my $died;
  my ( $out, $err ) = capture {
    eval { Mist::Minilla::CLI::run_command( refusing => '--dry-run' ); 1 }
      or $died = $@;
  };
  ok $died, 'a step refusal makes run_command die';
  like $died, qr/^mist: minil refusing stopped at a step that refused; see its message above\.$/,
    'with a one-line message pointing at the step\'s own';
  like $out . $err, qr/Unknown local files:\nstray\.txt/,
    'and the step\'s refusal was printed before it';
}

OTHER_EXCEPTIONS_PASS_THROUGH: {
  my $died;
  capture {
    eval { Mist::Minilla::CLI::run_command( 'crashing' ); 1 } or $died = $@;
  };
  is $died, "boom\n", 'an ordinary exception is rethrown unchanged';
}

SUCCESS_IS_SILENT: {
  my $died;
  my ( $out, $err ) = capture {
    eval { Mist::Minilla::CLI::run_command( passing => qw/ --no-test extra / ); 1 }
      or $died = $@;
  };
  ok !$died, 'a passing command does not die' or diag $died;
  is_deeply \@Minilla::CLI::Passing::seen, [ qw/ --no-test extra / ],
    'the arguments reach the command untouched';
  is $Minilla::CLI::Passing::auto_install, 1,
    'with AUTO_INSTALL set as Minilla::CLI->run sets it';
  ok !$Minilla::AUTO_INSTALL, 'and restored afterwards';
  is $out . $err, q{}, 'printing nothing of its own';
}

UNKNOWN_COMMAND: {
  my $died;
  capture {
    eval { Mist::Minilla::CLI::run_command( 'no_such_command_here' ); 1 } or $died = $@;
  };
  like $died, qr/Can't locate Minilla\/CLI\/No_such_command_here\.pm/,
    'an unknown command fails to load, loudly';
}

done_testing;
