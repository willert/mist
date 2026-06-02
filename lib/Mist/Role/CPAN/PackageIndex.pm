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

# Transient state across a single reindex_distributions run: tracks
# which (existing_dist, incoming_dist) collision pairs have already
# emitted a warning, so we don't spam one per affected package. Reset
# at the start of each reindex.
has _seen_collisions => (
  is      => 'rw',
  default => sub { {} },
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
    # index can't tell which dist canonically owns the package. Dedup
    # per (existing_dist, incoming_dist) so the build-master sees one
    # signal per dist pair, not one per affected package. Cleanup is
    # iterative — fix the surfaced pair, re-run, the next pair (if any)
    # appears. (Inner hash from get_hash is keyed by VERSION, not path —
    # read paths off the entry objects.)
    if ( $index->already_added( $pkg ) ) {
      my $existing = $index->entries->get_hash->{ $pkg } || {};
      for my $entry ( values %$existing ) {
        my $other_path = $entry->path;
        next if $other_path eq "$current_path";
        my $other_dist = CPAN::DistnameInfo->new( $other_path )->dist // '';
        next if $other_dist eq $current_dist;

        my $key = join "\0", $other_dist, $current_dist;
        next if exists $self->_seen_collisions->{ $key };
        $self->_seen_collisions->{ $key } = {
          existing_dist => $other_dist,
          existing_path => "$other_path",
          incoming_dist => $current_dist,
          incoming_path => "$current_path",
          first_pkg     => $pkg,
        };

        printf STDERR
          "  [WARNING] Cross-dist collision: %s <-> %s (first: %s)\n"
          . "    %s\n"
          . "    %s\n"
          . "    Remove one tarball to resolve.\n",
          $other_dist, $current_dist, $pkg, $other_path, $current_path;
      }
    }

    my $do_index = sub {
      # Stringify in case $version is a version object (Module::Metadata
      # and many .pm files using `version->declare(...)` return objects).
      # CPAN::PackageDetails::_parse_version warns "Invalid version format"
      # on objects and falls back to 0, producing thousands of warnings
      # per reindex. The stringification overload yields the canonical
      # version string and silences the noise.
      $index->add_entry(
        package_name => $pkg,
        version      => defined $version ? "$version" : 0,
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

  $self->_seen_collisions( {} );

  my @paths = $self->_dist_tarballs_lowest_version_first;
  for my $path ( @paths ) {
    $self->add_distribution_to_index( $path, $index );
  }

  $self->write_index( $index );
  $self->_print_reindex_report( $index, \@paths );
}

# After a full reindex, summarise anything the build-master may want to
# act on: cross-dist collisions (recap of inline warnings) and tarballs
# under mpan-dist that no longer have any package entry pointing at
# them (older versions superseded by highest-version-wins, dists whose
# packages were stolen by a competing tarball, etc.).
sub _print_reindex_report {
  my ( $self, $index, $collected_paths ) = @_;

  my $collisions = $self->_seen_collisions;
  my @obsolete   = $self->_unreferenced_tarballs( $index, $collected_paths );

  return unless %$collisions or @obsolete;

  print STDERR "\n=== mist index report ===\n";

  if ( %$collisions ) {
    print STDERR "\nCross-dist collisions (one signal per dist pair; "
               . "cleanup is iterative — re-run after resolving):\n";
    for my $c ( map { $collisions->{ $_ } } sort keys %$collisions ) {
      printf STDERR "  %s <-> %s (first: %s)\n    %s\n    %s\n",
        $c->{existing_dist}, $c->{incoming_dist}, $c->{first_pkg},
        $c->{existing_path}, $c->{incoming_path};
    }
  }

  if ( @obsolete ) {
    print STDERR "\nObsolete tarballs (in mpan-dist but unreferenced from "
               . "02packages — typically superseded by a higher-version sibling, "
               . "or out-competed for every package by another dist):\n";
    print STDERR "  $_\n" for @obsolete;
  }

  print STDERR "\n";
}

# Diff the collected tarball set against paths actually referenced from
# the freshly-built index. Returns relative paths in the same form
# 02packages uses (e.g. R/RJ/RJBS/Foo-1.0.tar.gz or ../../vendor/Foo.tar.gz).
sub _unreferenced_tarballs {
  my ( $self, $index, $collected_paths ) = @_;

  my $authors_id = $self->cpan_dist_root->subdir(qw/ authors id /);

  # as_unique_sorted_list returns the final entries (highest version
  # per package) — the same set that actually lands in 02packages. The
  # raw entries hash also contains lower-version entries that get
  # dropped at write time, which would mask the obsolescence. The
  # method returns an arrayref even in list context, so deref.
  my ( $final ) = $index->entries->as_unique_sorted_list;  # list ctx; arrayref
  my %referenced = map { ( $_->path => 1 ) } @$final;

  my @obsolete;
  for my $path ( @$collected_paths ) {
    my $rel = Path::Class::file( "$path" )->relative( $authors_id );
    push @obsolete, "$rel" unless $referenced{ "$rel" };
  }

  return sort @obsolete;
}

# Order distribution version strings the way point releases are actually cut:
# 1.2 < 1.9 < 1.10. version->parse (and CPAN::Version->vcmp) read a bare decimal
# '1.10' as 1.1, which sorts it below 1.9 and inverts the highest-version-wins
# dedup below for any dist with a multi-digit point release. Compare the
# dot/underscore-separated numeric components instead; this also keeps v-strings
# (v1.2.3) and long CPAN::Meta versions (2.150010) in intuitive order, and does
# not choke on v-strings the way version->parse("v$ver") would.
sub _version_parts {
  my $v = shift;
  $v = '0' unless defined $v && length $v;
  $v =~ s/^v//i;
  return [ map { /(\d+)/ ? $1 : 0 } split /[._]/, $v ];
}

sub _version_cmp {
  my @x = @{ _version_parts( shift ) };
  my @y = @{ _version_parts( shift ) };
  for my $i ( 0 .. ( @x > @y ? $#x : $#y ) ) {
    my $c = ( $x[$i] // 0 ) <=> ( $y[$i] // 0 );
    return $c if $c;
  }
  return 0;
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
      || _version_cmp( $a->[1], $b->[1] )
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
