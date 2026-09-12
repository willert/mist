package Mist::Minilla::CLI;

# Runs a Minilla command class the way Minilla::CLI->run does - the same two
# globals set, the command's own option parsing untouched - with one
# difference: a step's refusal reaches the caller.
#
# Minilla::CLI::run wraps the command in a try/catch whose `return` on
# Minilla::Error::CommandExit only leaves the catch block, so run() finishes
# normally. The step has printed its refusal (Unknown local files, a wrong
# release branch, no origin) and the caller sees success. Embedded in mist
# that made a dry-run re-stamp its candidate and print "validated" after
# CheckUntrackedFiles had refused, and a real release would have gone on to
# build a tarball. Here the exception becomes a die, which a mist command
# reports with a nonzero exit and nothing after the refusal runs.

use strict;
use warnings;

use Module::Runtime qw/ use_module /;
use Scalar::Util qw/ blessed /;
use Try::Tiny;

sub run_command {
  my ( $command, @args ) = @_;
  my $klass = use_module( 'Minilla::CLI::' . ucfirst $command );

  local $Minilla::AUTO_INSTALL  = 1;
  local $Minilla::Logger::COLOR = -t STDOUT ? 1 : 0;

  try {
    $klass->run( @args );
  } catch {
    my $error = $_;
    die "mist: minil $command stopped at a step that refused; see its message above.\n"
      if blessed $error and $error->isa( 'Minilla::Error::CommandExit' );
    die $error;
  };
  return;
}

1;

__END__

=pod

=head1 NAME

Mist::Minilla::CLI - run a Minilla command so that a refusal is an error

=head1 SYNOPSIS

  use Mist::Minilla::CLI ();
  Mist::Minilla::CLI::run_command( release => '--dry-run' );

=head1 DESCRIPTION

C<run_command( $command, @args )> loads C<Minilla::CLI::E<lt>CommandE<gt>>
and runs it with the globals C<Minilla::CLI-E<gt>run> would set. A step that
refuses throws C<Minilla::Error::CommandExit>, which C<Minilla::CLI-E<gt>run>
swallows; here it dies with a one-line message, after the step has already
printed its own, so the calling mist command exits nonzero and runs nothing
past the refusal. Any other exception is rethrown unchanged.

=cut
