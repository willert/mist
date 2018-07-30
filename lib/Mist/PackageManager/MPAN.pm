package Mist::PackageManager::MPAN;
use 5.014;
use utf8;

use Moo;
use MooX::late;
use MooX::HandlesVia;

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

has mirror_list => (
  is         => 'bare',
  isa        => 'ArrayRef',
  traits     => [qw/ Array /],
  lazy_build => 1,
  handles    => {
    mirror_list  => 'elements',
    add_mirror   => 'push',
  },
);

sub _build_mirror_list {
  my @mirrors;
  if ( my $mist_root = $ENV{MIST_APP_ROOT}) {
    printf STDERR "Mist root: %s\n", $mist_root;

    my $mpan = dir( $mist_root )->subdir( 'mpan-dist' );
    printf STDERR "MPAN: %s\n", $mpan;

    push @mirrors, "$mpan" if -d "$mpan";
  }

  # push @mirrors, 'http://www.cpan.org/';

  return \@mirrors;
}

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

around _build_mirror_list => sub {
  my ( $orig, $self, @args ) = @_;
  return [
    sprintf( 'file://%s/', $self->mpan_dist ),
    @{ $self->$orig( @args ) }
  ];
};

sub cpanm_mirror_options {
  my $self = shift;
  return ( map {( '--mirror' => $_ )} $self->mirror_list );
}

sub install {
  my ( $self, @cmd_args ) = @_;

  my $mpan      = $self->mpan_dist;
  my $local_lib = $self->local_lib;

  my @install_options = (
    '--quiet',
    '--local-lib-contained' => $self->local_lib,
    '--save-dists'          => $self->mpan_dist,

    $self->cpanm_mirror_options,

    '--mirror-only',
    '--cascade-search'
  );

  $self->run_bundled_cpanm_script( @install_options, @cmd_args );
}

sub commit {
  my $self = shift;

  my $updated_packages = 0;

  $self->mpan_dist->traverse( sub{
    my ( $dist, $cont ) = @_;

    return $cont->() if $dist->is_dir;

    # return $cont->() if $self->has_distribution_index_for( $dist )
    #   and $self->distribution_index( $dist )->{digest} eq md5_hex( $dist->slurp );

    return $cont->() if $self->has_distribution_index_for( $dist )
      and $self->distribution_index( $dist )->{mtime} == $dist->stat->mtime;

    $self->add_distribution_to_index( $dist );
    $updated_packages += 1;
    return $cont->();
  });

  $self->commit_mpan_package_index if $updated_packages;
}

# -- internals ---------------------------------------------------------------

sub cpan_dist_root { my $self = shift; $self->mpan_dist }

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

1;
