package App::Mist::Command::init;
# ABSTRACT: Inject dependencies and run mpan-install

use 5.010;

use App::Mist -command;

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/file dir/;
use Cwd;

sub opt_spec {
  return (
    [ "rebuild|R",  "rebuild the complete mpan distribution" ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $rebuild_dist = !! $opt->{rebuild};

  my $ctx  = $self->app->ctx;

  if ( $rebuild_dist ) {
    print "Rebuilding Mist distribution environment\n", ;
    for my $mist_dir ( $ctx->mpan_dist, $ctx->perl5_base_lib ) {
      $mist_dir->rmtree; $mist_dir->mkpath;
    }
  }

  my $app = $self->app;
  my $do  = sub{
    my @cmd = $app->prepare_command( @_ );
    $app->execute_command( @cmd );
  };

  # compile needs to run before switching context because it
  # will dynamically load some modules from mist's local::lib
  $do->( 'compile' ) unless $ENV{__MIST_COMPILATION_DONE};
  $ENV{__MIST_COMPILATION_DONE} = 1;

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

  my $run_script = sub {
    my @cmd = @_ == 1 && ref $_[0] eq 'ARRAY' ? @{$_[0]} : @_;
    local $ENV{MIST_APP_ROOT} = $ctx->project_root;
    local $ENV{MIST_PERL5_LIBDIR} = $ctx->local_lib;
    system( @cmd );
  };

  $run_script->( $_ ) for $ctx->dist->get_scripts( 'prepare' );

  if ( $rebuild_dist ) {

    my @merge = $ctx->dist->get_merged_dists;

  MERGED_DIST:
    for my $dist ( @merge ) {
      my $dist_path = $ctx->get_merge_path_for( $dist );
      if ( not $dist_path or not -r -d "$dist_path" ) {
        warn "Merged dist ${dist} not found. Skipping ..\n";
        next MERGED_DIST;
      }
      print "\n";
      $do->( 'merge', @$args, "$dist_path" );
    }
  }

  $do->( 'inject',             @$args, @prepend ) if @prepend;
  $do->( 'inject', '--notest', @$args, @notest  ) if @notest;
  $do->( 'inject',             @$args, @prereqs ) if @prereqs;

  $run_script->( $_ ) for $ctx->dist->get_scripts( 'finalize' );

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
