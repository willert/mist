package Mist::Script::install;
use strict;
use warnings;

use Config;

our @CMD_OPTS;

BEGIN { @CMD_OPTS = @ARGV; @ARGV = () }

our $MPAN_DIST_DIR      // die '$MPAN_DIST_DIR not set';

our $PERL5_BASE_LIB = 'perl5';
our $LOCAL_LIB_DIR = File::Spec->catdir(
  $PERL5_BASE_LIB,
  join( q{-}, 'perl', $Config{version}, $Config{archname} )
);

our $PREPEND_DISTS //= eval {[ DISTRIBUTION->distinfo->get_prepended_modules ]};
die '$PREPEND_DISTS not set' . $@ unless $PREPEND_DISTS;

our $DONT_TEST_DISTS //= eval {[ DISTRIBUTION->distinfo->get_modules_not_to_test ]};
die '$DONT_TEST_DISTS not set' . $@ unless $DONT_TEST_DISTS;

our $PREREQUISITE_DISTS // die '$PREREQUISITE_DISTS not set';

use App::cpanminus::script;
use FindBin qw/$Bin/;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use File::Spec;
use File::Copy;
use Cwd qw/realpath/;

my $mist_home = $ENV{MIST_APP_ROOT} ? $ENV{MIST_APP_ROOT} : $Bin;

my $perl5_baselib = File::Spec->catdir( $mist_home, $PERL5_BASE_LIB );
mkpath( $perl5_baselib );

my $mpan          = File::Spec->catdir( $Bin, $MPAN_DIST_DIR );
my $local_lib     = File::Spec->catdir( $mist_home, $LOCAL_LIB_DIR );
my $libexec_dir   = File::Spec->catdir( $perl5_baselib, 'libexec' );

mkpath( $libexec_dir );

my $cmd_wrapper_src = File::Spec->catfile( $mpan, 'cmd-wrapper.bash' );
my $cmd_wrapper     = File::Spec->catfile( $libexec_dir, 'cmd-wrapper.bash' );

copy( $cmd_wrapper_src, $cmd_wrapper )
  or die "Creating $cmd_wrapper failed: $!";

my $perm = ( stat $cmd_wrapper )[2] & 07777;
chmod( $perm | 0755, $cmd_wrapper );

Mist::Script::perl->init
  if eval{ Mist::Script::perl->can( 'init' ) };

sub run_cpanm {
  my $app = App::cpanminus::script->new;
  my @options = (
    "--quiet",
    "--local-lib-contained=${local_lib}",
    "--mirror=file://${mpan}",
    '--mirror-only',
    @CMD_OPTS,
  );

  $app->parse_options( @options, @_ );
  my $result = $app->_doit;
  exit 1 unless $result and $result == 1;
  return $result;
}

unless (caller) {

  die "mpan-install can not run as root\n" if $> == 0;

  my $workspace = tempdir();
  mkpath( $local_lib );

  if ( not -r $mpan or not -w $local_lib ) {
    warn "$0: can't read from ${mpan}: permission denied\n"
      unless -r $mpan;

    warn "$0: can't write to ${local_lib}: permission denied\n"
      unless -w $local_lib;

    exit 1;
  }

  my $p5_dir = realpath( File::Spec->catdir( $local_lib, File::Spec->updir ));
  my $rc_dir = File::Spec->catdir( $p5_dir, 'etc' );
  mkpath( $rc_dir );
  my $mist_rc = File::Spec->catfile( $rc_dir, 'mist.mistrc' );
  open my $env, '>', $mist_rc;  # to catch write errors early on

  my $bin_dir = File::Spec->catdir( $p5_dir, 'bin' );
  mkpath( $bin_dir );
  my $mist_run = File::Spec->catfile( $bin_dir, 'mist-run');
  open my $wrapper, '>', $mist_run; # to catch write errors early on
  {
    my $perm = ( stat $mist_run )[2] & 07777;
    chmod( $perm | 0755, $mist_run );
  }

  local $ENV{HOME} = $workspace;

  if ( eval { DISTRIBUTION->distinfo->can( 'get_assertions' ) }) {
    $_->() for DISTRIBUTION->distinfo->get_assertions;
  }

  if ( App::Mist::MPAN::prereqs->can( 'assert' )) {
    eval { App::Mist::MPAN::prereqs->assert };
  }

  if ( my $err = $@ ) {
    die "\n[FATAL] Error checking prerequisites:\n${err}\n";
  }

  my @prepend = ( @$PREPEND_DISTS );
  my @notest  = ( @$DONT_TEST_DISTS );
  my @prereqs = ( @$PREREQUISITE_DISTS );
  for my $module ( @prepend ) {
    run_cpanm( @ARGV, $module );
  }
  for my $module ( @notest ) {
    run_cpanm( @ARGV, '--installdeps', $module );
    run_cpanm( @ARGV, '--notest', $module );
  }
  for my $module ( @prereqs ) {
    run_cpanm( @ARGV, $module );
  }

  printf $env <<'MIST_ENV', $mist_home;
# This file is automatically generated by ./mpan-install
# DO NOT EDIT

export MIST_APP_ROOT="%s"
export PATH="$MIST_APP_ROOT/bin:$MIST_APP_ROOT/sbin:$MIST_APP_ROOT/script:$PATH"

MIST_ENV

  if ( eval{ Mist::Script::perl->can( 'write_env' )} ) {
    Mist::Script::perl->write_env( $env );
  }

  require local::lib;

  {
    local $SIG{__WARN__} = sub{};
    print $env local::lib->environment_vars_string_for( "${local_lib}" );
  }
  close $env;

  printf $wrapper <<'WRAPPER', $local_lib, $mist_home, $mist_rc;
#!/bin/bash

LOCAL_LIB="%s"
MIST_ROOT="%s"
MIST_ENV="%s"

if [ ! -r $MIST_ENV ] ; then
    echo "FATAL: Could not load env from $MIST_ENV"
    exit 1
fi

source $MIST_ENV
export PATH="$LOCAL_LIB/bin:$LOCAL_LIB/sbin:$PATH"
export PATH="$MIST_ROOT/bin:$MIST_ROOT/sbin:$MIST_ROOT/script:$PATH"
export PERL5LIB="$MIST_ROOT/lib:$PERL5LIB"

exec "$@"
WRAPPER

  for my $script_dir (qw/ bin sbin script /) {

    my $loc_script_dir = File::Spec->catdir( $perl5_baselib, $script_dir );

    my @binaries;
    my $dir;

    use strict;

    $dir = File::Spec->catdir( $local_lib, $script_dir );
    if ( -d $dir and opendir( my $dh, $dir ) ) {
      push @binaries, map{(
        File::Spec->catfile( $loc_script_dir, $_ )
      )} grep {
        -f File::Spec->catfile( $dir, $_ ) and
          -x File::Spec->catfile( $dir, $_ )
      } readdir( $dh );
    }

    $dir = File::Spec->catdir( $Bin, $script_dir );
    if ( -d $dir and opendir( my $dh, $dir ) ) {
      push @binaries, map{(
        File::Spec->catfile( $loc_script_dir, $_ )
      )} grep {
        -f File::Spec->catfile( $script_dir, $_ ) and
          -x File::Spec->catfile( $script_dir, $_ )
      } readdir( $dh );
    }

    if ( @binaries ) {
      mkpath( $loc_script_dir );
      print "Creating local binaries in ${loc_script_dir}\n";

      for my $bin ( @binaries ) {
        unlink $bin;
        symlink $cmd_wrapper, $bin
          or die "Failed to create symlink for $bin";
      }
    }
  }


  print <<"SUCCESS";

Successfully created a mist environment for this distribution.
To enable it put the following line in your scripts:
  source $mist_rc

To run binaries from this distribution (\$HOME/bin and \$HOME/sbin are in
automatically prepended to \$PATH) you can also use this wrapper script:
  $mist_run my_script.pl [OPTIONS ..]

SUCCESS
}