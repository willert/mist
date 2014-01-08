package App::Mist::Command::compile;
use 5.014;

use Moose;
extends 'MooseX::App::Cmd::Command';

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
  my $local_lib = $app->local_lib;


  chdir $home->stringify;

  try {

    my $assert  = "\n# TODO: assertions not yet implemented\n";

    my @prepend = $app->dist->get_prepended_modules;
    my @notest  = $app->dist->get_modules_not_to_test;
    my @prereqs = $app->fetch_prereqs;

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

    append_module_source( 'Mist::Distribution' => $out );
    append_module_source( 'Mist::Environment'  => $out );

    # append_module_source( 'App::Mist::MPAN::prereqs' => $out );

    print $out $app->mist_environment->as_code( package => 'DISTRIBUTION' );

    append_module_source('App::Mist::MPAN::perlbrew' => $out, VARS => [
      PERLBREW_ROOT            => $self->app->perlbrew_root,
      PERLBREW_DEFAULT_VERSION => $perlbrew_version,
    ]) if $perlbrew_version;

    append_module_source( 'Mist::Script::install' => $out, VARS => [
      PERL5_BASE_LIB     => $app->perl5_base_lib->relative( $home ),
      MPAN_DIST_DIR      => $mpan->relative( $home ),
      LOCAL_LIB_DIR      => $local_lib->relative( $home ),
      # PREPEND_DISTS      => \@prepend,
      # DONT_TEST_DISTS    => \@notest,
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
