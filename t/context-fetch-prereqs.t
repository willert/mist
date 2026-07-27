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

# ---------------------------------------------------------------------------
# `requires 'perl' => '5.020'` is the standard cpanfile way to declare an
# interpreter floor, but `perl` is CPAN::Meta's pseudo-prereq, not a
# distribution. Passed through, cpanm aborts the whole install with "Couldn't
# find module or a distribution perl", which is what broke a fresh project's
# first `mist init`. It is checked against the mistfile's pin instead - the
# project's declared perl, rather than whichever one is running the command.

# Not built on prereqs_for: Context::BUILD chdirs into the project, and when
# fetch_prereqs dies that sub's chdir-back never runs, so its File::Temp::Dir is
# reaped while the cwd is still inside it ("cannot remove path when cwd is ...").
# Hold the tempdir here and chdir back before returning, so it is reaped from
# outside.
sub prereqs_error_for {
  my (%file) = @_;
  my $tmp    = build_project( %file );
  my $before = Cwd::getcwd();

  my $ctx = App::Mist::Context->new(
    project_root => Path::Class::Dir->new( "$tmp" )->absolute->resolve,
  );

  local $@;
  eval { $ctx->fetch_prereqs; 1 };
  my $error = $@;

  chdir $before or die "chdir back $before: $!";

  return "$error";
}

PERL_PREREQ_IS_NOT_HANDED_TO_CPANM: {
  my @reqs = prereqs_for(
    cpanfile => qq{requires 'perl' => '5.020';\nrequires 'Zoo::Mod' => '1.0';\n},
    mistfile => qq{perl '5.20.3';\n},
  );

  is_deeply [ @reqs ], [ 'Zoo::Mod~1.0' ],
    'the perl pseudo-prereq is dropped and real modules pass through';
}

PERL_PREREQ_IS_CHECKED_AGAINST_THE_MISTFILE_PIN: {
  # Satisfied: a decimal floor against a dotted pin, which naive string or
  # numeric comparison gets wrong. 5.020 is 5.20.0, so 5.20.3 clears it.
  my @ok = prereqs_for(
    cpanfile => qq{requires 'perl' => '5.020';\n},
    mistfile => qq{perl '5.20.3';\n},
  );
  is_deeply [ @ok ], [], 'a satisfied floor leaves nothing for cpanm';

  ok !prereqs_error_for(
    cpanfile => qq{requires 'perl' => '>= 5.010, < 5.030';\n},
    mistfile => qq{perl '5.20.3';\n},
  ), 'a satisfied range does not die';

  my $error = prereqs_error_for(
    cpanfile => qq{requires 'perl' => '5.022';\n},
    mistfile => qq{perl '5.20.3';\n},
  );
  like $error, qr/requires perl/, 'an unsatisfied floor dies';
  like $error, qr/5\.022/, 'naming the cpanfile requirement';
  like $error, qr/5\.20\.3/, 'and the mistfile pin';
}

UNPINNED_PROJECT_CANNOT_CHECK_THE_FLOOR: {
  # With no mistfile perl there is nothing authoritative to compare against, so
  # the floor goes unverified rather than being checked against a guess - but it
  # still must not reach cpanm.
  my @reqs = prereqs_for(
    cpanfile => qq{requires 'perl' => '5.999';\nrequires 'Zoo::Mod';\n},
    mistfile => qq{notest 'Zoo::Mod';\n},
  );

  is_deeply [ @reqs ], [ 'Zoo::Mod' ],
    'an unpinned project drops perl without dying on the floor';

  my @no_mistfile = prereqs_for(
    cpanfile => qq{requires 'perl' => '5.999';\nrequires 'Zoo::Mod';\n},
  );
  is_deeply [ @no_mistfile ], [ 'Zoo::Mod' ],
    'and so does a project with no mistfile at all';
}

done_testing;
