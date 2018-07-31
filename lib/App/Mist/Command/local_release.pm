package App::Mist::Command::local_release;
# ABSTRACT: run limited local tag and release of package

use 5.010;

use App::Mist -command;
use Minilla::CLI;
no thanks 'CPAN::Uploader';

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;
  Minilla::CLI->new()->run( local_release => @$args );
}

1;
