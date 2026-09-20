package Mist::TranslatedChanges;

# Changelogs kept in translation beside Changes, named Changes.<locale>.
#
# Their topmost block sits under a {{$HEAD}} marker instead of a version line.
# The marker is positional: it means "this block translates whatever Changes
# lists first", so a translation can be written in the same commit as the
# English entry, before the release has assigned a number. At release the marker
# is replaced by the version line just stamped into Changes and a fresh marker
# is opened above it - the same shape Minilla::Release::RewriteChanges leaves
# behind for {{$NEXT}}, so both files end a release looking alike.
#
# Core-only on purpose: this is read by the release pre-flight, by a release
# step and by the dist work dir, and its tests run without the project env.

use strict;
use warnings;
use base 'Exporter';

our @EXPORT_OK;
BEGIN { @EXPORT_OK = qw/
  translated_changelogs
  head_block_state
  released_version_line
  stamp_head_block
  consume_head_marker
  drop_spent_head_marker
  changelog_marker_faults
/ }

use Carp;
use File::Spec;

# Locale-shaped suffixes only. A bare Changes.* would also match a Changes.bak
# or Changes.old somebody left lying around, and the release would then edit a
# backup file.
my $LOCALE = qr/ [a-z]{2} (?: _[A-Z]{2} )? /x;

my $HEAD_LINE = qr/ ^ \{\{\$HEAD\}\} \h* $ /mx;
my $NEXT_LINE = qr/ ^ \{\{\$NEXT\}\} \h* $ /mx;

# A marker followed by an indented non-blank line, i.e. an entry beneath it.
# Deliberately the same shape App::Mist::Command::release applies to {{$NEXT}},
# so the two gates agree on what counts as "has an entry".
my $HEAD_WITH_ENTRY = qr/ ^ \{\{\$HEAD\}\} \h* \R+ \h+ \S /mx;

sub _slurp {
  my ( $file ) = @_;
  open my $fh, '<:raw', $file or croak "Can't open ${file}: $!";
  local $/;
  return <$fh>;
}

sub _spew {
  my ( $file, $content ) = @_;
  open my $fh, '>:raw', $file or croak "Can't write ${file}: $!";
  print {$fh} $content;
  close $fh or croak "Can't close ${file}: $!";
  return;
}

sub translated_changelogs {
  my ( $dir ) = @_;
  $dir = '.' unless defined $dir;

  opendir my $dh, $dir or croak "Can't read ${dir}: $!";
  my @found = sort grep { /\A Changes\.${LOCALE} \z/x } readdir $dh;
  closedir $dh;

  return @found;
}

# 'none'   no marker: this file is not tracking releases, which is the opt-out
# 'empty'  marker present with nothing under it: a translation is owed
# 'filled' marker present with a block under it: ready to be stamped
sub head_block_state {
  my ( $file ) = @_;
  my $content = _slurp( $file );

  return 'none' unless $content =~ $HEAD_LINE;
  return $content =~ $HEAD_WITH_ENTRY ? 'filled' : 'empty';
}

# The version line the release just stamped into Changes, read back rather than
# recomputed: taking the timestamp from each file separately lets the two drift,
# and the version line is the key the files are joined on.
sub released_version_line {
  my ( $changes ) = @_;
  $changes = 'Changes' unless defined $changes;
  return undef unless -f $changes;

  my @lines = split /\R/, _slurp( $changes ), -1;

  my $i = 0;
  $i++ while $i < @lines and $lines[ $i ] !~ /\A\{\{\$NEXT\}\}\h*\z/;
  return undef if $i >= @lines;

  $i++;
  $i++ while $i < @lines and $lines[ $i ] =~ /\A\h*\z/;
  return undef if $i >= @lines;

  # Entries are indented, version lines are not; an indented line here means
  # {{$NEXT}} still holds pending entries and nothing has been stamped yet.
  my $line = $lines[ $i ];
  return undef unless $line =~ /\A\S/;

  $line =~ s/\h+\z//;
  return $line;
}

# Release: file the block under its version line and open a fresh marker above
# it, so the next entry has somewhere to go.
sub stamp_head_block {
  my ( $file, $version_line ) = @_;
  croak "stamp_head_block needs a version line" unless defined $version_line;

  my $content = _slurp( $file );
  $content =~ s/$HEAD_LINE/{{\$HEAD}}\n\n${version_line}/
    or return 0;

  _spew( $file, $content );
  return 1;
}

# Dist copy of a snapshot build: the marker is consumed outright, matching what
# stock Minilla::WorkDir does to {{$NEXT}} there. Never used on the source tree.
sub consume_head_marker {
  my ( $file, $version_line ) = @_;
  croak "consume_head_marker needs a version line" unless defined $version_line;

  my $content = _slurp( $file );
  $content =~ s/$HEAD_LINE/${version_line}/
    or return 0;

  _spew( $file, $content );
  return 1;
}

# Dist copy of a tagged release: the marker is spent, and shipping it beside a
# Changes whose {{$NEXT}} was stripped would leave the two files inconsistent.
# Only ever the dist copy - in the source tree an empty marker is load-bearing,
# it is where the next translation goes.
sub drop_spent_head_marker {
  my ( $file ) = @_;
  return 0 unless head_block_state( $file ) eq 'empty';

  my $content = _slurp( $file );
  $content =~ s/$HEAD_LINE\R*//;
  _spew( $file, $content );
  return 1;
}

# Structural faults that must never be guessed past: each one is otherwise
# silent, and each makes the release file the wrong block or none at all.
# Returns human-readable strings for the caller to format; empty means clean.
sub changelog_marker_faults {
  my ( $dir ) = @_;
  $dir = '.' unless defined $dir;

  my @faults;

  my $changes = File::Spec->catfile( $dir, 'Changes' );
  if ( -f $changes and _slurp( $changes ) =~ $HEAD_LINE ) {
    push @faults, "Changes contains a {{\$HEAD}} marker.\n"
      . "{{\$HEAD}} belongs only in a translated changelog; Changes uses\n"
      . "{{\$NEXT}}.\n";
  }

  for my $name ( translated_changelogs( $dir ) ) {
    my $content = _slurp( File::Spec->catfile( $dir, $name ) );

    my $markers = () = $content =~ /$HEAD_LINE/g;
    push @faults, "${name} has ${markers} {{\$HEAD}} markers, expected one.\n"
      . "The marker refers to exactly one block, the topmost.\n"
      if $markers > 1;

    push @faults, "${name} contains a {{\$NEXT}} marker.\n"
      . "A translated changelog uses {{\$HEAD}}; {{\$NEXT}} is rewritten in\n"
      . "Changes only, so a copy here would never be given a version.\n"
      if $content =~ $NEXT_LINE;
  }

  return @faults;
}

1;
