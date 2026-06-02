package Mist::ParseDistribution;
use strict;
use warnings;

use base 'CPAN::ParseDistribution';
use Path::Class ();
use Carp;

# Those are dynamically loaded normally. Force pre-loading them
# because we will use mist's local::lib in the process of
# installing distributions
use CPAN::ParseDistribution::Unix;
use Devel::AssertOS::Unix;

use Module::Metadata 1.000033;
use CPAN::Meta ();
use Archive::Tar ();
use Archive::Zip ();
use Cwd ();
use File::Find ();
use File::Path qw/ rmtree /;
use File::Spec ();
use File::Temp ();
use YAML ();

sub new {
  my ( $class, $file, %extra_params ) = @_;

  my $repo = delete $extra_params{repository}
    or croak "missing 'repository' parameter pointing to a Mist repository";

  my $self = eval{ $class->SUPER::new( $file, %extra_params )};

  croak( $@ ) if $@;

  $self->{pathname}   = Path::Class::file( $file )->absolute->resolve;
  $self->{repository} = Path::Class::dir(  $repo )->absolute->resolve;

  $self->modules; # force vivification of module hash

  return $self;
}

sub pathname {
  my $self = shift;
  return $self->{pathname};
}

sub repository {
  my $self = shift;
  return $self->{repository};
}

sub repository_path {
  my $self = shift;
  Path::Class::file( $self->pathname )->relative( $self->repository );
}

sub module_path {
  my $self = shift;
  Path::Class::file( $self->pathname )->relative(
    $self->repository->subdir(qw/ authors id /)
  );
}

sub as_module_name {
  my $self = shift;
  my $name = $self->{dist};
  $name =~ s/-/::/g;
  return $name;
}

# Override CPAN::ParseDistribution's modules(). Upstream's regex-based
# scanner has two bugs: it misses inline-version package syntax
# (`package Foo 1.23;`) and matches `package Foo;` inside POD example
# blocks. This implementation mirrors PAUSE's own indexing behaviour:
#
#   1. If META declares a `provides:` block, that is authoritative.
#   2. Otherwise walk *.pm under the dist, honouring no_index/directory
#      (hardcoded t/xt/inc plus any META additions), no_index/file,
#      no_index/package, and no_index/namespace.
#   3. Per file, take ONLY the first non-main package in declaration
#      order — matching the original parser's no-/g behaviour, which
#      kept fatpacked installers (cpanm) and compat-shim files
#      (XSLoader.pm declaring DynaLoader) from polluting the index.
#
# Package extraction and version parsing run through Module::Metadata
# (the reference implementation used by Module::Build / EU::MM /
# Carton), so all modern package-declaration forms work and POD blocks
# are correctly skipped.
sub modules {
  my $self = shift;
  return $self->{modules} if keys %{ $self->{modules} ||= {} };

  my $tempdir = $self->_extract_dist;

  my ( $distroot ) = grep { -d $_ } glob "$tempdir/*";
  $distroot //= $tempdir;

  $self->{modules} = $self->_index_distroot( $distroot );

  rmtree( $tempdir );
  return $self->{modules};
}

sub _index_distroot {
  my ( $self, $distroot ) = @_;

  my $meta = $self->_read_meta( $distroot ) || {};

  # META 'provides' is the canonical answer when the author bothered to
  # declare it — short-circuit the file walk entirely.
  if ( ref $meta->{provides} eq 'HASH' ) {
    return {
      map {
        my $entry = $meta->{provides}{$_};
        $_ => ref $entry eq 'HASH' ? $entry->{version} : undef;
      } keys %{ $meta->{provides} }
    };
  }

  my $no_index = ref $meta->{no_index} eq 'HASH' ? $meta->{no_index} : {};
  my %ignored_dirs  = map { $_ => 1 } qw/ t xt inc test /;
  $ignored_dirs{ $_ } = 1 for _listify( $no_index->{directory} );
  my %ignored_files = map { $_ => 1 } _listify( $no_index->{file} );
  my %ignored_pkgs  = map { $_ => 1 } _listify( $no_index->{package} );
  my @ignored_ns    = _listify( $no_index->{namespace} );

  my @pm_files;
  File::Find::find( {
    no_chdir => 1,
    wanted   => sub {
      return unless -f $_ and /\.pm$/;
      my $rel = File::Spec->abs2rel( $_, $distroot );
      my ( $top ) = File::Spec->splitdir( $rel );
      # Match upstream: ignore only top-level directories. Sub-paths
      # like lib/inc/Module/Install.pm are legitimate even though they
      # contain "inc" deeper in the tree.
      return if $top and $ignored_dirs{ $top };
      return if $ignored_files{ $rel };
      push @pm_files, $_;
    },
  }, $distroot );

  my %result;
  for my $pm ( @pm_files ) {
    my $info = Module::Metadata->new_from_file( $pm ) or next;

    my ( $primary ) = grep {
      _is_indexable( $_, \%ignored_pkgs, \@ignored_ns )
    } $info->packages_inside;
    next unless defined $primary;

    $result{ $primary } = $info->version( $primary );
  }

  return \%result;
}

sub _is_indexable {
  my ( $pkg, $ignored_pkgs, $ignored_ns ) = @_;
  return 0 if $pkg eq 'main' or $pkg eq 'DB';
  return 0 if grep { /^_/ } split /::/, $pkg;
  return 0 if $ignored_pkgs->{ $pkg };
  for my $ns ( @$ignored_ns ) {
    return 0 if $pkg eq $ns or index( $pkg, "${ns}::" ) == 0;
  }
  return 1;
}

sub _read_meta {
  my ( $self, $distroot ) = @_;

  # META.yml is read exactly as before, so every dist that ships it indexes
  # identically. Fall back to META.json (via CPAN::Meta, which reads the v2
  # format) only when META.yml is absent, so a JSON-only dist still has its
  # provides / no_index honoured instead of dropping to the .pm file walk.
  # Both readers fail soft: a malformed file returns undef and the caller
  # walks the files. as_struct yields a plain hashref whose provides/no_index
  # match the shape _index_distroot already expects.
  my ( $yml ) = glob "$distroot/META.yml";
  if ( $yml and -f $yml ) {
    my $meta = eval { YAML::LoadFile( $yml ) };
    return ref $meta eq 'HASH' ? $meta : undef;
  }

  my ( $json ) = glob "$distroot/META.json";
  if ( $json and -f $json ) {
    my $meta = eval { CPAN::Meta->load_file( $json )->as_struct };
    return ref $meta eq 'HASH' ? $meta : undef;
  }

  return undef;
}

sub _listify {
  my ( $val ) = @_;
  return ()        unless defined $val;
  return @$val     if ref $val eq 'ARRAY';
  return ( $val );
}

# In-tree replacement for CPAN::ParseDistribution::_unarchive — we own
# the extraction so an upstream rename of that private helper can't
# silently break the indexer. chdirs into a tempdir because both
# Archive::Tar->extract and Archive::Zip->extractTree work on cwd.
sub _extract_dist {
  my $self = shift;
  my $file = $self->{file};

  my $tempdir = File::Temp::tempdir( TMPDIR => 1 );
  my $cwd     = Cwd::getcwd();

  chdir $tempdir or die "chdir $tempdir: $!\n";
  eval {
    if ( $file =~ /\.zip$/i ) {
      Archive::Zip->new( "$file" )->extractTree;
    } elsif ( $file =~ /\.(?:tar(?:\.gz)?|tgz)$/i ) {
      Archive::Tar->new( "$file", 1 )->extract;
    } elsif ( $file =~ /\.(?:tar\.bz2|tbz)$/i ) {
      open my $fh, '-|', 'bzip2', '-dc', "$file"
        or die "Can't unbzip2 $file: $!\n";
      Archive::Tar->new( $fh )->extract;
      close $fh;
    } else {
      die "Unknown archive type: $file\n";
    }
    1;
  };
  my $err = $@;
  chdir $cwd or die "chdir back to $cwd: $!\n";
  die $err if $err;

  return $tempdir;
}

1;
