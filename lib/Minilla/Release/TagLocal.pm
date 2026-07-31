package Minilla::Release::TagLocal;
use strict;
use warnings;
use utf8;

use Minilla::Util qw(cmd);
use Minilla::Logger;

sub run {
  my ($self, $project, $opts) = @_;

  my $ver = $project->version;
  if ( $opts->{dry_run} ) {
    # See TagPublish: $ver is the un-bumped current version on a dry run, not
    # what a real release would tag, so it is never named. BumpVersionSmart
    # leaves the real one in $opts.
    my $would = $opts->{dry_run_version};
    infof("DRY-RUN.  No tag created; %s\n", $would
      ? "a real release would tag $would."
      : "the release version is decided and tagged only on a real release.");
    return;
  }

  cmd('git', 'tag', '-f', $project->format_tag($ver));
}

1;
