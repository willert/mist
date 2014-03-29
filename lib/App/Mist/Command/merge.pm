package App::Mist::Command::merge;
# ABSTRACT: merge mist-managed dist from given path

use 5.010;

use App::Mist -command;

use Path::Class qw/ dir file /;
use File::Spec::Functions qw/ catfile /;
use File::Basename qw/ basename /;
use File::Copy qw/ copy /;
use File::Path ();

use Mist::PackageManager::MPAN;

use Minilla::Project;
use Minilla::Util qw/ check_git /;

use Cwd;
use Try::Tiny;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  my ( $dist, $project, $work_dir );

  die "$0: No Minilla directory to merge\n"
    unless $args and ref $args eq 'ARRAY' and @$args;

  my $path = dir( pop @$args )->absolute->resolve;

  die "$0: ${path} is not Minilla distribution\n"
    unless -d q{}. $path and -f -r q{}. $path->file('cpanfile');

  goto SWITCH_CONTEXT if $dist = $ENV{MIST_MERGE_DIST_FILE};

  printf "Merging Minilla distribution from %s\n\n", $path;

  my $current_pwd = dir( getcwd());
  try {
    chdir( "$path" );
    check_git;
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

 SWITCH_CONTEXT:
  $ENV{MIST_MERGE_DIST_FILE} = $dist;
  $ctx->ensure_correct_perlbrew_context;

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
