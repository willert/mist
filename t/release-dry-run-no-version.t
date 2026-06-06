#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Capture::Tiny qw/ capture /;

use Minilla::Release::TagPublish;
use Minilla::Release::TagLocal;

# A dry run skips the version-bump step, so $project->version is the un-bumped
# CURRENT version - not what a real release would tag. The Tag steps must not
# echo it on a dry run: "Would have tagged version 0.26" reads as "this release
# is 0.26" and misleads (a real release bumps, or keeps an in-flight version,
# then tags). The dry-run line stays version-free and says so.

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
    "$step dry run names no version number at all";
}

done_testing;
