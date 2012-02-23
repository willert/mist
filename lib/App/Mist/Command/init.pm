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

  my $dist_prepend = $self->app->mpan_conf->file(qw/ 01.prepend.txt /);
  my $dist_notest  = $self->app->mpan_conf->file(qw/ 02.notest.txt /);

  my @prepend = $self->app->slurp_file( $dist_prepend );
  my @notest  = $self->app->slurp_file( $dist_notest );

  my @prereqs = grep{
    my $this = $_;
    ! grep{
      $this =~ m/^${_}(?:~.*)$/ and $_ = $this # pick up version string
    } ( @prepend, @notest );
  } $self->app->fetch_prereqs;

  $app->execute_command( $app->prepare_command(
    'inject', '--skip-satisfied', @prepend
  )) if @prepend;

  $app->execute_command( $app->prepare_command(
    'inject', '--skip-satisfied', '--notest', @notest
  )) if @notest;

  $app->execute_command( $app->prepare_command(
    'inject', '--skip-satisfied', @prereqs
  )) if @prereqs;

  $app->execute_command( $app->prepare_command(
    'compile'
  ));

  system( file('mpan-install')->absolute->stringify );

  return;
}

1;
