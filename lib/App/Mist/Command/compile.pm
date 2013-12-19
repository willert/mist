package App::Mist::Command::compile;

use strict;
use warnings;

use base 'App::Cmd::Command';

use App::Mist::Utils qw/ append_module_source /;
use Module::Path qw/ module_path /;

use Try::Tiny;
use File::Copy;
use File::Share qw/ dist_file /;
use Path::Class qw/ dir /;
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

    append_module_source(
      'App::cpanminus::fatscript' => $out,
      until => qr/# END OF FATPACK CODE\s*$/,
    );

    append_module_source( 'Devel::CheckBin'      => $out );
    append_module_source( 'Devel::CheckLib'      => $out );
    append_module_source( 'Devel::CheckCompiler' => $out );
    append_module_source( 'Probe::Perl'          => $out );

    append_module_source( 'App::Mist::MPAN::prereqs' => $out );

    append_module_source('App::Mist::MPAN::perlbrew' => $out, VARS => [
      PERLBREW_ROOT            => $self->app->perlbrew_root,
      PERLBREW_DEFAULT_VERSION => $perlbrew_version,
    ]) if $perlbrew_version;

    append_module_source( 'App::Mist::MPAN::install' => $out, VARS => [
      PERL5_BASE_LIB     => $app->perl5_base_lib->relative( $home ),
      MPAN_DIST_DIR      => $mpan->relative( $home ),
      LOCAL_LIB_DIR      => $local_lib->relative( $home ),
      PREPEND_DISTS      => \@prepend,
      DONT_TEST_DISTS    => \@notest,
      PREREQUISITE_DISTS => \@prereqs,
    ]);

    close $out;

    unlink "mpan-install";
    rename "mpan-install.tmp", "mpan-install";
    chmod 0755, "mpan-install";

    print STDERR "Generating cmd wrapper\n";

    my $cmd_wrapper = 'cmd-wrapper.bash';
    my $wrapper = $app->mpan_dist->file( $cmd_wrapper )->stringify;
    copy( dist_file( 'App-Mist', $cmd_wrapper ), $wrapper );
    chmod 0755, $wrapper;

  } catch {

    warn "$_\n";

  } finally {

    unlink "mpan-install.tmp"

  };

}

1;
