package App::Mist::Command::merge;
# ABSTRACT: merge mist-managed dist from given path

use 5.010;

use App::Mist -command;

use Path::Class qw/ dir file /;
use File::Spec::Functions qw/ catfile /;
use File::Basename qw/ basename /;
use File::Copy qw/ copy /;
use File::Path ();

use Mist::ParseDistribution;
use Mist::PackageManager::MPAN;

use Mist::Minilla::Project;
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
    $project = Mist::Minilla::Project->new;
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

  my $other_mistfile = $path->file( 'mistfile' );
  my $other_env = do{
    if ( -f -r "$other_mistfile" ) {
      Mist::Environment->new( "$other_mistfile" )->parse
          or die "Error parsing $other_mistfile";
    }
  };

  $package_manager->add_mirror(
    sprintf( 'file://%s/', $path->subdir( 'mpan-dist' ))
  ) if -d -r $path->subdir( 'mpan-dist' )->stringify;

  $package_manager->begin_work;

  eval {
    # run foreign mist callstack before trying to install dist itself
    if ( $other_env ) {
      $package_manager->install( @$args, @$_ )
        for $other_env->build_cpanm_call_stack;
    }

    $package_manager->install( @$args, $dist );
  };


  my $install_error = $@;
  $package_manager->commit;

  die $install_error if $install_error;


  my $dist_info = Mist::ParseDistribution->new(
    $dist, repository => $ctx->mpan_dist
  );

  if ( -f -r "$other_mistfile" ) {
    print "Merging mistfile $other_mistfile\n";

    my $our_mistfile = $ctx->project_root->file( 'mistfile' );
    $our_mistfile->touch; # ensure local mistfile exists

    if ( not -f -r -w "$our_mistfile" ) {
      print STDERR "Can't write to $our_mistfile, skipping merge\n";
      goto MISTFILE_DONE;
    }

    my $mistfile = $our_mistfile->slurp( iomode => '<:utf8' );
    my $spec = $other_mistfile->slurp( iomode => '<:utf8' );;

    my $distname = $dist_info->as_module_name;
    $spec =~ s/\n(?!\n|$)/\n  /g; # indent merged file

    # construct the most convenient path to store
    my $distpath = dir( $path )->resolve->absolute;
    my $dev_home = dir( $ENV{HOME} )->resolve->absolute;
    if ( $dev_home->subsumes( $distpath ) ) {
      $distpath = $distpath->relative( $dev_home );
    } else {
      $distpath->relative( $ctx->project_root );
    }

    my $merged = sprintf <<'MERGE_SPEC', ( $distname ) x 2, $distpath, $spec, $distname;
### <<<[%s] - keep this line intact
merge '%s' => sub {
  # generated code block - do not edit
  dist_path '%s';

  %s
};
### [%s]>>> - keep this line intact
MERGE_SPEC

    $mistfile =~ s{### <<<\[(${distname})\].*?### \[\1\]>>>.*?(?:\n|$)}
                  {$merged}s or $mistfile .= "\n\n${merged}";

    $our_mistfile->spew({ iomode => '<:utf8' }, $mistfile );
  }

  print "\nPlease run\n  $0 compile\nas mistfile might have changed\n";

 MISTFILE_DONE:

  $project->cleanup if $project;
}

1;
