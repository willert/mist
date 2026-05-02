package App::Mist::Command::release;
# ABSTRACT: run full release of the distribution package

use 5.010;

use App::Mist -command;
use Minilla::CLI;

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $inc{'CPAN/Uploader.pm'} //= __FILE__; }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;

  my $minil = Minilla::CLI->new();
  $minil->run( release => @$args );
  $minil->run( dist => '--no-test', @$args );
}

1;
