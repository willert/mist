package App::Mist::Command::build_dist;
# ABSTRACT: create distribution package

use 5.010;

use App::Mist -command;
use Minilla::CLI;
use Minilla::Util qw(cmd);

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $inc{'CPAN/Uploader.pm'} //= __FILE__; }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;

  my $minil = Minilla::CLI->new();
  cmd( mist => run => 'prove' ); # exits on fail
  $minil->run( dist => '--no-test', @$args );
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::build_dist - build a release tarball of this project

=head1 SYNOPSIS

  mist build_dist

=head1 DESCRIPTION

Builds a distribution tarball of the current project. It first runs the
test suite (via C<mist run prove>) and aborts if the tests fail; it then
hands off to L<Minilla> to build the tarball with C<dist --no-test>.

This command operates on the project I<itself> as a CPAN-style
distribution; it has nothing to do with the bundled F<mpan-dist/> mirror.
Any extra arguments are passed through to C<minil dist>.

=head1 SEE ALSO

L<App::Mist::Command::release>, L<App::Mist::Command::local_release>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
