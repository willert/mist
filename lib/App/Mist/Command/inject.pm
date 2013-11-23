package App::Mist::Command::inject;

use strict;
use warnings;

use base 'App::Cmd::Command';

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
  );

  my @download_options = (
    @base_options,
    "--save-dists=${mpan}",

    # use cpan for the requested package itself
    "--mirror=http://search.cpan.org/CPAN",
  );

  my @dependency_options = (
    @base_options,
    "--installdeps",
    "--save-dists=${mpan}",

    # favor mpan-dist packages for dependencies
    "--mirror=file://${mpan}",
    "--mirror=http://search.cpan.org/CPAN",
    "--cascade-search"
  );

  my @install_options = (
    @base_options,

    # use cpan for the requested package itself
    "--mirror=http://search.cpan.org/CPAN",
  );

  my $installed_packages = 0;
  my $initial_directory = cwd();

  my %mpan_dist_files;
  $self->app->mpan_dist->traverse( sub{
    my ( $dist, $cont ) = @_;
    $mpan_dist_files{ $dist->stringify } = {
      'pre-existing' => 1,
      'mtime'        => $dist->stat->mtime
    } unless $dist->is_dir;
    return $cont->();
  });

  $self->app->load_cpanm;

  my @modules  = grep{ !/^-/ } @$args;
  my @cmd_args = grep{ /^-/ } @$args;

  for my $module ( @modules ) {

    printf "Injecting %s ...\n", $module;

  DOWNLOAD_DIST: {
      try {
        local $ENV{SHELL} = '/bin/true';
        $self->app->run_cpanm( '--look', @download_options, @cmd_args, $module );
      } finally {
        chdir $initial_directory;
      };
    }

  CPANM_AUTO_INDEXER: {
      my $stage;

      try {
        $stage = 'Dependencies';
        my @dep_cmd_opts = ( '--reinstall', grep { !/--reinstall/ } @cmd_args );
        $self->app->run_cpanm( @dependency_options, @dep_cmd_opts, $module );
      } finally {
        chdir $initial_directory;
      };

      $stage = 'Building';
      $self->app->run_cpanm( @install_options, @cmd_args, $module );
    }

  }

  my $updated_packages = 0;

  $self->app->mpan_dist->traverse( sub{
    my ( $dist, $cont ) = @_;
    return $cont->() if $dist->is_dir;
    my $mtime = $dist->stat->mtime;
    return $cont->() if exists $mpan_dist_files{ $dist->stringify }
      and $mpan_dist_files{ $dist->stringify }{mtime} >= $mtime;
    $self->app->add_distribution_to_index( $dist );
    $updated_packages += 1;
    return $cont->();
  });

  $self->app->commit_mpan_package_index if $updated_packages;

}

1;
