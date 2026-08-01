package Minilla::Release::TagPrerelease;
use strict;
use warnings;
use utf8;

use Minilla::Util qw(cmd);
use Minilla::Logger;

# Tags the prerelease locally and does not push: a prerelease is handed to a
# sibling checkout, never published.
#
# Deliberately no `git tag -f`. Every prerelease carries a version no earlier
# one had, so the tag is always new - an existing tag means something else
# already claimed that version, which is a fault to look at rather than
# something to overwrite.
sub run {
  my ( $self, $project, $opts ) = @_;

  if ( $opts->{dry_run} ) {
    my $would = $opts->{dry_run_version};
    infof("DRY-RUN.  No tag created; %s\n", $would
      ? "a prerelease would tag $would."
      : "the prerelease version is decided and tagged only on a real run.");
    return;
  }

  cmd( 'git', 'tag', $project->format_tag( $project->version ) );
  return;
}

1;
