package App::Mist::Command::lib_paths;
use 5.010;

use App::Mist -command;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  say $_ for $ctx->project_root->subdir('lib'), $ctx->local_lib;
}

1;
