package App::Mist::Command::init;

use strict;
use warnings;

use base 'App::Cmd::Command';

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/file dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $app = $self->app;
  $app->ensure_correct_perlbrew_context;

  my $dist_prepend = $app->mpan_conf->file(qw/ 01.prepend.txt /);
  my $dist_notest  = $app->mpan_conf->file(qw/ 02.notest.txt /);

  my @prepend = $app->slurp_file( $dist_prepend );
  my @notest  = $app->slurp_file( $dist_notest );

  my @prereqs = grep{
    my $this = $_;
    ! grep{
      $this =~ m/^${_}(?:~.*)$/ and $_ = $this # pick up version string
    } ( @prepend, @notest );
  } $app->fetch_prereqs;

  my @inject = (
    'inject',
    '--skip-satisfied',
  );

  my $do = sub{ $app->execute_command( $app->prepare_command( @_ )) };

  $do->( @inject,             @$args, @prepend ) if @prepend;
  $do->( @inject, '--notest', @$args, @notest  ) if @notest;
  $do->( @inject,             @$args, @prereqs ) if @prereqs;
  $do->( 'compile' );

  system( file('mpan-install')->absolute->stringify );

  return;
}

1;
