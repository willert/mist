package App::Mist::Command::compile;

use strict;
use warnings;

use App::Mist -command;

use Try::Tiny;
use Path::Class qw/dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $app       = $self->app;
  my $cpanm     = $app->cpanm_executable;
  my $home      = $app->project_root;
  my $mpan      = $app->mpan_dist;
  my $mpan_conf = $app->mpan_conf;
  my $local_lib = $app->local_lib;

  my $dist_prereqs = $mpan_conf->file(qw/ 00.prereqs.pl /);
  my $dist_prepend = $mpan_conf->file(qw/ 01.prepend.txt /);
  my $dist_notest  = $mpan_conf->file(qw/ 02.notest.txt /);

  chdir $home->stringify;
  $mpan_conf->mkpath;
  $_->touch for grep{ not -r $_->stringify } $dist_prepend, $dist_notest;

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

    my $prereqs = $self->app->slurp_file( $dist_prereqs );
    my @prepend = $self->app->slurp_file( $dist_prepend );
    my @notest  = $self->app->slurp_file( $dist_notest );
    my @prereqs = $self->app->fetch_prereqs;

    my @args = (
      $mpan->relative( $home ),
      $local_lib->relative( $home ),
      $prereqs,
      @prepend ? sprintf( qq{'%s'}, join qq{',\n    '}, @prepend ) : '',
      @notest  ? sprintf( qq{'%s'}, join qq{',\n    '}, @notest  ) : '',
      @prereqs ? sprintf( qq{'%s'}, join qq{',\n    '}, @prereqs ) : '',
    );


    print STDERR "Generating mpan-install\n";

    open my $in,  "<", "$cpanm" or die $!;
    open my $out, ">", "mpan-install.tmp" or die $!;

    while (<$in>) {
        print $out $_;
        last if /# END OF FATPACK CODE\s*$/;
    }

    printf $out <<'INSTALLER', @args;

use App::cpanminus::script;
use FindBin qw/$Bin/;
use Path::Class qw/file dir/;
use File::Temp qw/tempdir/;

my $mpan      = dir( $Bin, '%s' );
my $local_lib = dir( $Bin, '%s' );

sub run_cpanm {
  my $app       = App::cpanminus::script->new;
  my @options   = (
    "--quiet",
    "--local-lib-contained=${local_lib}",
    "--mirror=file://${mpan}",
    '--mirror-only',
  );

  # use Data::Dumper::Concise;
  # printf STDERR '@Options: %%s%%s', Dumper( \@options ), "\n";

  $app->parse_options( @options, @_ );
  $app->doit or exit(1);
}

unless (caller) {

  die "mpan-install can not run as root\n" if $> == 0;

  my $workspace = tempdir();
  $local_lib->mkpath;

  if ( not -r "${mpan}" or not -w "${local_lib}" ) {
    warn "$0: can't read from ${mpan}: permission denied\n"
      unless -r "${mpan}";

    warn "$0: can't write to ${local_lib}: permission denied\n"
      unless -w "${local_lib}";

    exit 1;
  }

  my $mist_rc = $local_lib->file(qw/ etc mist.mistrc /);
  $mist_rc->dir->mkpath;
  my $env = $mist_rc->openw; # to catch write errors early on

  my $mist_run = $local_lib->file(qw/ bin mist-run /);
  $mist_run->dir->mkpath;
  my $wrapper = $mist_run->openw; # to catch write errors early on
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


  run_cpanm( @ARGV, @prepend ) if @prepend;
  run_cpanm( @ARGV, '--installdeps', @notest ) if @notest;
  run_cpanm( @ARGV, '--notest', @notest ) if @notest;
  run_cpanm( @ARGV, @prereqs ) if @prereqs;

  require local::lib;
  print $env local::lib->environment_vars_string_for( "${local_lib}" );
  close $env;

  printf $wrapper <<'WRAPPER', $Bin, $mist_rc;
#!/bin/bash

MIST_ROOT="%%s"
MIST_ENV="%%s"

if [ ! -r $MIST_ENV ] ; then
    echo "FATAL: Could not load env from $MIST_ENV"
    exit 1
fi

source $MIST_ENV
export PATH="$MIST_ROOT/bin:$MIST_ROOT/sbin:$PATH"

exec "$@"
WRAPPER

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

$BASE_DIR/perl5/bin/mist-run `basename $0` $@

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
