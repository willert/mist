package App::Mist::Command::inject;
use 5.010;

use App::Mist -command;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  die "$0: No module to install"
    unless $args and ref $args eq 'ARRAY' and @$args;

  $ctx->ensure_correct_perlbrew_context;

  require Mist::PackageManager::MPAN;
  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $ctx->project_root,
    local_lib    => $ctx->local_lib,
    workspace    => $ctx->workspace_lib,
  });

  $package_manager->begin_work;
  eval { $package_manager->install( @$args ) };
  my $install_error = $@;
  $package_manager->commit;
  die $install_error if $install_error;
}

1;
