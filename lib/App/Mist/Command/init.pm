package App::Mist::Command::init;

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
  my $app = $self->app;

  $app->execute_command( $app->prepare_command(
    'inject', '--skip-satisfied', $self->app->fetch_prereqs
  ));

  $app->execute_command( $app->prepare_command(
    'compile'
  ));

  system( file('mpan-install')->absolute->stringify );

  return;
}

1;
