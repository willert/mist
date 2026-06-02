#!/usr/bin/env perl

# Unit tests for Mist::Role::CPAN::PackageIndex, focusing on the two
# pure-ish ordering/diff helpers that don't require parsing real dists:
#
#   _dist_tarballs_lowest_version_first - collects every tarball under
#     authors/id (+ vendor) and orders by dist ASC, NUMERIC version ASC,
#     path ASC. The numeric version sort is the crux: 1.2 < 1.9 < 1.10,
#     which a naive string sort would get wrong (it would rank "1.10"
#     before "1.2").
#
#   _unreferenced_tarballs - the set-diff of on-disk tarballs against the
#     paths actually referenced from a freshly-built index, returned as
#     authors/id-relative paths.
#
# Both helpers only ever look at file *paths*, never tarball contents, so
# the fixture tarballs can be empty - we just need real files on disk
# with the right CPAN-shaped names. Everything is built under File::Temp;
# no shared fixtures, no network.

use strict;
use warnings;

use Test::More;

use File::Temp ();
use File::Spec ();
use Path::Class ();
use Archive::Tar ();
use Archive::Tar::Constant qw/ COMPRESS_GZIP /;

use CPAN::PackageDetails;
use CPAN::DistnameInfo;
use Mist::CPAN::PackageIndex;

# --- build a throwaway mpan-dist-shaped tree -------------------------------

my $tmp = File::Temp->newdir( CLEANUP => 1 );
my $root = Path::Class::dir( "$tmp" );

# dist => [ author-path-segments..., [ versions ] ]
my %fixture = (
  Foo => { author => [qw/ F FO FOO /], versions => [qw/ 1.10 1.2 1.9 /] },
  Bar => { author => [qw/ B BA BAR /], versions => [qw/ 0.9 0.10 /]      },
);

# Map "Dist-Version" => absolute Path::Class::File of its tarball, so the
# expectations below can be expressed by name rather than by path string.
my %tarball;

for my $dist ( sort keys %fixture ) {
  my $spec    = $fixture{ $dist };
  my $dist_dir = $root->subdir( qw/ authors id /, @{ $spec->{author} } );
  $dist_dir->mkpath;

  for my $version ( @{ $spec->{versions} } ) {
    my $name = "${dist}-${version}.tar.gz";
    my $file = $dist_dir->file( $name );

    # Real on-disk gzip'd tarball; contents are irrelevant to the helpers
    # under test, but we make it a valid archive rather than a stub so the
    # fixture stays honest.
    my $tar = Archive::Tar->new;
    $tar->add_data( "$dist/lib/${dist}.pm", "package $dist; 1;\n" );
    $tar->write( "$file", COMPRESS_GZIP );

    $tarball{ "${dist}-${version}" } = $file;
  }
}

my $on_disk_count = keys %tarball;
is $on_disk_count, 5, 'built 5 fixture tarballs on disk';

# Helper-under-test consumer. Mist::CPAN::PackageIndex is the real Moo
# class that 'with's the role; it only requires cpan_dist_root, which must
# be a Path::Class::Dir (the role calls ->subdir on it).
my $idx = Mist::CPAN::PackageIndex->new( cpan_dist_root => $root );

# --- _dist_tarballs_lowest_version_first -----------------------------------

# Intended order: dist ASC, then version ASC in the dotted/PAUSE sense
# where 1.10 is a later point release than 1.9 (1.2 < 1.9 < 1.10). Both dists
# carry a pair a lexical sort would invert - Bar 0.9 < 0.10 and Foo 1.9 < 1.10 -
# so the assertion fails if the numeric compare regresses to string order. This
# is the ordering the role's own comment relies on ("lowest first, highest last,
# so highest-version-wins attributes each package to the newest tarball").
my @expected_order = (
  $tarball{ 'Bar-0.9'  },
  $tarball{ 'Bar-0.10' },
  $tarball{ 'Foo-1.2'  },
  $tarball{ 'Foo-1.9'  },
  $tarball{ 'Foo-1.10' },
);

my @got = $idx->_dist_tarballs_lowest_version_first;

is scalar(@got), scalar(@expected_order),
  '_dist_tarballs_lowest_version_first returns every tarball';

my @got_versions =
  map  { ( CPAN::DistnameInfo->new( "$_" )->version ) }
  grep { CPAN::DistnameInfo->new( "$_" )->dist eq 'Foo' }
  @got;

# Ordered by dist ASC, then version ASC by NUMERIC components so a multi-digit
# point release sorts newest (1.2 < 1.9 < 1.10), then path ASC. A bare
# version->parse() would read "1.10" as the decimal 1.1 and rank it below 1.9,
# inverting the highest-version-wins dedup; the role uses _version_cmp (numeric
# dot/underscore components) precisely to avoid that.
is_deeply
  [ map { "$_" } @got ],
  [ map { "$_" } @expected_order ],
  'ordered by dist ASC, version ASC (1.2 < 1.9 < 1.10), path ASC';

is_deeply \@got_versions, [qw/ 1.2 1.9 1.10 /],
  'Foo tarballs visited lowest-version first; 1.10 is newest, visited last';

# --- _version_cmp: direct unit coverage ------------------------------------
#
# The ordering test above exercises _version_cmp only through plain dotted point
# releases. Pin its behaviour directly for the forms it explicitly handles -
# v-strings, underscore (TRIAL) components, long CPAN::Meta versions, absent and
# undef components - and lock in the documented tradeoffs of the per-component
# compare so a change to the dotted "1.10 > 1.9" semantics surfaces here.

{
  my $cmp = \&Mist::Role::CPAN::PackageIndex::_version_cmp;
  my $sgn = sub { ( shift ) <=> 0 };   # assert ordering, not raw magnitude

  # Point-release semantics - the whole reason the helper exists.
  is $sgn->( $cmp->( '1.2',  '1.10' ) ), -1, '1.2 < 1.10 (point release)';
  is $sgn->( $cmp->( '1.9',  '1.10' ) ), -1, '1.9 < 1.10 (multi-digit point release)';
  is $sgn->( $cmp->( '1.10', '1.10' ) ),  0, '1.10 == 1.10';

  # v-strings: leading 'v' stripped, then compared per dotted component.
  is $sgn->( $cmp->( 'v1.2.3', 'v1.2.10' ) ), -1, 'v1.2.3 < v1.2.10';
  is $sgn->( $cmp->( 'v1.2.3', '1.2.3'   ) ),  0, 'v-prefix ignored: v1.2.3 == 1.2.3';

  # Long CPAN::Meta-style version compares as a single numeric component.
  is $sgn->( $cmp->( '2.15', '2.150010' ) ), -1, '2.15 < 2.150010';

  # An absent trailing component counts as 0.
  is $sgn->( $cmp->( '1.2', '1.2.1' ) ), -1, '1.2 < 1.2.1 (absent component is 0)';

  # undef / empty normalise to 0.
  is $sgn->( $cmp->( undef, '0' ) ), 0, 'undef normalises to 0';
  is $sgn->( $cmp->( '',    '0' ) ), 0, 'empty string normalises to 0';

  # --- documented tradeoffs (see the comment above _version_parts) ----------
  # These assert the KNOWN limitation, not desired behaviour: comparing each
  # component numerically drops a fractional component's leading zeros. Pinned
  # so the cost stays visible and any change to it is a conscious one.
  is $sgn->( $cmp->( '0.05',    '0.5'  ) ), 0,
    'TRADEOFF: 0.05 == 0.5 (leading-zero fractional components collapse)';
  is $sgn->( $cmp->( '0.009',   '0.01' ) ), 1,
    'TRADEOFF: 0.009 > 0.01 (leading-zero fractional components invert)';
  is $sgn->( $cmp->( '1.23_01', '1.23' ) ), 1,
    'TRADEOFF: 1.23_01 > 1.23 (underscore TRIAL sorts above its stable base)';
}

# --- _unreferenced_tarballs ------------------------------------------------

# Build an index by hand so the "referenced" set is fully under our
# control and the diff is deterministic. We reference exactly four of the
# five tarballs (each package appears once, so there is no version-dedup
# ambiguity in as_unique_sorted_list), deliberately leaving Foo-1.9
# orphaned - it is on disk but no package entry points at it.
my $index = $idx->create_empty_package_index;

my %referenced_paths = (
  'Bar::A' => 'B/BA/BAR/Bar-0.9.tar.gz',
  'Bar::B' => 'B/BA/BAR/Bar-0.10.tar.gz',
  'Foo::A' => 'F/FO/FOO/Foo-1.2.tar.gz',
  'Foo::B' => 'F/FO/FOO/Foo-1.10.tar.gz',
);
while ( my ( $pkg, $path ) = each %referenced_paths ) {
  $index->add_entry(
    package_name => $pkg,
    version      => '1.0',
    path         => $path,
  );
}

# Collected paths = every tarball on disk, in the helper's own order.
my @collected = $idx->_dist_tarballs_lowest_version_first;

my @orphans = $idx->_unreferenced_tarballs( $index, \@collected );

is_deeply \@orphans, [ 'F/FO/FOO/Foo-1.9.tar.gz' ],
  '_unreferenced_tarballs returns exactly the orphaned tarball (set-diff)';

# Sanity: when every collected tarball is referenced, nothing is orphaned.
my $full_index = $idx->create_empty_package_index;
my $n = 0;
for my $file ( @collected ) {
  my $rel = Path::Class::file( "$file" )
    ->relative( $root->subdir(qw/ authors id /) );
  $full_index->add_entry(
    package_name => 'Pkg' . $n++,
    version      => '1.0',
    path         => "$rel",
  );
}
my @none = $idx->_unreferenced_tarballs( $full_index, \@collected );
is_deeply \@none, [],
  '_unreferenced_tarballs is empty when every tarball is referenced';

# --- vendor/ tarballs ------------------------------------------------------
#
# _dist_tarballs_lowest_version_first walks vendor/ in addition to authors/id/,
# and _unreferenced_tarballs expresses every path relative to authors/id - so a
# vendor tarball is addressed as ../../vendor/NAME. The fixture above only
# populates authors/id, leaving both branches untested; build a separate tree
# with one tarball in each location and confirm the vendor one is collected and,
# when unreferenced, reported in the ../../vendor form.

VENDOR: {
  my $vtmp  = File::Temp->newdir( CLEANUP => 1 );
  my $vroot = Path::Class::dir( "$vtmp" );

  my $aid  = $vroot->subdir(qw/ authors id A AU AUTH /);
  my $vdir = $vroot->subdir(qw/ vendor /);
  $_->mkpath for $aid, $vdir;

  for my $spec ( [ $aid, 'Auth-1.0' ], [ $vdir, 'Vend-2.0' ] ) {
    my ( $dir, $name ) = @$spec;
    my $tar = Archive::Tar->new;
    $tar->add_data( "$name/lib/Stub.pm", "package Stub; 1;\n" );
    $tar->write( $dir->file( "$name.tar.gz" )->stringify, COMPRESS_GZIP );
  }

  my $vidx = Mist::CPAN::PackageIndex->new( cpan_dist_root => $vroot );

  my %basename =
    map { Path::Class::file( "$_" )->basename => 1 }
    $vidx->_dist_tarballs_lowest_version_first;

  ok $basename{ 'Vend-2.0.tar.gz' },
    '_dist_tarballs_lowest_version_first collects tarballs under vendor/';
  ok $basename{ 'Auth-1.0.tar.gz' },
    '... alongside tarballs under authors/id/';

  # Reference only the authors/id tarball, so the vendor one is the lone orphan
  # and must come back as ../../vendor/Vend-2.0.tar.gz (authors/id-relative).
  my @collected = $vidx->_dist_tarballs_lowest_version_first;
  my $index     = $vidx->create_empty_package_index;
  $index->add_entry(
    package_name => 'Stub',
    version      => '1.0',
    path         => File::Spec->catfile(qw/ A AU AUTH Auth-1.0.tar.gz /),
  );

  my @orphans = $vidx->_unreferenced_tarballs( $index, \@collected );
  is_deeply \@orphans,
    [ File::Spec->catfile(qw/ .. .. vendor Vend-2.0.tar.gz /) ],
    'unreferenced vendor tarball is reported as ../../vendor/Vend-2.0.tar.gz';
}

done_testing;
