#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Capture::Tiny qw/ capture /;

use Minilla::Release::TagPublish;
use Minilla::Release::TagLocal;
use Minilla::Release::MakeDist;

# A dry run skips the version-bump step, so $project->version is the un-bumped
# CURRENT version - not what a real release would tag. The Tag steps must not
# echo it on a dry run: "Would have tagged version 0.26" reads as "this release
# is 0.26" and misleads (a real release bumps, or keeps an in-flight version,
# then tags).
#
# BumpVersionSmart does know the real one, and leaves it in $opts, so the Tag
# steps name that when it is there. The invariant is not "no version" but "never
# the un-bumped one".

{
  package FakeProject;
  sub new     { bless {}, shift }
  sub version { '0.26' }              # a recognizable version the line must NOT echo
}

my $proj = FakeProject->new;

for my $step ( qw/ Minilla::Release::TagPublish Minilla::Release::TagLocal / ) {
  my ( $out, $err ) = capture {
    $step->run( $proj, { dry_run => 1 } );
  };
  my $msg = $out . $err;

  like $msg, qr/DRY-RUN/,
    "$step dry run still announces DRY-RUN";
  unlike $msg, qr/0\.26/,
    "$step dry run does not echo the un-bumped current version";
  unlike $msg, qr/version\s+\d/,
    "$step dry run names no version number when none was worked out";

  # The usual case: the bump step ran, declined to write, and passed on what a
  # real release would tag.
  my ( $out2, $err2 ) = capture {
    $step->run( $proj, { dry_run => 1, dry_run_version => '0.27' } );
  };
  my $msg2 = $out2 . $err2;

  like $msg2, qr/0\.27/,
    "$step dry run names the version a real release would tag";
  unlike $msg2, qr/0\.26/,
    "$step dry run still never echoes the un-bumped one";
}

# The same rule for the tarball. Minilla::WorkDir::dist prints "Wrote
# App-Foo-0.26.tar.gz" from inside the work dir; a dry run removes that
# directory, so without a word the run ends having announced a file the project
# root never receives.
{
  package FakeWorkDir;
  sub new  { bless {}, shift }
  sub dist { 1 }

  package FakeDistProject;
  sub new      { bless {}, shift }
  sub work_dir { FakeWorkDir->new }
}

DRY_RUN_TARBALL_IS_DECLARED_EPHEMERAL: {
  my ( $out, $err ) = capture {
    Minilla::Release::MakeDist->run( FakeDistProject->new, { dry_run => 1 } );
  };
  my $msg = $out . $err;

  like $msg, qr/DRY-RUN/,      'MakeDist marks the dry run';
  like $msg, qr/discarded/,    '...saying the tarball does not survive it';

  my ( $out2, $err2 ) = capture {
    Minilla::Release::MakeDist->run( FakeDistProject->new, { dry_run => 0 } );
  };
  is $out2 . $err2, q{},
    'and a real release, whose tarball is the release, adds nothing';
}

done_testing;
