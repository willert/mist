package App::Mist::Command::info;

use strict;
use warnings;

use App::Mist -command;

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/file dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;
  printf STDERR "%s\n", join( "\n", $self->app->fetch_prereqs );
}

1;
