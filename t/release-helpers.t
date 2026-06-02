#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use File::Spec;
use File::Temp ();
use Cwd ();
use Config;

# Loading App::Mist::Command::release triggers App::Mist's BEGIN, which resolves
# the project perl5/ relative to $RealBin - absent in the clean-room dist work
# dir. Skip under RELEASE_TESTING (mist's own release dist-test); this runs
# normally via ./mist-run prove, and the pure helpers it covers need no install.
BEGIN {
  plan skip_all => 'needs the full mist install (perl5/); run via ./mist-run prove'
    if $ENV{RELEASE_TESTING};
}

use App::Mist::Command::release;

# ---------------------------------------------------------------------------
# _cleanroom_inc: pure string builder. Returns a 2-element list, arch-first,
# derived verbatim from its $dir argument and $Config{archname}. Never hardcode
# the archname - build expected values with the same File::Spec->catdir so
# path separators match on every platform / pinned perl.
# ---------------------------------------------------------------------------

my $dir = File::Spec->catdir( File::Spec->rootdir, qw/ tmp cleanroom_probe / );
my @inc = App::Mist::Command::release::_cleanroom_inc( $dir );

my $e0 = File::Spec->catdir( $dir, qw/ lib perl5 /, $Config{archname} );
my $e1 = File::Spec->catdir( $dir, qw/ lib perl5 / );

is scalar(@inc), 2, 'cleanroom_inc returns exactly two elements';
is $inc[0], $e0, 'cleanroom_inc arch dir first';
is $inc[1], $e1, 'cleanroom_inc plain lib/perl5 second';
is_deeply [ @inc ], [ $e0, $e1 ], 'cleanroom_inc full list value and order';

my $other_dir = File::Spec->catdir( File::Spec->rootdir, qw/ var other_probe / );
my @inc2 = App::Mist::Command::release::_cleanroom_inc( $other_dir );
is_deeply
  [ @inc2 ],
  [ File::Spec->catdir( $other_dir, qw/ lib perl5 /, $Config{archname} ),
    File::Spec->catdir( $other_dir, qw/ lib perl5 / ) ],
  'cleanroom_inc uses its $dir argument verbatim (distinct prefixes)';

# ---------------------------------------------------------------------------
# _args_request_dry_run: must agree with how Minilla::CLI::Release will parse
# the very same @$args. Minilla parses with Getopt::Long's default config
# (auto_abbrev on), so any unambiguous abbreviation of --dry-run counts; a bare
# string-equality check would miss those and let mist run the trailing `dist`
# (leaving a tarball) for what Minilla treated as a dry run. It must also leave
# @$args untouched, since the same arrayref is forwarded to Minilla verbatim.
# ---------------------------------------------------------------------------

{
  my $probe = \&App::Mist::Command::release::_args_request_dry_run;

  my @cases = (
    [ []                       => 0, 'no args' ],
    [ ['--dry-run']            => 1, 'full --dry-run' ],
    [ ['--dry']                => 1, 'abbreviation --dry' ],
    [ ['--dry-r']              => 1, 'abbreviation --dry-r' ],
    [ ['--no-dry-run']         => 0, 'negated --no-dry-run' ],
    [ ['--trial', '--dry-run'] => 1, '--dry-run alongside another option' ],
    [ ['--no-test']            => 0, 'unrelated option only' ],
    [ ['foo', '--dry']         => 1, 'positional arg before the abbreviation' ],
  );

  for my $case ( @cases ) {
    my ( $args, $want, $label ) = @$case;
    my @copy = @$args;
    is( ( $probe->( \@copy ) ? 1 : 0 ), $want, "dry-run probe: $label" );
    is_deeply( \@copy, $args, "dry-run probe leaves args untouched: $label" );
  }
}

# ---------------------------------------------------------------------------
# _changes_has_next_entry: reads ./Changes from CWD. with_changes chdirs into a
# fresh temp dir, optionally writes Changes, calls the sub, then ALWAYS restores
# cwd - including the no-file path. The newdir object is held in a lexical so it
# is not reaped while we are chdir'd inside it.
# ---------------------------------------------------------------------------

sub with_changes {
  my ($content) = @_;
  my $before = Cwd::getcwd();
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  my $r;
  {
    chdir $tmp or die "chdir $tmp: $!";
    if ( defined $content ) {
      open my $fh, '>', 'Changes' or die "open Changes: $!";
      print {$fh} $content;
      close $fh;
    }
    $r = App::Mist::Command::release::_changes_has_next_entry();
    chdir $before or die "chdir back $before: $!";
  }
  return $r;
}

# Marker written with \$NEXT so $NEXT is not interpolated.

ok  with_changes("{{\$NEXT}}\n  - foo\n"),
    'next marker + indented entry is TRUE';

ok !with_changes("{{\$NEXT}}\n\nNot indented line\n"),
    'next marker, blank, then NON-indented line is FALSE';

ok !with_changes("0.01 2020-01-01\n  - foo\n"),
    'no next marker is FALSE even with an indented entry';

is  with_changes(undef), 0,
    'no Changes file returns 0 (numeric, no die)';

ok  with_changes("{{\$NEXT}}\n\n  - foo\n"),
    '\\R+ permits a blank line before an INDENTED entry -> TRUE';

ok  with_changes("{{\$NEXT}}   \n  - foo\n"),
    '\\h* permits trailing whitespace after the marker -> TRUE';

ok !with_changes("{{\$NEXT}}\nNot indented\n"),
    'non-indented line right after marker (no blank) is FALSE';

ok !with_changes("{{\$NEXT}}\n"),
    'marker as final line with nothing after is FALSE';

ok !with_changes("   {{\$NEXT}}\n  - foo\n"),
    'indented (non-column-0) marker is FALSE (/m ^ anchors line start)';

ok !with_changes(""),
    'empty Changes file is FALSE';

ok  with_changes("{{\$NEXT}}\n\t- foo\n"),
    'TAB-indented entry counts as indentation -> TRUE';

# Marker NOT on the first line: a real Minilla layout has a title + blank line
# before {{$NEXT}}. /m's ^ must anchor at the marker's own line, not just the
# string start. This is the only TRUE fixture that kills a dropped-/m mutant -
# every other TRUE case puts the marker on line 1, where ^ matches regardless.
ok  with_changes("Revision history for Foo\n\n{{\$NEXT}}\n  - foo\n"),
    'marker on a later line (title + blank above) is TRUE (/m, kills dropped-/m mutant)';

# Empty {{$NEXT}} section: the marker is immediately followed by a blank line and
# then a NON-indented older-release header. The older release below DOES carry
# indented entries - the match must stay anchored to the marker and NOT drift
# onto that unrelated section's indentation.
ok !with_changes("{{\$NEXT}}\n\n0.35 2025-01-01\n  - old entry\n"),
    'empty NEXT section above an indented older release is FALSE (no drift)';

# CRLF line endings after the marker: \R matches \r\n as one break, \h does not
# swallow the \r, so {{$NEXT}}\r\n + indented entry still matches -> TRUE.
ok  with_changes("{{\$NEXT}}\r\n  - foo\r\n"),
    'CRLF (\\r\\n) line endings after the marker still TRUE';

# A Changes path that exists but cannot be opened for reading must take the
# `open ... or return 0` branch. chmod 0000 a regular file (so -f is TRUE but
# open fails with EACCES). Skip under root, where the perms are ignored.
SKIP: {
  skip 'cannot deny read access as root', 1 if $> == 0;
  my $before = Cwd::getcwd();
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  my $r;
  {
    chdir $tmp or die "chdir $tmp: $!";
    open my $fh, '>', 'Changes' or die "open Changes: $!";
    print {$fh} "{{\$NEXT}}\n  - foo\n";
    close $fh;
    chmod 0000, 'Changes' or die "chmod Changes: $!";
    # Guard against a host where 0000 is still readable (some FS / mount opts).
    if ( open my $probe, '<', 'Changes' ) {
      close $probe;
      chmod 0644, 'Changes';
      chdir $before or die "chdir back $before: $!";
      skip 'chmod 0000 did not deny read on this filesystem', 1;
    }
    $r = App::Mist::Command::release::_changes_has_next_entry();
    chmod 0644, 'Changes';    # let CLEANUP unlink it
    chdir $before or die "chdir back $before: $!";
  }
  is $r, 0, 'unreadable Changes (chmod 0000) returns 0 via open-failure branch';
}

# A directory named Changes is not a plain file: -f is FALSE, so the guard
# `return 0 unless -f 'Changes'` fires before open is even attempted.
{
  my $before = Cwd::getcwd();
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  my $r;
  {
    chdir $tmp or die "chdir $tmp: $!";
    mkdir 'Changes' or die "mkdir Changes: $!";
    $r = App::Mist::Command::release::_changes_has_next_entry();
    chdir $before or die "chdir back $before: $!";
  }
  is $r, 0, 'a directory named Changes returns 0 (not a plain file)';
}

my $before = Cwd::getcwd();
with_changes("{{\$NEXT}}\n  - foo\n");
my $after = Cwd::getcwd();
is $after, $before, 'cwd is restored after a with_changes call';

done_testing;
