package App::Mist::Command::lib_paths;
# ABSTRACT: Print library paths of current project

use 5.010;

use App::Mist -command;
use local::lib 2.00 ();

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;
  $ctx->ensure_correct_perlbrew_context;

  say $_ for $ctx->project_root->subdir('lib'),
    local::lib->lib_paths_for( $ctx->local_lib );
}

1;
