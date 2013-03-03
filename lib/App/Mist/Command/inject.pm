package App::Mist::Command::inject;

use strict;
use warnings;

use base 'App::Cmd::Command';

use Hook::LexWrap;
use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/file dir/;
use Cwd;

use File::Temp qw/ tempfile tempdir /;
use Data::Dumper;

sub execute {
  my ( $self, $opt, $args ) = @_;

  die "$0: No module to install"
    unless $args and ref $args eq 'ARRAY' and @$args;

  $self->app->ensure_correct_perlbrew_context;

  my $mpan      = $self->app->mpan_dist;
  my $local_lib = $self->app->local_lib;
  my $workspace = $self->app->workspace_lib;

  my @base_options   = (
    "--quiet",
    "--local-lib-contained=${local_lib}",
    "--mirror-only",
    "--save-dists=${mpan}",
  );

  # favor mpan-dist packages for dependencies
  my @dependency_options = (
    @base_options,
    "--mirror=file://${mpan}",
    "--mirror=http://search.cpan.org/CPAN",
    "--installdeps",
  );

  # use cpan itself for the requested package itself
  my @install_options = (
    @base_options,
    "--mirror=http://search.cpan.org/CPAN",
  );

  my $installed_packages = 0;
  my $initial_directory = cwd();

  $self->app->load_cpanm;

  DOWNLOAD_DIST: {
    my $guard = wrap 'App::cpanminus::script::build_stuff',
      pre  => sub{
        my ( $cpanm, $module, $dist ) = @_;
        printf STDERR "Downloading: %s\n", $module;
        $_[-1] = 1;             # shor-circuit call to prevent installation
      };

    try {
      no warnings 'redefine';
      *CORE::GLOBAL::exit = sub{};
      $self->app->run_cpanm( @install_options, @$args );
    } finally {
      chdir $initial_directory;
    };
  }

 CPANM_AUTO_INDEXER: {
    my $stage;

    my $guard = wrap 'App::cpanminus::script::build_stuff',
      pre  => sub{
        my ( $cpanm, $module, $dist ) = @_;
        printf STDERR "%s: %s\n", $stage, $module;
      },
      post => sub{
        my ( $cpanm, $module, $dist ) = @_;
        if ( $dist and my $success = !! $_[-1]  ) {
          $self->app->add_distribution_to_index( $dist );
          $installed_packages += 1;
        }
      };

    try {
      no warnings 'redefine';
      *CORE::GLOBAL::exit = sub{};
      $stage = 'Dependencies';
      my @dep_cmd_opts = grep { ! /--reinstall/ } @$args;
      $self->app->run_cpanm( @dependency_options, @dep_cmd_opts );
    } finally {
      chdir $initial_directory;
    };

    $stage = 'Building';
    $self->app->run_cpanm( @install_options, @$args );
  }

  $self->app->commit_mpan_package_index if $installed_packages;

}

1;
