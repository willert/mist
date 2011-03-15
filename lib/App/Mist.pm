package App::Mist;

use strict;
use warnings;

use Carp;
use Scalar::Util qw/looks_like_number blessed/;

use App::Cmd::Setup -app;
use Module::Pluggable search_path => [ 'App::Mist::Command' ];

use Path::Class qw/dir file/;
use File::HomeDir;
use File::Find::Upwards;

{
  my $project_root;
  sub project_root {
    my $self = shift;
    $project_root ||= do{
      my $root = find_containing_dir_upwards( 'dist.ini' )
        or die "Can't find project root";
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

sub workspace_lib {
  my $self = shift;
  my $ll = $self->workspace->subdir('perl5');
  $ll->mkpath;
  return $ll;
}

1;
