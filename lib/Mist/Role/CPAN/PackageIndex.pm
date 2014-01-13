package Mist::Role::CPAN::PackageIndex;

use 5.010;
use Moose::Role;

use Path::Class ();
use Carp;

use Mist::ParseDistribution;
use CPAN::DistnameInfo;
use CPAN::PackageDetails;

use File::Temp ();

my $VERBOSE = 0;
my $DEBUG = 0;

requires 'use_cpan_dist_root';

has cpan_dist_root => (
  is      => 'ro',
  lazy    => 1,
  builder => 'use_cpan_dist_root',
);

has cpan_index_file => (
  is         => 'ro',
  isa        => 'Path::Class::File',
  lazy_build => 1,
);

sub create_empty_package_index {
  my $self = shift;

  return CPAN::PackageDetails->new(
    file        => "02packages.details.txt",
    description => "Package names for my private CPAN",
    columns     => "package name, version, path",
    line_count  => 0,

    allow_packages_only_once => 0,

    intended_for => "My private CPAN",
    url          => "http://example.com/MyCPAN/modules/02packages.details.txt",
    written_by   => "$0 using CPAN::PackageDetails" .
      $CPAN::PackageDetails::VERSION,
  );
}

sub _build_cpan_index_file {
  my $self = shift;
  my $dist_dir = $self->cpan_dist_root;
  my $package_file = $dist_dir->file(qw/ modules 02packages.details.txt.gz /);

  $package_file->parent->mkpath;

  if ( not -r -f "$package_file" ) {
    my $empty_index = $self->create_empty_package_index;
    $self->write_index( $empty_index, $package_file );
  }

  return $package_file;
}


has package_index => (
  is         => 'ro',
  isa        => 'CPAN::PackageDetails',
  lazy_build => 1,
);

sub _build_package_index {
  my $self = shift;

  no strict 'refs';
  no warnings 'redefine';

  my $org = \&CPAN::PackageDetails::init;
  local *{"CPAN::PackageDetails::init"} = sub{
    push @_, allow_packages_only_once => 0;
    goto &$org;
  };

  my $index = do {
    local $SIG{__WARN__} = sub{
      print STDERR "@_\n" unless $_[0] =~ m{ \b uninitialized \b}x;
    };
    CPAN::PackageDetails->read( q{}. $self->cpan_index_file );
  };

  return $index;
}

sub add_distribution_to_index {
  my ( $self, $dist, $index ) = @_;

  $index //= $self->package_index;

  my $dist_info = $self->parse_distribution( $dist );

  printf "Indexing %s\n", $dist_info->module_path;

  my $modules = $dist_info->modules;

  if ( not %$modules ) {
    # parsing dist failed, try to at least index main module
    my $dist_name = CPAN::DistnameInfo->new( q{}. $dist_info->pathname );
    my $main_module = $dist_name->dist;
    $main_module =~ s/-/::/g;
    $modules->{ $main_module } = $dist_name->version
      if $dist_name->version;
  }

  while ( my ( $pkg, $version ) = each %$modules ) {

    my $do_index = sub {
      $index->add_entry(
        package_name => $pkg,
        version      => $version // 0,
        path         => $dist_info->module_path,
      );
    };

    $VERBOSE ? &$do_index() : eval{ &$do_index() };

    if ( my $err = $@ ) {
      $err =~ s/(.*) at .*/$1/s;
      print STDERR "  [WARNING] ${err}\n" if $VERBOSE;
    }
  }

  return;
}

sub parse_distribution {
  my ( $self, $path ) = @_;

  croak "Can't read dist file ${path}" unless -r -f "$path";

  my $dist_info = CPAN::DistnameInfo->new( $path );

  warn "$0: skipping $_\n" and return
    unless $dist_info->distvname;

  return Mist::ParseDistribution->new(
    $dist_info->pathname,
    repository => $self->cpan_dist_root
  );
}

sub reindex_distributions {
  my $self = shift;

  my $index = $self->create_empty_package_index;

  $self->cpan_dist_root->subdir(qw/ authors id /)->traverse( sub{
    my ( $dist, $cont ) = @_;
    $self->add_distribution_to_index( $dist, $index ) unless $dist->is_dir;
    return $cont->();
  });

  $self->write_index( $index );
}

sub write_index {
  my ( $self, $index, $filename ) = @_;
  $index    //= $self->package_index;
  $filename //= $self->cpan_index_file->stringify;

  local $SIG{__WARN__} = sub{
    print STDERR "@_\n" unless $_[0] =~ m{ entries \s+ is \s+ deprecated }x;
  };

  $index->write_file( $filename );

  my $dist_dir = $self->cpan_dist_root;
  my $package_file = $dist_dir->file(qw/ modules 02packages.details /);
  $index->write_fh( $package_file->openw );

  return;
}

no Moose::Role;

1;
