package Mist::Role::CPAN::PackageIndex;

use 5.010;
use Moo::Role;
use MooX::late;

use Path::Class ();
use Carp;
use version 0.74 ();

use Mist::ParseDistribution;
use CPAN::DistnameInfo;

use CPAN::PackageDetails;

# Those are dynamically loaded normally. Force pre-loading them
# because we will use mist's local::lib in the process of
# installing distributions
use CPAN::PackageDetails::Header;
use CPAN::PackageDetails::Entries;
use CPAN::PackageDetails::Entry;


use File::Temp ();

my $VERBOSE = 0;
my $DEBUG = 0;

requires 'cpan_dist_root';

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

  my $dist_name = CPAN::DistnameInfo->new( q{}. $dist_info->pathname );
  my $main_module = $dist_name->dist;
  $main_module =~ s/-/::/g;

  if ( not $modules->{ $main_module } ) {
    # parsing dist failed, try to at least index main module
    $main_module = 'Term::ReadKey' if $main_module eq 'TermReadKey';
    printf ".. getting modules failed, defaulting to %s\n", $main_module;
    $modules->{ $main_module } = $dist_name->version // 0;
  }

  my $current_path = $dist_info->module_path;
  my $current_dist = $dist_name->dist // '';

  while ( my ( $pkg, $version ) = each %$modules ) {

    # Cross-dist collision warning: when a package already in the index
    # points at a tarball whose parsed dist name differs from ours, the
    # index can't tell which dist canonically owns the package. Surface
    # it so the build-master can remove the obsolete tarball. (The inner
    # hash from get_hash is keyed by VERSION, not path — read paths off
    # the entry objects themselves.)
    if ( $index->already_added( $pkg ) ) {
      my $existing = $index->entries->get_hash->{ $pkg } || {};
      for my $entry ( values %$existing ) {
        my $other_path = $entry->path;
        next if $other_path eq "$current_path";
        my $other_dist = CPAN::DistnameInfo->new( $other_path )->dist // '';
        next if $other_dist eq $current_dist;
        printf STDERR
          "  [WARNING] Cross-dist collision for %s:\n"
          . "    existing: %s (%s)\n"
          . "    incoming: %s (%s)\n"
          . "    incoming wins; remove obsolete tarball to silence.\n",
          $pkg, $other_path, $other_dist, $current_path, $current_dist;
      }
    }

    my $do_index = sub {
      $index->add_entry(
        package_name => $pkg,
        version      => $version // 0,
        path         => $current_path,
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
  my $self  = shift;
  my $index = $self->create_empty_package_index;

  for my $path ( $self->_dist_tarballs_lowest_version_first ) {
    $self->add_distribution_to_index( $path, $index );
  }

  $self->write_index( $index );
}

# Collect every tarball under authors/id/ (and vendor/ when present),
# then sort so that within each dist the lowest-versioned tarball is
# visited first and the highest is visited last. CPAN::PackageDetails
# uses last-writer-wins for duplicate package entries, so this makes
# every submodule attribute to the highest-version tarball of its dist.
sub _dist_tarballs_lowest_version_first {
  my $self = shift;

  my @paths;
  for my $root (
    $self->cpan_dist_root->subdir(qw/ authors id /),
    $self->cpan_dist_root->subdir(qw/ vendor /),
  ) {
    next unless -d $root->stringify;
    $root->traverse( sub {
      my ( $f, $cont ) = @_;
      push @paths, $f unless $f->is_dir;
      return $cont->();
    });
  }

  return
    map  { $_->[2] }
    sort {
         $a->[0] cmp $b->[0]
      || ( eval { version->parse( $a->[1] ) <=> version->parse( $b->[1] ) } || 0 )
      || $a->[2] cmp $b->[2]
    }
    map  {
      my $info = CPAN::DistnameInfo->new( "$_" );
      [ $info->dist // '', $info->version // 0, $_ ];
    }
    @paths;
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

1;
