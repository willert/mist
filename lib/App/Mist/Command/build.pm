package App::Mist::Command::build;

use strict;
use warnings;

use App::Mist -command;

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $cpanm = which( 'cpanm' )
    or die "cpanm not found";

  do $cpanm;
  require App::cpanminus;

  die "cpanm v$App::cpanminus::VERSION is too old, v1.4 needed"
    if $App::cpanminus::VERSION < 1.4;

  my $home = find_containing_dir_upwards( 'dist.ini' )
    or die "Can't find project root";

  my $mpan      = $home->subdir( $ENV{MIST_DIST_DIR}  || 'mpan-dist' );
  my $mpan_conf = $mpan->subdir( 'mist' );
  my $local_lib = $home->subdir( $ENV{MIST_LOCAL_LIB} || 'perl5' );

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

    open my $in,  "<", "$cpanm" or die $!;
    open my $out, ">", "mist-install.tmp" or die $!;

    print STDERR "Generating mist-installer\n";

    while (<$in>) {
        print $out $_;
        last if /# END OF FATPACK CODE\s*$/;
    }

    my $slurp_file = sub{
      my $file = shift;
      my @lines;
      printf STDERR "Reading: %s\n", $file;

      if ( -f -r $file->stringify ) {
        my $fh = $file->openr;
        @lines = readline $fh;
        chomp for @lines;
        @lines = grep{ $_ } @lines;
      }

      return wantarray ? @lines : join( "\n", @lines, '' );
    };

    my $prereqs = $slurp_file->( $dist_prereqs );
    my @prepend = $slurp_file->( $dist_prepend );
    my @notest  = $slurp_file->( $dist_notest );

    my @prereqs = qx{ dzil listdeps };
    chomp for @prereqs;
    @prereqs = grep{ $_ } @prereqs;

    my @args = (
      $mpan->relative( $home ),
      $local_lib->relative( $home ),
      $prereqs,
      @notest  ? sprintf( qq{'%s'}, join qq{',\n    '}, @notest  ) : '',
      @prereqs ? sprintf( qq{'%s'}, join qq{',\n    '}, @prereqs ) : '',
    );

    # use Data::Dumper::Concise;
    # printf STDERR '@Args: %s%s', Dumper( \@args ), "\n";


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

  die "mist-install can not run as root\n" if $> == 0;

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

  run_cpanm( @ARGV, @prepend ) if @prepend;
  run_cpanm( @ARGV, '--installdeps', @notest ) if @notest;
  run_cpanm( @ARGV, '--notest', @notest ) if @notest;

  require local::lib;
  print $env local::lib->environment_vars_string_for( "${local_lib}" );
  close $env;

  print <<"SUCCESS";

Successfully created a mist environment for this distribution.
To enable it put the following line in your scripts:
  source $mist_rc

SUCCESS
}

INSTALLER

    close $out;

    unlink "mist-install";
    rename "mist-install.tmp", "mist-install";
    chmod 0755, "mist-install";

  } catch {
    warn "$_\n";
  } finally {

    unlink "mist-install.tmp"

  };

}



1;
