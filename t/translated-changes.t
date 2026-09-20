#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use Cwd ();
use File::Temp ();

use Mist::TranslatedChanges qw/
  translated_changelogs
  head_block_state
  released_version_line
  stamp_head_block
  consume_head_marker
  drop_spent_head_marker
  changelog_marker_faults
/;

sub spew {
  my ( $file, $content ) = @_;
  open my $fh, '>:raw', $file or die "open $file: $!";
  print {$fh} $content;
  close $fh;
}

sub slurp {
  my ( $file ) = @_;
  open my $fh, '<:raw', $file or die "open $file: $!";
  local $/;
  return <$fh>;
}

# Each block runs in its own temp dir with the real filenames, because the glob
# and the gates are all about what sits next to Changes.
my $cwd = Cwd::getcwd();
my @keep;

sub in_tempdir {
  my ( $code ) = @_;
  my $dir = File::Temp->newdir( CLEANUP => 1 );
  push @keep, $dir;
  chdir $dir->dirname or die "chdir: $!";
  $code->();
  chdir $cwd or die "chdir back: $!";
}

my $PENDING = <<'CHANGES';
{{$NEXT}}

    - something pending

0.0900 2026-08-01T10:00:00Z

    - the previous release
CHANGES

my $STAMPED = <<'CHANGES';
{{$NEXT}}

0.1000 2026-09-20T00:28:33Z

    - something released

0.0900 2026-08-01T10:00:00Z

    - the previous release
CHANGES

my $TRANSLATION_FILLED = <<'TRANS';
{{$HEAD}}

    [Veroeffentlichen]
    - etwas veroeffentlicht

0.0900 2026-08-01T10:00:00Z

    - die vorige Veroeffentlichung
TRANS

my $TRANSLATION_EMPTY = <<'TRANS';
{{$HEAD}}

0.0900 2026-08-01T10:00:00Z

    - die vorige Veroeffentlichung
TRANS

# ---------------------------------------------------------------------------
# The glob is locale-shaped so a stray backup never becomes a release target.

in_tempdir( sub {
  spew( 'Changes',        $STAMPED );
  spew( 'Changes.de',     $TRANSLATION_EMPTY );
  spew( 'Changes.de_DE',  $TRANSLATION_EMPTY );
  spew( 'Changes.bak',    $TRANSLATION_EMPTY );
  spew( 'Changes.old',    $TRANSLATION_EMPTY );
  spew( 'Changes.DE',     $TRANSLATION_EMPTY );
  spew( 'Changes.deu',    $TRANSLATION_EMPTY );
  spew( 'Changes.de_de',  $TRANSLATION_EMPTY );

  is_deeply( [ translated_changelogs() ], [ 'Changes.de', 'Changes.de_DE' ],
    'only locale-shaped suffixes are picked up' );
} );

# ---------------------------------------------------------------------------
# Marker states.

in_tempdir( sub {
  spew( 'Changes.de_DE', $TRANSLATION_FILLED );
  is( head_block_state( 'Changes.de_DE' ), 'filled',
    'a block under the marker reads as filled' );

  spew( 'Changes.de_DE', $TRANSLATION_EMPTY );
  is( head_block_state( 'Changes.de_DE' ), 'empty',
    'a marker with the next version line under it reads as empty' );

  spew( 'Changes.de_DE', "0.0900 2026-08-01T10:00:00Z\n\n    - nur dies\n" );
  is( head_block_state( 'Changes.de_DE' ), 'none',
    'no marker at all is the opt-out, not a fault' );
} );

# ---------------------------------------------------------------------------
# The version line is read back from Changes, never recomputed.

in_tempdir( sub {
  spew( 'Changes', $STAMPED );
  is( released_version_line(), '0.1000 2026-09-20T00:28:33Z',
    'the line stamped under {{$NEXT}} is what gets mirrored' );

  spew( 'Changes', $PENDING );
  is( released_version_line(), undef,
    'nothing to mirror while {{$NEXT}} still holds pending entries' );

  unlink 'Changes';
  is( released_version_line(), undef, 'no Changes, nothing to mirror' );
} );

# ---------------------------------------------------------------------------
# The release stamp: file the block and open a fresh marker above it.

in_tempdir( sub {
  spew( 'Changes',       $STAMPED );
  spew( 'Changes.de_DE', $TRANSLATION_FILLED );

  ok( stamp_head_block( 'Changes.de_DE', released_version_line() ),
    'stamping reports that it filed a block' );

  is( slurp( 'Changes.de_DE' ), <<'EXPECTED', 'block filed, fresh marker opened' );
{{$HEAD}}

0.1000 2026-09-20T00:28:33Z

    [Veroeffentlichen]
    - etwas veroeffentlicht

0.0900 2026-08-01T10:00:00Z

    - die vorige Veroeffentlichung
EXPECTED

  is( head_block_state( 'Changes.de_DE' ), 'empty',
    'the freshly opened marker is empty and so gates the next release' );
} );

# ---------------------------------------------------------------------------
# Dist copy: the marker is consumed or dropped, never left as a template.

in_tempdir( sub {
  spew( 'Changes.de_DE', $TRANSLATION_FILLED );
  ok( consume_head_marker( 'Changes.de_DE', '0.1000 2026-09-20T00:28:33Z' ),
    'a snapshot build consumes the marker' );
  unlike( slurp( 'Changes.de_DE' ), qr/\{\{\$HEAD\}\}/,
    'no marker survives into a snapshot dist' );
  like( slurp( 'Changes.de_DE' ), qr/^0\.1000 /m,
    'the build-time version line takes its place' );

  spew( 'Changes.de_DE', $TRANSLATION_EMPTY );
  ok( drop_spent_head_marker( 'Changes.de_DE' ),
    'a spent marker is dropped from the dist copy' );
  is( slurp( 'Changes.de_DE' ), <<'EXPECTED', 'and nothing else moves' );
0.0900 2026-08-01T10:00:00Z

    - die vorige Veroeffentlichung
EXPECTED

  spew( 'Changes.de_DE', $TRANSLATION_FILLED );
  ok( !drop_spent_head_marker( 'Changes.de_DE' ),
    'a marker with a block under it is never dropped' );
  is( slurp( 'Changes.de_DE' ), $TRANSLATION_FILLED, 'the file is untouched' );
} );

# ---------------------------------------------------------------------------
# Structural faults. Each is silent if guessed past, so each must be refused.

in_tempdir( sub {
  spew( 'Changes',       $STAMPED );
  spew( 'Changes.de_DE', $TRANSLATION_FILLED );
  is_deeply( [ changelog_marker_faults() ], [], 'a healthy pair has no faults' );
} );

in_tempdir( sub {
  spew( 'Changes', "{{\$HEAD}}\n\n    - wrong file\n" );
  my @faults = changelog_marker_faults();
  is( scalar @faults, 1, '{{$HEAD}} in Changes is a fault' );
  like( $faults[0], qr/Changes contains a \{\{\$HEAD\}\} marker/, 'named as such' );
} );

in_tempdir( sub {
  spew( 'Changes', $STAMPED );
  spew( 'Changes.de_DE', "{{\$NEXT}}\n\n    - falscher Marker\n" );
  my @faults = changelog_marker_faults();
  is( scalar @faults, 1, '{{$NEXT}} in a translation is a fault' );
  like( $faults[0], qr/would never be given a version/,
    'and says why it could never work' );
} );

in_tempdir( sub {
  spew( 'Changes', $STAMPED );
  spew( 'Changes.de_DE',
    "{{\$HEAD}}\n\n    - eins\n\n{{\$HEAD}}\n\n    - zwei\n" );
  my @faults = changelog_marker_faults();
  is( scalar @faults, 1, 'two markers in one file is a fault' );
  like( $faults[0], qr/has 2 \{\{\$HEAD\}\} markers/, 'counted in the message' );
} );

done_testing();
