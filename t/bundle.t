#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Temp qw/ tempdir /;
use Path::Class qw/ dir /;

# Mist::Bundle is the on-disk format for a dependency erratum: a .bundle file of
# floor specs (cat-able into cpanm) plus an optional .meta sidecar. Run under the
# project env (./mist-run prove) - it needs the vendored Moo stack.
eval { require Mist::Bundle; 1 }
  or plan skip_all => "cannot load Mist::Bundle: $@";

my $tmp = dir( tempdir( 'mist-bundle-XXXXXX', TMPDIR => 1, CLEANUP => 1 ) );

SPEC_FOR_BUILDS_A_FLOOR_TOKEN: {
  is( Mist::Bundle->spec_for( 'Foo::Bar', '2.0' ), 'Foo::Bar~2.0',
    'spec_for joins module and version with a tilde (a >= floor)' );

  ok !eval { Mist::Bundle->spec_for( 'Foo::Bar', '>= 2.0' ); 1 },
    'spec_for rejects a version with whitespace (would break $(cat) word-split)';
}

EPHEMERAL_ROUNDTRIP_HAS_NO_META: {
  my $id = 'd1f2a3b4-0000-1111-2222-333344445555';
  my @specs = qw/ HTTP::Tiny~0.090 IO::Socket::SSL~2.085 /;

  Mist::Bundle->new({ specs => \@specs })->save( $tmp, $id );

  ok  -e $tmp->file( "$id.bundle" ), 'ephemeral save writes the .bundle';
  ok !-e $tmp->file( "$id.meta" ),   'ephemeral save writes no .meta';

  my $got = Mist::Bundle->load( $tmp, $id );
  is_deeply $got->specs, \@specs, 'specs round-trip in order';
  is_deeply $got->meta,  {},      'no metadata on an ephemeral bundle';
}

BUNDLE_FILE_IS_PURE_AND_CAT_ABLE: {
  my $id = 'cat-able';
  Mist::Bundle->new({ specs => [qw/ A~1 B~2 /] })->save( $tmp, $id );

  my @raw = $tmp->file( "$id.bundle" )->slurp;
  chomp @raw;
  ok !( grep { /\A#/ } @raw ), 'no comment lines in the .bundle (cpanm would choke)';
  ok !( grep { /\s/ } grep { length } @raw ),
    'every spec line is one whitespace-free token';
}

PUBLISHED_ROUNDTRIP_CARRIES_META: {
  my $id = 'cve-2026-1234';
  my @specs = qw/ HTTP::Tiny~0.090 Net::SSLeay~1.94 /;
  my %meta  = (
    name        => 'cve-2026-1234',
    description => 'bump HTTP stack for CVE-2026-1234',
    published   => '2026-06-20T12:00:00Z',
  );

  Mist::Bundle->new({ specs => \@specs, meta => \%meta })->save( $tmp, $id );

  ok -e $tmp->file( "$id.meta" ), 'a bundle with metadata writes a .meta sidecar';

  my $got = Mist::Bundle->load( $tmp, $id );
  is_deeply $got->specs, \@specs, 'published specs round-trip';
  is_deeply $got->meta,  \%meta,  'published metadata round-trips';

  my @meta_lines = $tmp->file( "$id.meta" )->slurp;
  chomp @meta_lines;
  is $meta_lines[0], "name: cve-2026-1234",
    'name leads the .meta for clean diffs';
  is $meta_lines[1], "description: bump HTTP stack for CVE-2026-1234",
    'description follows name';
}

LOAD_SKIPS_BLANKS_AND_COMMENTS: {
  my $id = 'with-noise';
  my $f  = $tmp->file( "$id.bundle" );
  my $fh = $f->openw;
  print {$fh} "# a hand-added note\n\n  Foo::Bar~1.2  \n\nBaz::Qux~3.4\n";
  $fh->close;

  my $got = Mist::Bundle->load( $tmp, $id );
  is_deeply $got->specs, [qw/ Foo::Bar~1.2 Baz::Qux~3.4 /],
    'load trims, drops blanks and # comments';
}

ID_IS_GUARDED_AGAINST_TRAVERSAL: {
  ok !eval { Mist::Bundle->spec_file( $tmp, '../escape' ); 1 },
    'a .. in the id is rejected';
  ok !eval { Mist::Bundle->spec_file( $tmp, 'a/b' ); 1 },
    'a slash in the id is rejected';
  ok !eval { Mist::Bundle->spec_file( $tmp, '.hidden' ); 1 },
    'a leading dot in the id is rejected';
}

NEW_ID_IS_A_VALID_UUID_SHAPED_STEM: {
  my $id = Mist::Bundle->new_id;
  like $id, qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
    'new_id is UUID-shaped';
  ok eval { Mist::Bundle->spec_file( $tmp, $id ); 1 },
    'a generated id passes the traversal guard (usable as a filename stem)';
  isnt( Mist::Bundle->new_id, $id, 'successive ids differ' );
}

done_testing;
