package App::Mist::Command::compile;
# ABSTRACT: Recompile mpan-install for this project

use 5.010;

use App::Mist -command;

use App::Mist::Utils qw/ append_module_source append_text_file /;
use Module::Path qw/ module_path /;

use Try::Tiny;
use File::Copy;
use File::Share qw/ dist_file /;
use Path::Class qw/ dir /;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $ctx  = $self->app->ctx;
  my $home = $ctx->project_root;
  my $mpan = $ctx->mpan_dist;

  chdir $home->stringify;

  try {

    my $assert  = "\n# TODO: assertions not yet implemented\n";

    my @prepend = $ctx->dist->get_prepended_modules;
    my @notest  = $ctx->dist->get_modules_not_to_test;
    my @prereqs = $ctx->fetch_prereqs;

    my $perl_version = $ctx->perl_version;

    print "Generating mpan-install\n";

    open my $out, ">", "mpan-install.tmp" or die $!;
    print $out "#!/usr/bin/env perl\n\n";

    append_module_source( 'Getopt::Long' => $out, begin_lift => 1 );

    append_module_source(
      'App::cpanminus::fatscript' => $out,
      until => qr/# END OF FATPACK CODE\s*$/,
    );

    append_module_source( 'Devel::CheckBin'      => $out, begin_lift => 1 );
    append_module_source( 'Devel::CheckLib'      => $out, begin_lift => 1 );
    append_module_source( 'Devel::CheckCompiler' => $out, begin_lift => 1 );
    append_module_source( 'Probe::Perl'          => $out, begin_lift => 1 );

    append_module_source( 'Mist::Distribution' => $out );
    append_module_source( 'Mist::Environment'  => $out );

    print $out $ctx->mist_environment->as_code( package => 'DISTRIBUTION' );

    append_text_file(
      dist_file( 'App-Mist', 'cmd-wrapper.bash' ) => $out,
      package => 'CMD_WRAPPER::Bash',
    );

    # has to be included before Mist::Script::install so it has unfettered
    # access to @ARGV
    append_module_source('Mist::Script::perlbrew' => $out, VARS => [
      PERLBREW_ROOT            => $ctx->perlbrew_root,
      PERLBREW_DEFAULT_VERSION => $perl_version,
    ]);

    append_module_source( 'Mist::Script::install' => $out, VARS => [
      MPAN_DIST_DIR      => $mpan->relative( $home ),
      PREREQUISITE_DISTS => \@prereqs,
    ]);

    append_module_source( 'Mist::Script::usage' => $out, verbatim => 1 );

    close $out;

    unlink "mpan-install";
    rename "mpan-install.tmp", "mpan-install";
    chmod 0755, "mpan-install";

  } catch {

    warn "$_\n";

  } finally {

    unlink "mpan-install.tmp"

  };

}

1;
