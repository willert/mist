package App::Mist::Command::merge;
use 5.010;

use Moose;
extends 'MooseX::App::Cmd::Command';

use Path::Class qw/ dir file /;
use File::Spec::Functions qw/ catfile /;
use File::Basename qw/ basename /;
use File::Copy qw/ copy /;
use File::Path ();

use Minilla::Project;
use Minilla::Util qw/ check_git /;

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

  printf "Merging Minilla distribution from %s", $path;

  my $current_pwd = dir( getcwd());

  my ( $dist, $project, $work_dir );
  try {
    chdir( "$path" );
    check_git;
    $project = Minilla::Project->new({ cleanup => 0 });
    {
      # activating $Minilla::DEBUG seems to be the only way to
      # avoid Minillas own workdir cleanup for now
      local $Minilla::DEBUG = 1;
      $work_dir = $project->work_dir;
    }
    $dist = $work_dir->dist();
  } finally {
    chdir "$current_pwd";
  };

  return unless $dist;

  printf "Injecting distribution %s", $dist;

  my $app = $self->app;
  my $do  = sub{ $app->execute_command( $app->prepare_command( @_ )) };
  $do->( 'inject', @$args, $dist ) if $dist;

  printf "Removing %s\n", $work_dir->as_string;
  File::Path::rmtree( $work_dir->as_string );
}

1;
