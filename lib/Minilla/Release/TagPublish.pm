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
    # Never $ver here: a dry run skips the bump step, so it is the un-bumped
    # current version, NOT what a real release would tag, and naming it reads as
    # "this release is $ver". BumpVersionSmart works the real one out and leaves
    # it in $opts.
    my $would = $opts->{dry_run_version};
    infof("DRY-RUN.  No tag created or pushed; %s\n", $would
      ? "a real release would tag $would."
      : "the release version is decided and tagged only on a real release.");
    return;
  }

  my $tag = $project->format_tag($ver);
  cmd('git', 'tag', '-f', $tag);
  cmd('git', 'push', 'origin', tag => $tag);
}

1;
