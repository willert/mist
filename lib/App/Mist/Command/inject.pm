package App::Mist::Command::inject;
use 5.014;

use Moose;
extends 'MooseX::App::Cmd::Command';

use Mist::PackageManager::MPAN;

sub execute {
  my ( $self, $opt, $args ) = @_;

  die "$0: No module to install"
    unless $args and ref $args eq 'ARRAY' and @$args;

  $self->app->ensure_correct_perlbrew_context;

  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $self->app->project_root,
    local_lib    => $self->app->local_lib,
    workspace    => $self->app->workspace_lib,
  });

  my @modules  = grep{ !/^-/ } @$args;
  my @cmd_args = grep{ /^-/ } @$args;

  $package_manager->begin_work;

  $package_manager->install( \@modules, @cmd_args );

#  for my $module ( @modules ) {
#    $package_manager->install(
#      $module, @cmd_args
#    );
#  }

  $package_manager->commit;
}

1;
