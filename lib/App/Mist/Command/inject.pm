package App::Mist::Command::inject;

use strict;
use warnings;

use App::Mist -command;

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

  my $mpan      = $self->app->mpan_dist;
  my $local_lib = $self->app->local_lib;
  my $workspace = $self->app->workspace_lib;

  my @options   = (
    "--quiet",
    "--local-lib-contained=${workspace}",
    "--mirror-only",
    "--mirror=http://search.cpan.org/CPAN",
    "--mirror=file://${mpan}",
    "--save-dists=${mpan}",
  );

  my $installed_packages = 0;

  $self->app->load_cpanm;

  CPANM_AUTO_INDEXER: {

    my $guard = wrap 'App::cpanminus::script::build_stuff',
      pre  => sub{
        my ( $cpanm, $module, $dist ) = @_;
        printf STDERR "Building: %s\n", $module;

      },
      post => sub{
        my ( $cpanm, $module, $dist ) = @_;

        if ( my $success = !! $_[-1]  ) {
          $self->app->add_distribution_to_index( $dist );
          $installed_packages += 1;
        }
      };

    $self->app->run_cpanm( @options, @$args );
  }

  $self->app->commit_mpan_package_index if $installed_packages;

}

1;
