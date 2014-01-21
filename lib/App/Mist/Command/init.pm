package App::Mist::Command::init;
use 5.014;

use Moose;
extends 'MooseX::App::Cmd::Command';

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/file dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $app = $self->app;
  $app->ensure_correct_perlbrew_context;

  my @prepend = $app->dist->get_prepended_modules;
  my @notest  = $app->dist->get_modules_not_to_test;

  my @prereqs = grep{
    my $this = $_;
    # this clever bit of code seems to manipulate @prepend and @notest arrays
    ! grep{
      $this =~ m/^${_}(?:~.*)$/ and $_ = $this # pick up version string
    } ( @prepend, @notest );
  } $app->fetch_prereqs;

  my $do = sub{ $app->execute_command( $app->prepare_command( @_ )) };

  my @default_opts = (
    '--no-skip-installed', '--no-skip-satisfied', '--reinstall'
  );

  $do->( 'inject', @default_opts,             @$args, @prepend ) if @prepend;
  $do->( 'inject', @default_opts, '--notest', @$args, @notest  ) if @notest;
  $do->( 'inject', @default_opts,             @$args, @prereqs ) if @prereqs;

  $do->( 'compile' );

  print "Packaging and compilation successful!\n\n";

  {
    print "Running mpan-install\n";
    # we have to get rid of MIST_APP_ROOT here or else
    # ./mpan-install might update mist's own local lib
    # instead of the one of the project being worked on
    local $ENV{MIST_APP_ROOT} = undef;
    system( file('mpan-install')->absolute->stringify );
  }

  return;
}

1;
