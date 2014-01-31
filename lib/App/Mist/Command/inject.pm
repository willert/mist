package App::Mist::Command::inject;
use 5.010;

use App::Mist -command;

use Mist::PackageManager::MPAN;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  die "$0: No module to install"
    unless $args and ref $args eq 'ARRAY' and @$args;

  $ctx->ensure_correct_perlbrew_context;

  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $ctx->project_root,
    local_lib    => $ctx->local_lib,
    workspace    => $ctx->workspace_lib,
  });

  $package_manager->begin_work;

  $package_manager->install( @$args );

  $package_manager->commit;
}

1;
