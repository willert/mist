#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

use File::Temp qw/ tempdir /;
use Path::Class qw/ dir /;

# `mist merge` splices a marker-delimited block for the merged dist into the
# consumer's mistfile. _splice_merge_block is the pure step: it renders the block
# and either replaces the dist's existing top-level block or appends a new one.
#
# The invariant under test is that it binds only to *top-level* markers. A
# consumer can carry subordinate ### <<<[D] markers - copies of D's block nested
# inside siblings that merge D themselves - and an unanchored first-match scan
# writes the top-level result into one of those instead. The next `mist merge S`
# then regenerates S's whole subtree from S's own mistfile and drops it, both
# commands exiting 0.
eval { require App::Mist::Command::merge; 1 }
  or plan skip_all => "cannot load App::Mist::Command::merge: $@";

sub splice_block {
  my ( $mistfile, %p ) = @_;
  return App::Mist::Command::merge::_splice_merge_block(
    $mistfile,
    $p{dist} || 'WeCARE::Env',
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
# copy of WeCARE::Env's own block sitting two spaces deeper. The retired
# `dist_path` lines are deliberate: this is the legacy shape still committed in
# downstream mistfiles, and the splice has to handle it unchanged.
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
  like $out, qr/^  # generated code block - do not edit$/m,
    'the block body is indented one level';
  like $out, qr/^  prepend 'Term::Table' => '0\.023';$/m,
    "the merged dist's own directives are carried into the block";
  unlike $out, qr/dist_path/,
    'the retired dist_path directive is no longer emitted';
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

# --- write-path guards ------------------------------------------------------

# The splice builds its output from its input, so it cannot lose content on its
# own - it loses content when it is handed the wrong arguments. Path::Class'
# slurp returns a list of lines in list context, so a slurp inlined into the
# call arguments shifts the mistfile into $mistfile=line 1, $distname=line 2,
# $spec=line 3 and drops the rest as surplus args. That silently rewrote a
# 268-line mistfile down to its first three lines. These guards make the whole
# class loud instead.
sub splice_dies {
  my @args = @_;
  local $@;
  eval { App::Mist::Command::merge::_splice_merge_block( @args ); 1 };
  return "$@";
}

FIXED_ARITY: {
  my $mistfile = "perl '5.20.3';\n\nnotest 'Sub::Name';\n\nassert { 1 };\n";

  like splice_dies( split /^/, $mistfile ),
    qr/takes 3 arguments, got 5/,
    'a list-context slurp in the argument list dies on arity';
  like splice_dies( $mistfile, 'WeCARE::Env' ),
    qr/takes 3 arguments, got 2/, 'too few arguments dies too';

  # The exact shape of the regression: line 2 of a mistfile is blank, so it
  # arrived as the dist name.
  like splice_dies( "perl '5.20.3';\n", "\n", "notest 'Sub::Name';\n" ),
    qr/blank dist name/, 'and a blank dist name is refused on its own';
}

BLANK_OR_MULTILINE_DIST_NAME: {
  like splice_dies( '', '', 'spec' ), qr/blank dist name/, 'empty name refused';
  like splice_dies( '', '   ', 'spec' ), qr/blank dist name/, 'whitespace name refused';
  like splice_dies( '', undef, 'spec' ), qr/blank dist name/, 'undef name refused';
  like splice_dies( '', "Foo\nBar", 'spec' ), qr/multi-line dist name/,
    'a name spanning lines is refused';
}

# Independent of how the inputs went wrong: if a rewrite would drop a top-level
# block that is not the one being merged, refuse to hand it back.
REFUSES_TO_DROP_TOP_LEVEL_BLOCKS: {
  my $before = splice_block( '', dist => 'Other::Dist' )
             . "\n" . splice_block( '' );

  is count_markers( $before, 'Other::Dist' ), 1, 'fixture has the sibling block';

  # Splicing WeCARE::Env against the full file keeps Other::Dist, as it must.
  my $ok = splice_block( $before, spec => "prepend 'X';\n" );
  is count_markers( $ok, 'Other::Dist' ), 1, 'a normal rewrite keeps it';

  # Hand the guard the regression's actual outcome - a mistfile rewritten down to
  # its first line - with Other::Dist as the merge target, so the block it must
  # not have lost is WeCARE::Env.
  my $err = do {
    local $@;
    eval {
      App::Mist::Command::merge::_assert_only_target_block_changed(
        $before, "perl '5.20.3';\n", 'Other::Dist' );
      1;
    };
    "$@";
  };
  like $err, qr/would drop top-level merge block\(s\).*WeCARE::Env/,
    'a rewrite that drops a foreign top-level block is refused';
}

WRITE_KEEPS_A_BACKUP: {
  my $dir  = dir( tempdir( 'mist-mistwrite-XXXXXX', TMPDIR => 1, CLEANUP => 1 ));
  my $file = $dir->file( 'mistfile' );
  $file->spew( iomode => '>:utf8', "perl '5.20.3';\n# umlaut: \x{e4}\n" );

  # The backup goes to the per-project workspace, not next to the mistfile: a
  # project root is version-controlled, and an untracked mistfile.bak there would
  # fail the CheckUntrackedFiles step of that project's own mist release.
  my $workspace = dir( tempdir( 'mist-mistws-XXXXXX', TMPDIR => 1, CLEANUP => 1 ));
  my $backup    = $workspace->file( 'mistfile.bak' );

  App::Mist::Command::merge::_write_mistfile( $file, $backup, "rewritten\n" );

  is $file->slurp( iomode => '<:utf8' ), "rewritten\n", 'the new content lands';
  is $backup->slurp( iomode => '<:utf8' ),
    "perl '5.20.3';\n# umlaut: \x{e4}\n",
    'the previous content is kept in the workspace backup, decoded intact';
  ok ! -e $dir->file( 'mistfile.bak' )->stringify,
    'nothing is left in the project root beside the mistfile';
  ok ! -e $dir->file( 'mistfile.tmp' )->stringify,
    'no temp file is left behind';
  is_deeply [ sort map { $_->basename } $dir->children ], [ 'mistfile' ],
    'the project root holds only the mistfile afterwards';

  # Round trip a non-ASCII rewrite: spew's hashref-iomode form silently writes
  # bytes, which would mangle what the matching '<:utf8' slurp decoded.
  App::Mist::Command::merge::_write_mistfile( $file, $backup, "# \x{2014} \x{e4}\n" );
  is $file->slurp( iomode => '<:utf8' ), "# \x{2014} \x{e4}\n",
    'wide characters survive the write/read round trip';
}

done_testing;
