package MistTest::Mirror;

# Test helper: build hermetic, CPAN-shaped mpan-dist mirrors holding a trivial
# but genuinely buildable module at chosen versions, indexed with mist's own
# indexer (Mist::CPAN::PackageIndex). Used to exercise the cpanm mirror-ordering
# behaviour --full-dependency-tree relies on, and the full bundle lifecycle, with
# no network and no shared fixtures.

use strict;
use warnings;

use Archive::Tar ();
use Archive::Tar::Constant qw/ COMPRESS_GZIP /;
use Path::Class ();
use File::Spec ();

use Mist::CPAN::PackageIndex;

# Build a buildable EUMM dist tarball for ($module => $version) into $dir.
# Returns the tarball Path::Class::File. The module is pure-perl with a $VERSION
# and a VERSION_FROM Makefile.PL, so cpanm builds+installs it and the indexer
# (via Mist::ParseDistribution) reads the version straight from the .pm.
sub make_dist {
  my ( $dir, $module, $version ) = @_;

  ( my $dist = $module ) =~ s/::/-/g;
  my $base = "$dist-$version";
  ( my $pm_rel = $module ) =~ s{::}{/}g;
  $pm_rel = "lib/$pm_rel.pm";

  my $tar = Archive::Tar->new;
  $tar->add_data( "$base/$pm_rel",
    "package $module;\nour \$VERSION = '$version';\n1;\n" );
  $tar->add_data( "$base/Makefile.PL",
    "use ExtUtils::MakeMaker;\n"
    . "WriteMakefile( NAME => '$module', VERSION_FROM => '$pm_rel' );\n" );

  my $file = Path::Class::dir( $dir )->file( "$base.tar.gz" );
  $file->parent->mkpath;
  $tar->write( "$file", COMPRESS_GZIP );
  return $file;
}

# Build (or extend) a CPAN-shaped mirror at $mirror_dir from a list of
# [ $module => $version ] pairs, then index it with mist's real indexer.
# Returns the mirror as a Path::Class::Dir.
sub make_mirror {
  my ( $mirror_dir, @dists ) = @_;

  my $mirror  = Path::Class::dir( $mirror_dir );
  my $authors = $mirror->subdir(qw/ authors id L LO LOCAL /);
  $authors->mkpath;

  make_dist( $authors, @$_ ) for @dists;

  # Silence the indexer's per-dist "Indexing ..." chatter so it stays out of TAP.
  my $idx = Mist::CPAN::PackageIndex->new( cpan_dist_root => $mirror );
  {
    local *STDOUT;
    open STDOUT, '>', File::Spec->devnull or die "devnull: $!";
    $idx->reindex_distributions;
  }

  return $mirror;
}

# A file:// mirror URL (trailing slash) for a mirror dir, as cpanm wants it.
sub url {
  my ( $mirror ) = @_;
  return "file://$mirror/";
}

1;
