package App::Mist::Command::build_dist;
# ABSTRACT: create distribution package

use 5.010;

use App::Mist -command;
use Minilla::CLI;
use Minilla::Util qw(cmd);

no thanks 'CPAN::Uploader';

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;

  my $minil = Minilla::CLI->new();
  cmd( mist => run => 'prove' ); # exits on fail
  $minil->run( dist => '--no-test', @$args );
}

1;
