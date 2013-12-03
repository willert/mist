package App::Mist::Command::compile;

use strict;
use warnings;

use base 'App::Cmd::Command';

use Module::Path qw/ module_path /;

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

    print STDERR "Generating mpan-install\n";

    open my $out, ">", "mpan-install.tmp" or die $!;
    print $out "#!/usr/bin/env perl\n\n";

    open my $fatscript, "<", module_path( 'App::cpanminus::fatscript' ) or die $!;
    while ( <$fatscript> ) {
      next if $_ eq "\n";
      last if /^__END__$/;
      print $out $_;
      last if /# END OF FATPACK CODE\s*$/;
    }

    {
      open my $fh, "<", module_path( 'App::Mist::MPAN::prereqs' ) or die $!;
      while ( <$fh> ) {
        last if /^__END__$/;
        print $out $_;
      }
    }

    # TODO {
    # TODO   open my $fh, "<", module_path( 'App::Mist::MPAN::perlenv' ) or die $!;
    # TODO   while ( <$fh> ) {
    # TODO     last if /^__END__$/;
    # TODO     print $out $_;
    # TODO   }
    # TODO }

    if ( $perlbrew_version ) {
      open my $fh, "<", module_path( 'App::Mist::MPAN::perlbrew' ) or die $!;
      while ( <$fh> ) {
        last if /^__END__$/;
        print $out $_;
      }
      my @args = (
        $self->app->perlbrew_root,
        $perlbrew_version,
      );
    printf $out <<'PERL', map{ sprintf q{'%s'}, $_ } @args;

BEGIN {
  $PERLBREW_ROOT            = %s;
  $PERLBREW_DEFAULT_VERSION = %s;
}
PERL
    }

    open my $fh, "<", module_path( 'App::Mist::MPAN::install' ) or die $!;
    while ( <$fh> ) {
      last if /^__END__$/;
      print $out $_;
    }


    my @args = map{ sprintf( qq{'%s'}, $_ ) } (
      $app->perl5_base_lib->relative( $home ),
      $mpan->relative( $home ),
      $local_lib->relative( $home ),
    );

    push @args, (
      @prepend ? sprintf( qq{['%s']}, join qq{',\n    '}, @prepend ) : '[]',
      @notest  ? sprintf( qq{['%s']}, join qq{',\n    '}, @notest  ) : '[]',
      @prereqs ? sprintf( qq{['%s']}, join qq{',\n    '}, @prereqs ) : '[]',
    );

    printf $out <<'INSTALLER', @args;

BEGIN {
  $PERL5_BASE_LIB     = %s;
  $MPAN_DIST_DIR      = %s;
  $LOCAL_LIB_DIR      = %s;
  $PREPEND_DISTS      = %s;
  $DONT_TEST_DISTS    = %s;
  $PREREQUISITE_DISTS = %s;
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
