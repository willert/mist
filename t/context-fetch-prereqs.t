#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use File::Temp ();
use File::Spec;
use Cwd ();

use App::Mist::Context;

# ---------------------------------------------------------------------------
# App::Mist::Context::fetch_prereqs loads the project cpanfile via
# Module::CPANfile, MERGES the requirements across every phase (runtime plus
# any 'on <phase>' block), formats each entry as 'Module~version' (bare
# 'Module' when there is no version constraint), and keysorts by the BARE
# module name (the '~version' suffix is stripped for the sort key only).
#
# Context::BUILD chdirs into project_root, so we save and restore cwd around
# construction. project_root is passed explicitly to skip the upward
# mistfile/cpanfile walk; the temp dir still gets both files so the project
# layout is realistic. The File::Temp::Dir object is held in a lexical for the
# whole test so it is not reaped (and CLEANUP'd) while we use it.
# ---------------------------------------------------------------------------

sub build_project {
  my (%file) = @_;

  my $tmp = File::Temp->newdir( CLEANUP => 1 );

  while ( my ( $name, $content ) = each %file ) {
    my $path = File::Spec->catfile( "$tmp", $name );
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $content;
    close $fh;
  }

  return $tmp;
}

sub prereqs_for {
  my (%file) = @_;

  my $tmp    = build_project( %file );
  my $before = Cwd::getcwd();

  my $ctx = App::Mist::Context->new(
    project_root => Path::Class::Dir->new( "$tmp" )->absolute->resolve,
  );

  my @reqs = $ctx->fetch_prereqs;

  chdir $before or die "chdir back $before: $!";

  return @reqs;
}

# A cpanfile mixing runtime requires with an 'on test' phase, plus a versioned
# and a no-version runtime requirement, exercises all three behaviours at once:
# phase merging, version formatting, and bare-name sorting.

my $cpanfile = <<'CPANFILE';
requires "Zoo::Mod", "1.0";
requires "Aardvark";
requires "Mid::Mod", "2.5";

on test => sub {
  requires "Test::More", "0.88";
};
CPANFILE

my @reqs = prereqs_for(
  cpanfile => $cpanfile,
  mistfile => "1;\n",
);

# --- phase merging ---------------------------------------------------------

ok scalar( grep { /^Test::More\b/ } @reqs ),
  "'on test' requirement is folded into the merged output";

# --- version normalization -------------------------------------------------

ok scalar( grep { $_ eq 'Mid::Mod~2.5' } @reqs ),
  "versioned requirement emerges as 'Mid::Mod~2.5'";

ok scalar( grep { $_ eq 'Aardvark' } @reqs ),
  'no-version requirement emerges bare (no ~ suffix)';

ok !scalar( grep { /^Aardvark~/ } @reqs ),
  'no-version requirement carries no version suffix';

is scalar( grep { /^Test::More/ } @reqs ), 1,
  'each module appears exactly once after the phase merge';

# --- full sorted output ----------------------------------------------------

is_deeply
  [ @reqs ],
  [ 'Aardvark', 'Mid::Mod~2.5', 'Test::More~0.88', 'Zoo::Mod~1.0' ],
  'output is the phase-merged list sorted by bare module name';

# --- sort key strips the version (not lexical on the whole string) ---------
# 'Zebra~0.01' must sort before 'Zoo::Mod~9.9' purely on the bare name, and a
# bare 'Test::More' must not jump ahead of 'Aardvark~0.01' just because it
# lacks a '~'. This pins the keysort { s/~.*//r } behaviour specifically.

my @ordered = prereqs_for(
  cpanfile => <<'CPANFILE',
requires "Zoo::Mod", "9.9";
requires "Aardvark", "0.01";
requires "Test::More";
requires "Zebra", "0.01";
CPANFILE
  mistfile => "1;\n",
);

is_deeply
  [ @ordered ],
  [ 'Aardvark~0.01', 'Test::More', 'Zebra~0.01', 'Zoo::Mod~9.9' ],
  'sort key is the bare module name with any ~version stripped';

done_testing;
