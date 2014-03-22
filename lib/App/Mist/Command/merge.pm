package App::Mist::Command::merge;
use 5.010;

use App::Mist -command;

use Path::Class qw/ dir file /;
use File::Spec::Functions qw/ catfile /;
use File::Basename qw/ basename /;
use File::Copy qw/ copy /;
use File::Path ();

use Cwd;
use Try::Tiny;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  die "$0: No Minilla directory to merge\n"
    unless $args and ref $args eq 'ARRAY' and @$args;

  my ( $path, $guard ) = map{
    dir( $_ )->absolute->resolve
  }  grep{ !/^-/ } @$args;

  die "$0: Too many arguments\n" if $guard;

  $ctx->ensure_correct_perlbrew_context;

  die "$0: ${path} is not Minilla distribution\n"
    unless -d q{}. $path and -f -r q{}. $path->file('cpanfile');

  printf "Merging Minilla distribution from %s\n\n", $path;

  my $current_pwd = dir( getcwd());

  require Minilla::Project;
  require Minilla::Util;

  my ( $dist, $project, $work_dir );
  try {
    chdir( "$path" );
    Minilla::Util::check_git();
    $project = Minilla::Project->new({ cleanup => 0 });
    $work_dir = $project->work_dir;
    $dist = $work_dir->dist();
  } catch {
    /Minilla::Error::CommandExit/ and return;
    printf STDERR "%s\n", $_;
  } finally {
    chdir "$current_pwd";
  };

  exit 1 unless $dist;

  printf "Injecting distribution %s\n", $dist;

  require Mist::PackageManager::MPAN;
  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $ctx->project_root,
    local_lib    => $ctx->local_lib,
    workspace    => $ctx->workspace_lib,
  });

  $package_manager->add_mirror(
    sprintf( 'file://%s/', $path->subdir( 'mpan-dist' ))
  ) if -d -r $path->subdir( 'mpan-dist' )->stringify;

  $package_manager->begin_work;

  $package_manager->install( @$args, $dist );

  $package_manager->commit;
}

1;
