#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use Cwd ();
use File::Spec;
use File::Temp ();
use Archive::Tar ();

use Mist::ParseDistribution;

# Build a .tar.gz distribution tarball in $dir from an in-memory
# { 'relative/path.pm' => $source } map. Every member is rooted under a
# single top-level "$distname/" directory, mirroring a real CPAN tarball
# (Mist::ParseDistribution::modules picks the lone subdir as the distroot).
# Returns the absolute path to the created tarball.
sub build_tarball {
  my ( $dir, $distname, %files ) = @_;

  my $tar  = Archive::Tar->new;
  for my $rel ( sort keys %files ) {
    $tar->add_data( "$distname/$rel", $files{ $rel } );
  }

  # Archive::Tar->write second arg is the gzip compression level;
  # COMPRESS_GZIP is the constant 9. Pass it numerically to avoid
  # importing Archive::Tar::Constant.
  my $path = File::Spec->catfile( $dir, "$distname.tar.gz" );
  $tar->write( $path, 9 )
    or die "could not write tarball $path: " . $tar->error;
  return $path;
}

# Index a tarball and return the module => version hashref.
# The repository argument is mandatory but irrelevant to indexing here;
# point it at any existing directory.
sub index_tarball {
  my ( $tarball, $repo ) = @_;
  my $dist = Mist::ParseDistribution->new( $tarball, repository => $repo );
  return $dist->modules;
}

# Stringify a version map for stable, readable is_deeply diffs:
# Module::Metadata->version returns version objects, not plain scalars.
sub stringify_versions {
  my ( $modules ) = @_;
  return {
    map { $_ => defined $modules->{ $_ } ? "$modules->{ $_ }" : undef }
    keys %$modules
  };
}

my $tmp = File::Temp::tempdir( CLEANUP => 1 );

# --- Core fixture: inline-version + POD trap + nested module -----------------
#
# Foo.pm uses the inline-version package syntax `package Foo 1.23;` that
# upstream CPAN::ParseDistribution's regex scanner misses, and embeds a
# `package Trap::InPod;` line inside a POD block that the same upstream
# scanner wrongly indexes. Foo/Bar.pm is an ordinary nested module.

my $foo_pm = <<'END_FOO';
package Foo 1.23;
use strict;
use warnings;

=head1 NAME

Foo - example distribution

=head1 EXAMPLE

The following looks like a package declaration but lives inside POD and
must never be indexed:

    package Trap::InPod;

=cut

sub hello { 'world' }

1;
END_FOO

my $bar_pm = <<'END_BAR';
package Foo::Bar;
use strict;
use warnings;
our $VERSION = "0.5";
1;
END_BAR

CORE: {
  my $tarball = build_tarball(
    $tmp, 'Foo-1.23',
    'lib/Foo.pm'     => $foo_pm,
    'lib/Foo/Bar.pm' => $bar_pm,
  );

  my $modules = index_tarball( $tarball, $tmp );

  is_deeply stringify_versions( $modules ),
    { 'Foo' => '1.23', 'Foo::Bar' => '0.5' },
    'index is exactly { Foo => 1.23, Foo::Bar => 0.5 }';

  is "$modules->{Foo}", '1.23',
    'inline-version syntax `package Foo 1.23;` is parsed (inline-version fix)';

  ok !exists $modules->{'Trap::InPod'},
    '`package Trap::InPod;` inside a POD block is NOT indexed (POD-trap fix)';
}

# --- no_index directory: t/ is hardcoded-ignored ----------------------------
#
# A .pm under a top-level t/ directory must be excluded even though it
# declares an ordinary indexable package.

NO_INDEX_DIR_HARDCODED: {
  my $tarball = build_tarball(
    $tmp, 'Hard-1.0',
    'lib/Hard.pm'           => "package Hard;\nour \$VERSION = '1.0';\n1;\n",
    't/lib/Hard/Helper.pm'  => "package Hard::Helper;\nour \$VERSION = '9.9';\n1;\n",
  );

  my $modules = index_tarball( $tarball, $tmp );

  is_deeply stringify_versions( $modules ),
    { 'Hard' => '1.0' },
    'module under hardcoded-ignored t/ directory is excluded';
}

# --- no_index from META.yml: directory, package, namespace ------------------
#
# META.yml declares additional no_index rules. Verify each kind excludes
# the matching module while leaving the canonical one indexed.

NO_INDEX_META: {
  my $meta = <<'END_META';
---
name: Meta-2.0
version: 2.0
no_index:
  directory:
    - private
  package:
    - Meta::Secret
  namespace:
    - Meta::Internal
END_META

  my $tarball = build_tarball(
    $tmp, 'Meta-2.0',
    'META.yml'                          => $meta,
    'lib/Meta.pm'                       => "package Meta;\nour \$VERSION = '2.0';\n1;\n",
    'private/Meta/Hidden.pm'            => "package Meta::Hidden;\nour \$VERSION = '7';\n1;\n",
    'lib/Meta/Secret.pm'               => "package Meta::Secret;\nour \$VERSION = '8';\n1;\n",
    'lib/Meta/Internal/Detail.pm'      => "package Meta::Internal::Detail;\nour \$VERSION = '9';\n1;\n",
  );

  my $modules = index_tarball( $tarball, $tmp );

  is_deeply stringify_versions( $modules ),
    { 'Meta' => '2.0' },
    'META no_index directory/package/namespace rules all exclude their matches';
}

# --- first non-main package per file only -----------------------------------
#
# A file declaring two real packages indexes ONLY the first one, matching
# the original parser's no-/g behaviour that kept compat-shim files from
# polluting the index. `main` is skipped, so the first *non-main* package
# wins even when a stray `package main;` precedes it.

FIRST_PACKAGE_ONLY: {
  my $multi_pm = <<'END_MULTI';
package main;
package Multi::First;
our $VERSION = '3.0';
package Multi::Second;
our $VERSION = '4.0';
1;
END_MULTI

  my $tarball = build_tarball(
    $tmp, 'Multi-3.0',
    'lib/Multi.pm' => $multi_pm,
  );

  my $modules = index_tarball( $tarball, $tmp );

  is_deeply stringify_versions( $modules ),
    { 'Multi::First' => '3.0' },
    'only the first non-main package in a file is indexed';
}

# --- META provides short-circuits the file walk -----------------------------
#
# When META.yml carries a provides block it is authoritative: the indexer
# returns exactly that map without scanning .pm files.

META_PROVIDES: {
  my $meta = <<'END_META';
---
name: Prov-5.0
version: 5.0
provides:
  Prov::Declared:
    file: lib/Prov/Declared.pm
    version: 5.5
END_META

  my $tarball = build_tarball(
    $tmp, 'Prov-5.0',
    'META.yml'                  => $meta,
    'lib/Prov.pm'               => "package Prov;\nour \$VERSION = '5.0';\n1;\n",
    'lib/Prov/Declared.pm'      => "package Prov::Declared;\nour \$VERSION = '5.5';\n1;\n",
  );

  my $modules = index_tarball( $tarball, $tmp );

  is_deeply stringify_versions( $modules ),
    { 'Prov::Declared' => '5.5' },
    'META provides block is authoritative and short-circuits the file walk';
}

# --- _is_indexable guard branches: DB / leading-underscore / exact-namespace -
#
# NO_INDEX_META above covers _is_indexable's no_index package and child-namespace
# (Foo::Internal::*) branches. This covers the remaining three guards. Each
# skipped package shares its file with a sibling that MUST stay indexable, so the
# assertion fails loudly if a guard is dropped: removing a guard makes the
# skipped package the file's first indexable one, so it - not the sibling - lands
# in the map. The namespace fixture names a package EXACTLY equal to a no_index
# namespace, which the child-prefix check (index($pkg,"$ns\::")==0) alone would
# let through - only the `$pkg eq $ns` clause excludes it.

GUARD_SKIPS: {
  my $meta = <<'END_META';
---
name: Guard-1.0
version: 1.0
no_index:
  namespace:
    - Guard::Exact
END_META

  my $tarball = build_tarball(
    $tmp, 'Guard-1.0',
    'META.yml'      => $meta,
    'lib/Guard.pm'  => "package Guard;\nour \$VERSION = '1.0';\n1;\n",
    # 'DB' is skipped -> Guard::Db (declared after it) is what gets indexed.
    'lib/Guard/Db.pm' =>
      "package DB;\nour \$VERSION = '5';\npackage Guard::Db;\nour \$VERSION = '1.1';\n1;\n",
    # a '_'-prefixed segment is skipped -> Guard::Real wins.
    'lib/Guard/Hidden.pm' =>
      "package Guard::_Hidden;\nour \$VERSION = '6';\npackage Guard::Real;\nour \$VERSION = '6.6';\n1;\n",
    # package name == no_index namespace is skipped -> Guard::ExactReal wins.
    'lib/Guard/Exact.pm' =>
      "package Guard::Exact;\nour \$VERSION = '7';\npackage Guard::ExactReal;\nour \$VERSION = '7.7';\n1;\n",
  );

  my $modules = index_tarball( $tarball, $tmp );

  is_deeply stringify_versions( $modules ),
    {
      'Guard'           => '1.0',
      'Guard::Db'       => '1.1',
      'Guard::Real'     => '6.6',
      'Guard::ExactReal'=> '7.7',
    },
    'DB / leading-underscore / exact-namespace packages skipped; siblings indexed';
}

done_testing;
