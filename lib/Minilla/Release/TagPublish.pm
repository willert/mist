package Minilla::Release::TagPublish;
use strict;
use warnings;
use utf8;

use Minilla::Util qw(cmd);
use Minilla::Logger;

sub run {
  my ($self, $project, $opts) = @_;

  my $ver = $project->version;
  if ( $opts->{dry_run} ) {
    # Deliberately no version here: a dry run skips the bump step, so $ver is
    # the un-bumped current version, NOT what a real release would tag. Naming
    # it reads as "this release is $ver" and misleads. The tag version is
    # decided (bump or keep-in-flight) only on a real release.
    infof("DRY-RUN.  No tag created or pushed; the release version is decided and tagged only on a real release.\n");
    return;
  }

  my $tag = $project->format_tag($ver);
  cmd('git', 'tag', '-f', $tag);
  cmd('git', 'push', 'origin', tag => $tag);
}

1;
