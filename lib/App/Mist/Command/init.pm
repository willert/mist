package App::Mist::Command::init;

use strict;
use warnings;

use App::Mist -command;

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $app = $self->app;

  $self->app->execute_command( $app->prepare_command(
    'inject', '--reinstall', $app->run_dzil( 'listdeps' )
  ));

  return;
}

1;
