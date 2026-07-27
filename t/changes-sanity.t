#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use File::Spec;

# Changes is hand-edited around a {{$NEXT}} placeholder that Minilla's
# RewriteChanges turns into a version heading at release time. That makes it easy
# to damage silently: an edit adding bullets under {{$NEXT}} once used the
# heading below as its trailing anchor and dropped it, so the previous release's
# entries were adopted by the next heading RewriteChanges inserted and a released
# version vanished from the changelog. The file still looked well formed, and the
# release gate only checks that {{$NEXT}} has an entry under it.

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
my $changes = File::Spec->catfile( $repo, 'Changes' );

plan skip_all => 'no Changes here' unless -f $changes;

# Every assertion here is about the *repository's* changelog, so this only runs
# in a checkout. In a dist build Minilla::WorkDir::_rewrite_changes has already
# substituted {{$NEXT}} for the version being built, and there is no .git for the
# tag cross-check - so the file the tarball ships legitimately violates the
# invariants below, and asserting them there fails the release at DistTest.
plan skip_all => 'not a git checkout (a dist/clean-room build)'
  unless -e File::Spec->catdir( $repo, '.git' );

my @lines = do {
  open my $fh, '<', $changes or die "open Changes: $!";
  <$fh>;
};

# A heading is a version and its release timestamp at column 0.
my @headings;
my @malformed;
my $next_at;
for my $i ( 0 .. $#lines ) {
  my $line = $lines[$i];
  chomp( my $text = $line );

  $next_at = $i if $text eq '{{$NEXT}}' and not defined $next_at;

  next unless $text =~ /^\d/;    # only column-0 version-ish lines
  if ( $text =~ /^(\d+)\.(\d+) \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/ ) {
    push @headings, { major => $1, minor => $2, version => "$1.$2", line => $i + 1 };
  }
  else {
    push @malformed, sprintf 'line %d: %s', $i + 1, $text;
  }
}

WELL_FORMED: {
  is_deeply \@malformed, [],
    'every column-0 version line is "<version> <ISO timestamp>"';
  ok scalar @headings, 'the changelog has version headings at all';

  # Compared as a string, never a pattern: $NEXT would interpolate in a regex,
  # and \Q...\E suppresses metacharacters, not interpolation.
  my $placeholders = grep { my $l = $_; chomp $l; $l eq '{{$NEXT}}' } @lines;
  is $placeholders, 1, 'exactly one {{$NEXT}} placeholder';
  ok defined $next_at && $next_at < $headings[0]{line},
    '{{$NEXT}} sits above the newest version heading';
}

# Strictly descending, and no version listed twice. Deliberately not asserting a
# gapless sequence: retracting a release legitimately skips a number, and a test
# that cried wolf there would be worse than no test.
ORDERED_AND_UNIQUE: {
  my %seen;
  my @duplicated = grep { $seen{ $_->{version} }++ } @headings;
  is_deeply [ map { $_->{version} } @duplicated ], [],
    'no version appears twice';

  my @out_of_order;
  for my $i ( 1 .. $#headings ) {
    my ( $above, $below ) = @headings[ $i - 1, $i ];
    my $descends = $above->{major} <=> $below->{major}
                || $above->{minor} <=> $below->{minor};
    push @out_of_order, "$below->{version} (line $below->{line}) follows $above->{version}"
      unless $descends > 0;
  }
  is_deeply \@out_of_order, [], 'versions descend down the file';
}

# The assertion that maps onto the actual bug: a version that was released must
# still have somewhere to hang its entries.
SUBTEST_EVERY_TAG_HAS_A_SECTION: {
  my @tags = do {
    open my $fh, '-|', 'git', '-C', $repo, 'tag', '--list'
      or die "git tag: $!";
    grep { /^\d+\.\d+$/ } map { chomp; $_ } <$fh>;
  };

  unless ( @tags ) {
    note 'no version tags found, skipping the tag cross-check';
    last SUBTEST_EVERY_TAG_HAS_A_SECTION;
  }

  my %documented = map { $_->{version} => 1 } @headings;
  my @undocumented = sort grep { not $documented{$_} } @tags;

  is_deeply \@undocumented, [],
    'every released tag has a section in Changes'
      or diag "released but absent from Changes: @undocumented";
}

done_testing;
