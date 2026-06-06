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
    # what a real release would tag, so naming it misleads. Stay version-free.
    infof("DRY-RUN.  No tag created; the release version is decided and tagged only on a real release.\n");
    return;
  }

  cmd('git', 'tag', '-f', $project->format_tag($ver));
}

1;
