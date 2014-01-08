package Mist::PackageManager::MPAN;
use 5.014;
use utf8;

use Moose;

extends 'Mist::PackageManager';
with (
  'Mist::Role::cpanminus',
  'Mist::Role::CPAN::PackageIndex',
);

use List::MoreUtils qw/ uniq /;
use Digest::MD5 qw/ md5_hex /;

use Try::Tiny;

my $VERBOSE = 0;
my $DEBUG = 0;

has distribution_index => (
  is         => 'bare',
  isa        => 'HashRef',
  traits     => [qw/ Hash /],
  handles    => {
    distribution_index => 'accessor',
    has_distribution_index_for => 'exists',
  },
  lazy_build => 1,
);

sub _build_distribution_index { return {}; }

has mpan_dist => ( is => 'ro', isa => 'Path::Class::Dir', lazy_build => 1 );
sub _build_mpan_dist   {
  my $self = shift;
  my $dist_dir = $self->project_root->subdir('mpan-dist');
  $dist_dir->mkpath;

  return $dist_dir;
}

sub use_cpan_dist_root { my $self = shift; $self->mpan_dist }

sub begin_work {
  my $self = shift;
  $self->clear_distribution_index;

  $self->mpan_dist->traverse( sub{
    my ( $dist, $cont ) = @_;
    $self->distribution_index( $dist => {
      'mtime'        => $dist->stat->mtime,
      'digest'       => md5_hex( $dist->slurp ),
    }) unless $dist->is_dir;

    return $cont->();
  });
}

sub install {
  my ( $self, $module, @args ) = @_;
  @args = @{ $args[0] } if @args == 1 and ref $args[0] eq 'ARRAY';

  my @modules = ref $module eq 'ARRAY' ? @$module : $module;

  my $mpan      = $self->mpan_dist;
  my $local_lib = $self->local_lib;

  my @base_options = (
    '--quiet',
    '--local-lib-contained' => $self->local_lib,
    '--save-dists' => $self->mpan_dist,

    '--mirror-only',
    '--mirror' => 'file://' . $self->mpan_dist . '/',
    '--mirror' => 'http://www.cpan.org/',
    '--cascade-search'
  );

  my @download_options = (
    @base_options,
    '--reinstall',
    '--no-skip-installed',
    '--perl' => '/bin/true',
  );

  my @dependency_options = (
    @base_options,
    '--installdeps',
    '--reinstall',
    '--save-dists' => $self->mpan_dist,
  );

  my @install_options = (
    @base_options,
  );

 INSTALL_MODULE: {
    # only report errors in the last cpanm call, they will most likely be the
    # same for all three calls anyways

#     {
#       # Download the dist via --look and a faked shell to open it in
#       local $ENV{SHELL} = '/bin/true';
#       $self->run_cpanm(
#         { -stderr => undef },
#         @download_options, @args, @modules
#       );
#     }

    # Force checking and, if not found, installing dependencies
#    $self->run_cpanm(
#      { -stderr => undef },
#       @dependency_options, @args, @modules
#    );

    # Finally install the module
    $self->run_cpanm( @install_options, @args, @modules );
  }
}

sub commit {
  my $self = shift;

  my $updated_packages = 0;

  $self->mpan_dist->traverse( sub{
    my ( $dist, $cont ) = @_;

    return $cont->() if $dist->is_dir;
    return $cont->() if $self->has_distribution_index_for( $dist )
      and $self->distribution_index( $dist )->{digest} eq md5_hex( $dist->slurp );

    $self->add_distribution_to_index( $dist );
    $updated_packages += 1;
    return $cont->();
  });

  $self->commit_mpan_package_index if $updated_packages;
}

# -- internals ---------------------------------------------------------------

{
  my $package_file;
  sub mpan_package_index {
    my $self = shift;
    if ( not $package_file ) {
      $package_file = $self->mpan_dist->file(
        'modules', '02packages.details.txt.gz'
      );
      $package_file->parent->mkpath;
    }
    return $package_file;
  }
}


sub commit_mpan_package_index {
  my ( $self, $dist ) = @_;

  # CPAN::PackageDetails seems to pick up empty header lines somehow
  # force-delete them to avoid warnings and unsightly index files
  delete $self->package_index->header->{''};

  my $packages = $self->mpan_package_index;
  $self->write_index;

  return;
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
