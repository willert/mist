package App::Mist;

use strict;
use warnings;

use Carp;
use Scalar::Util qw/looks_like_number blessed/;

use App::Cmd::Setup -app;
use Module::Pluggable search_path => [ 'App::Mist::Command' ];

use Path::Class qw/dir file/;
use File::HomeDir;
use File::Which;
use File::Find::Upwards;

{
  my $project_root;
  sub project_root {
    my $self = shift;
    $project_root ||= do{
      my $root = eval{
        local $SIG{__WARN__} = sub{};
        find_containing_dir_upwards( 'dist.ini' )
      } or die "$0: Can't find project root\n";
      dir( $root )->absolute->resolve;
    };
  }
}

{
  my $workspace;
  sub workspace {
    my $self = shift;
    $workspace ||= do{
      my $home = File::HomeDir->my_home
        or die "Can't find user home";
      ( my $project_base = lc $self->project_root )=~ s/\W/_/g;
      $project_base =~ s/^_+//;
      $project_base =~ s/_+$//;

      my $ws = dir( $home )->subdir( '.mist', $project_base );
      $ws->mkpath;

      $ws;
    };
  }
}

{
  my $ws_lib;
  sub workspace_lib {
    my $self = shift;
    $ws_lib ||= do{
      my $ll = $self->workspace->subdir('perl5');
      $ll->mkpath;
      $ll;
    };
  }
}

{
  my $mpan;
  sub mpan_dist {
    my $self = shift;
    $mpan ||= $self->project_root->subdir(
      $ENV{MIST_DIST_DIR}  || 'mpan-dist'
    );
  }

  sub mpan_conf {
    my $self = shift;
    my $conf_dir = $self->mpan_dist->subdir('mist');
    return @_ ? $conf_dir->file( @_ ) : $conf_dir;
  }

}

{
  my $local_lib;
  sub local_lib {
    my $self = shift;
    $local_lib ||= $self->project_root->subdir(
      $ENV{MIST_LOCAL_LIB} || 'perl5'
    );
  }
}


{
  my $dzil;
  sub dzil_executable {
    my $self = shift;
    $dzil ||= which( 'dzil' ) or die "$0: dzil not found\n";
  }

}

{
  my $cpanm_executable;
  sub cpanm_executable {
    my $self = shift;
    $cpanm_executable ||= which( 'cpanm' )
      or die "$0: cpanm not found\n";
  }
}

sub load_cpanm {
  my $self = shift;
  my $pkg = $self->cpanm_executable;

  do $pkg;
  require App::cpanminus;

  die "$0: cpanm v$App::cpanminus::VERSION is too old, v1.4 needed\n"
    if $App::cpanminus::VERSION < 1.4;

  return;
}

sub run_cpanm {
  my ( $self, @cmd_opts ) = @_;
  $self->load_cpanm;

  my $app = App::cpanminus::script->new;
  $app->parse_options( @cmd_opts );
  $app->doit or exit(1);
}


1;
