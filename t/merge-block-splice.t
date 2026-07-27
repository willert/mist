#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

# `mist merge` splices a marker-delimited block for the merged dist into the
# consumer's mistfile. _splice_merge_block is the pure step: it renders the block
# and either replaces the dist's existing top-level block or appends a new one.
#
# The invariant under test is that it binds only to *top-level* markers. A
# consumer can carry subordinate ### <<<[D] markers - copies of D's block nested
# inside siblings that merge D themselves - and an unanchored first-match scan
# writes the top-level result into one of those instead. The next `mist merge S`
# then regenerates S's whole subtree from S's own mistfile and drops it, both
# commands exiting 0. See docs/bug-merge-block-placement.md.
eval { require App::Mist::Command::merge; 1 }
  or plan skip_all => "cannot load App::Mist::Command::merge: $@";

sub splice_block {
  my ( $mistfile, %p ) = @_;
  return App::Mist::Command::merge::_splice_merge_block(
    $mistfile,
    $p{dist} || 'WeCARE::Env',
    $p{path} || 'Devel/wecare-env',
    $p{spec} || "prepend 'Term::Table' => '0.023';\n",
  );
}

sub count_markers {
  my ( $text, $dist, $indent ) = @_;
  $indent = '' unless defined $indent;
  my @open = $text =~ m/^\Q${indent}\E### <<<\[\Q${dist}\E\]/mg;
  return scalar @open;
}

# A sibling's block as `mist merge` writes it: markers at column 0, body indented
# two spaces, and - because embedding a mistfile indents every line - a nested
# copy of WeCARE::Env's own block sitting two spaces deeper.
my $sibling_block = <<'SIBLING';
### <<<[WeCARE::Env::PSGI] - keep this line intact
merge 'WeCARE::Env::PSGI' => sub {
  # generated code block - do not edit
  dist_path 'Devel/wecare-env-psgi';

  ### <<<[WeCARE::Env] - keep this line intact
  merge 'WeCARE::Env' => sub {
    # generated code block - do not edit
    dist_path 'Devel/wecare-env';

  };
  ### [WeCARE::Env]>>> - keep this line intact
};
### [WeCARE::Env::PSGI]>>> - keep this line intact
SIBLING

APPEND_TO_EMPTY_MISTFILE: {
  my $out = splice_block( '' );

  is count_markers( $out, 'WeCARE::Env' ), 1,
    'a mistfile with no block for the dist gains exactly one';
  like $out, qr/^merge 'WeCARE::Env' => sub \{$/m,
    'the generated merge verb sits at column 0';
  like $out, qr/^  dist_path 'Devel\/wecare-env';$/m,
    'the block body is indented one level';
  like $out, qr/^  prepend 'Term::Table' => '0\.023';$/m,
    "the merged dist's own directives are carried into the block";
}

REPLACE_TOP_LEVEL_BLOCK_IN_PLACE: {
  my $before = "perl '5.20.3';\n\n" . splice_block( '' ) . "\nprepend 'Later';\n";
  my $out = splice_block( $before, spec => "prepend 'Test::Simple' => '1.302212';\n" );

  is count_markers( $out, 'WeCARE::Env' ), 1,
    're-merging replaces the existing top-level block rather than adding one';
  like $out, qr/prepend 'Test::Simple'/,
    'the replacement carries the new directives';
  unlike $out, qr/prepend 'Term::Table'/,
    'and drops the superseded ones';
  like $out, qr/^perl '5\.20\.3';$/m, 'content before the block survives';
  like $out, qr/^prepend 'Later';$/m, 'content after the block survives';
}

# The regression. Nothing here is top-level for WeCARE::Env, so the merge must
# create a new top-level block and leave the subordinate pair byte-identical.
SUBORDINATE_MARKER_IS_NOT_A_MERGE_TARGET: {
  my $before = "perl '5.20.3';\n\n" . $sibling_block;
  my $out = splice_block( $before );

  is count_markers( $out, 'WeCARE::Env' ), 1,
    'a top-level block is created when only subordinate markers exist';
  is count_markers( $out, 'WeCARE::Env', '  ' ), 1,
    'the subordinate marker is still there';
  like $out, qr/\Q$sibling_block\E/,
    "the sibling's block is untouched, so a later merge of it drops nothing";
  like $out, qr/^  prepend 'Term::Table' => '0\.023';$/m,
    'the merged directives land in the new top-level block';

  # The de-indentation tell from the bug report: top-level block content written
  # at a subordinate marker leaves its closing brace and end marker at column 0
  # inside an indented context.
  unlike $out, qr/^  ### <<<\[WeCARE::Env\][^\n]*\nmerge /m,
    'no column-0 block body hanging off an indented marker';
}

PREFERS_TOP_LEVEL_BLOCK_OVER_EARLIER_SUBORDINATE_ONE: {
  my $before = $sibling_block . "\n" . splice_block( '' );
  my $out = splice_block( $before, spec => "prepend 'Test::Simple' => '1.302212';\n" );

  is count_markers( $out, 'WeCARE::Env' ), 1,
    'the top-level block is replaced, not duplicated';
  is count_markers( $out, 'WeCARE::Env', '  ' ), 1,
    'the subordinate marker is left alone even though it comes first in the file';
  like $out, qr/\Q$sibling_block\E/,
    "the sibling's block is untouched, so nothing leaked into the subordinate one";
}

# Guards the substitution's tail: consuming the end-marker line but not its
# newline (or consuming one too many) shows up as drift across repeat merges.
REPEATED_MERGE_IS_IDEMPOTENT: {
  my $once = splice_block( "perl '5.20.3';\n\n" . $sibling_block );
  my $twice = splice_block( $once );

  is $twice, $once, 'merging an unchanged dist twice leaves the mistfile alone';
}

done_testing;
