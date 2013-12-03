package App::Mist::Command::compile;

use strict;
use warnings;

use base 'App::Cmd::Command';

use Try::Tiny;
use Path::Class qw/dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $app       = $self->app;
  my $home      = $app->project_root;
  my $mpan      = $app->mpan_dist;
  my $mpan_conf = $app->mpan_conf;
  my $local_lib = $app->local_lib;

  my $dist_perlbrew = $mpan_conf->file(qw/ 00.perlbrew.txt /);
  my $dist_prereqs  = $mpan_conf->file(qw/ 00.prereqs.pl   /);
  my $dist_prepend  = $mpan_conf->file(qw/ 01.prepend.txt  /);
  my $dist_notest   = $mpan_conf->file(qw/ 02.notest.txt   /);

  chdir $home->stringify;
  $mpan_conf->mkpath;
  $_->touch for grep{ not -r $_->stringify }
    $dist_prepend, $dist_notest, $dist_perlbrew;

  if ( not -f -w "$dist_prereqs" ) {
    my $fh = $dist_prereqs->openw;
    print $fh <<'PREAMBLE'
# This file contains perl code that is run before anything
# else and can be used to ensure that the configuration of
# the host system confirms to expectations.
#
# I.E you an use the following lines to ensure that
# mysql_config (which is needed by DBD::mysql) is in the
# current PATH:
#
#   die <<ERROR if system("mysql_config --version") < 0;
#   Could not run mysql_config [$!]
#   Do you have libmysqlclient-dev installed?
#   ERROR
#
# Keep in mind that you can't use any modules that are not
# available on the host system in this file.

PREAMBLE
  }

  try {

    my $assert  = $self->app->slurp_file( $dist_prereqs );
    my @prepend = $self->app->slurp_file( $dist_prepend );
    my @notest  = $self->app->slurp_file( $dist_notest );
    my @prereqs = $self->app->fetch_prereqs;

    my $perlbrew_version = $self->app->perlbrew_version;
    my $perlbrew_init = '';

    if ( $perlbrew_version ) {
      my @args = (
        $self->app->perlbrew_root,
        $perlbrew_version,
      );
      $perlbrew_init = sprintf( <<'PERL', @args );
  use FindBin ();
  use File::Spec ();

  my $tmp_base_dir = File::Spec->catdir( $FindBin::Bin, 'tmp' );
  $tmp_base_dir = File::Spec->catdir(
    File::Spec->tmpdir, ( File::Spec->splitdir( $FindBin::Bin ))[ -1 ]
  ) unless -d $tmp_base_dir and -w $tmp_base_dir;

  $pb_root    = $ENV{PERLBREW_ROOT} || '%s';
  $pb_home    = File::Spec->catdir( $tmp_base_dir, 'perlbrew' );
  $pb_version = '%s';

  print "Using perlbrew root $pb_root\n";
  print "Using temporary perlbrew home $pb_home\n";

  my $pb_exec = qx{ which perlbrew } || "${pb_root}/bin/perlbrew";
  chomp $pb_exec;

  system( "$pb_exec version >/dev/null" ) == 0 or die <<"MSG";
No local installation of perlbrew was found ($?). You can install it
as root via:
  export PERLBREW_ROOT=${pb_root}
  curl -kL http://install.perlbrew.pl | sudo -E bash
or just for this account simply via:
  curl -kL http://install.perlbrew.pl | bash
MSG

  my @pb_installed_versions = qx# bash -c '
    export PERLBREW_ROOT=${pb_root}
    export PERLBREW_HOME=${pb_home}

    if ( ! . \${PERLBREW_ROOT}/etc/bashrc ) ; then
      perlbrew init 2>/dev/null
      if ( ! . \${PERLBREW_ROOT}/etc/bashrc ) ; then
        echo "Cannot create perlbrew environment in \${PERLBREW_ROOT}"
        exit 127
      fi
    fi

    $pb_exec list
  '#;

  my ( $pb_installed ) = grep{ / \b $pb_version \b /x } @pb_installed_versions;
  die "FATAL: $pb_version not found and can't write to $pb_root\n" .
    "Try\n  sudo -E perlbrew install $pb_version\nto install it as root\n"
      unless $pb_installed or -w $pb_root;

  my @pb_call = ( $pb_exec, 'install', $pb_version );
  system( @pb_call ) == 0 or die "`@pb_call` failed" unless $pb_installed;

  if ( !$ENV{PERLBREW_PERL} or $ENV{PERLBREW_PERL} ne $pb_version ) {
    print "Restarting $0 under $pb_version\n\n";
    $ENV{PERLBREW_ROOT} = $pb_root;
    $ENV{PERLBREW_HOME} = $pb_home;
    exec $pb_exec, 'exec', '--with', $pb_version, $0;
  }

PERL
    }

    my @args = (
      $app->perl5_base_lib->relative( $home ),
      $mpan->relative( $home ),
      $local_lib->relative( $home ),
      $perlbrew_init || '',
      $assert,
      @prepend ? sprintf( qq{'%s'}, join qq{',\n    '}, @prepend ) : '',
      @notest  ? sprintf( qq{'%s'}, join qq{',\n    '}, @notest  ) : '',
      @prereqs ? sprintf( qq{'%s'}, join qq{',\n    '}, @prereqs ) : '',
    );


    print STDERR "Generating mpan-install\n";

    use Module::Path qw/ module_path /;


    open my $out, ">", "mpan-install.tmp" or die $!;
    print $out "#!/usr/bin/env perl\n\n";

    open my $fatscript, "<", module_path( 'App::cpanminus::fatscript' ) or die $!;
    while ( <$fatscript> ) {
      next if $_ eq "\n";
      last if /^__END__$/;
      print $out $_;
      last if /# END OF FATPACK CODE\s*$/;
    }

    # while (<DATA>) {
    #   next if $_ eq "\n";
    #   print $out $_;
    #   last if /# END OF FATPACK CODE\s*$/;
    # }

    printf $out <<'INSTALLER', @args;

use strict;
use warnings;

use App::cpanminus::script;
use FindBin qw/$Bin/;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use File::Spec;
use File::Copy;
use Cwd qw/realpath/;

my $mist_home = $ENV{MIST_APP_ROOT} ? $ENV{MIST_APP_ROOT} : $Bin;

my $perl5_baselib = File::Spec->catdir( $mist_home, '%s' );
mkpath( $perl5_baselib );

my $mpan          = File::Spec->catdir( $Bin, '%s' );
my $local_lib     = File::Spec->catdir( $mist_home, '%s' );
my $libexec_dir   = File::Spec->catdir( $perl5_baselib, 'libexec' );

mkpath( $libexec_dir );

my $cmd_wrapper_src = File::Spec->catfile( $mpan, 'cmd-wrapper.bash' );
my $cmd_wrapper     = File::Spec->catfile( $libexec_dir, 'cmd-wrapper.bash' );

copy( $cmd_wrapper_src, $cmd_wrapper )
  or die "Creating $cmd_wrapper failed: $!";

my $perm = ( stat $cmd_wrapper )[2] & 07777;
chmod( $perm | 0755, $cmd_wrapper );


my $pb_root;
my $pb_home;
my $pb_version;

%s

sub run_cpanm {
  my $app = App::cpanminus::script->new;
  my @options   = (
    "--quiet",
    "--local-lib-contained=${local_lib}",
    "--mirror=file://${mpan}",
    '--mirror-only',
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
  open my $env, '>', $mist_rc; # to catch write errors early on

  my $bin_dir = File::Spec->catdir( $p5_dir, 'bin' );
  mkpath( $bin_dir );
  my $mist_run = File::Spec->catfile( $bin_dir, 'mist-run');
  open my $wrapper, '>', $mist_run; # to catch write errors early on
  {
     my $perm = ( stat $mist_run )[2] & 07777;
     chmod( $perm | 0755, $mist_run );
  }

  local $ENV{HOME} = $workspace;

  eval <<'CHECK_PREREQS';
%s
CHECK_PREREQS

  if ( my $err = $@ ) {
    die "\n[FATAL] Error checking prerequisites:\n${err}\n";
  }

  my @prepend = (
    %s
  );
  my @notest  = (
    %s
  );
  my @prereqs = (
    %s
  );


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

export MIST_APP_ROOT="%%s"
export PATH="$MIST_APP_ROOT/bin:$MIST_APP_ROOT/sbin:$MIST_APP_ROOT/script:$PATH"

MIST_ENV

  if ( $pb_version ) {
# FIXME:      printf $env <<'PERLBREW_HOME', $pb_home;
# FIXME:  # Initializing perlbrew environment
# FIXME:
# FIXME:  if [[
# FIXME:    -w "$MIST_APP_ROOT/tmp/perlbrew" ||
# FIXME:    ( -w "$MIST_APP_ROOT/tmp" && ! -e "$MIST_APP_ROOT/tmp/perlbrew" )
# FIXME:  ]] ; then
# FIXME:    export PERLBREW_HOME="$MIST_APP_ROOT/tmp/perlbrew"
# FIXME:  else
# FIXME:    export PERLBREW_HOME="%%s"
# FIXME:  fi
# FIXME:  PERLBREW_HOME

    print $env <<"PERLBREW_RC";

export PERLBREW_ROOT="$pb_root"
source "$pb_root/etc/bashrc"

perlbrew switch $pb_version

PERLBREW_RC
  }
  require local::lib;
  {
    local $SIG{__WARN__} = sub{};
    print $env local::lib->environment_vars_string_for( "${local_lib}" );
  }
  close $env;

  printf $wrapper <<'WRAPPER', $local_lib, $mist_home, $mist_rc;
#!/bin/bash

LOCAL_LIB="%%s"
MIST_ROOT="%%s"
MIST_ENV="%%s"

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

#   printf "%%s\n",
      $dir = File::Spec->catdir( $local_lib, $script_dir );
    if ( -d $dir and opendir( my $dh, $dir ) ) {
      push @binaries, map{(
        File::Spec->catfile( $loc_script_dir, $_ )
      )} grep {
        -f File::Spec->catfile( $dir, $_ ) and
          -x File::Spec->catfile( $dir, $_ )
      } readdir( $dh );
    }

#    printf "%%s\n",
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

INSTALLER

    close $out;

    unlink "mpan-install";
    rename "mpan-install.tmp", "mpan-install";
    chmod 0755, "mpan-install";

    print STDERR "Generating cmd wrapper\n";

    my $wrapper = $app->mpan_dist->file('cmd-wrapper.bash')->stringify;
    open $out, ">", $wrapper or die $!;

    print $out <<'CMD_WRAPPER';
#!/bin/bash

# get the absolute path of the executable
SELF_PATH=$(cd -P -- "$(dirname -- "$0")" && pwd -P) && SELF_PATH=$SELF_PATH/$(basename -- "$0")

# resolve symlinks
while [ -h $SELF_PATH ]; do
    # 1) cd to directory of the symlink
    # 2) cd to the directory of where the symlink points
    # 3) get the pwd
    # 4) append the basename
    DIR=$(dirname -- "$SELF_PATH")
    SYM=$(readlink $SELF_PATH)
    SELF_PATH=$(cd $DIR && cd $(dirname -- "$SYM") && pwd)/$(basename -- "$SYM")
done

WRAPPER=$(dirname $SELF_PATH)

CALL_PATH="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/$(basename $0)"

if [ $SELF_PATH == $CALL_PATH ] ; then
  echo "$(basename $0): Must be called as a symlink named like the command to be run" >&2
  exit 1
fi

# try to upward-find local::lib directory
for UPDIR in . .. ../.. ../../.. ../../../.. ; do
  TEST="$WRAPPER/$UPDIR/perl5";
  if [ -d $TEST ] ; then
      LOCAL_LIB=$( cd -P "$( dirname "$TEST" )" && pwd )
      BASE_DIR="$WRAPPER/$UPDIR"
      break
  fi
done

#exit if we can't find any
if [ ! $LOCAL_LIB ] ; then
  echo "$0: No local::lib directory found. Abort!" >&2
  exit 1
fi

exec "$BASE_DIR/perl5/bin/mist-run" `basename $0` "$@"

CMD_WRAPPER

    close $out;
    chmod 0755, $wrapper;

  } catch {
    warn "$_\n";
  } finally {

    unlink "mpan-install.tmp"

  };

}

1;
