package App::Mist::Command::init;
# ABSTRACT: Inject dependencies and run mpan-install

use 5.010;

use App::Mist -command;

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/file dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $app = $self->app;
  my $do  = sub{ $app->execute_command( $app->prepare_command( @_ )) };

  # compile needs to run before switching context because it
  # will dynamically load some modules from mist's local::lib
  $do->( 'compile' ) unless $ENV{__MIST_COMPILATION_DONE};
  $ENV{__MIST_COMPILATION_DONE} = 1;

  my $ctx  = $self->app->ctx;
  $ctx->ensure_correct_perlbrew_context;

  my @prepend = $ctx->dist->get_prepended_modules;
  my @notest  = $ctx->dist->get_modules_not_to_test;

  my @prereqs = grep{
    my $this = $_;
    # this clever bit of code seems to manipulate @prepend and @notest arrays
    ! grep{
      $this =~ m/^${_}(?:~.*)$/ and $_ = $this # pick up version string
    } ( @prepend, @notest );
  } $ctx->fetch_prereqs;

  $do->( 'inject',             @$args, @prepend ) if @prepend;
  $do->( 'inject', '--notest', @$args, @notest  ) if @notest;
  $do->( 'inject',             @$args, @prereqs ) if @prereqs;

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
