package Minilla::Release::MakeDist;
use strict;
use warnings;
use utf8;

use Minilla::Logger;

# Stock MakeDist, plus one line on a dry run.
#
# Minilla::WorkDir::dist builds the tarball inside the work dir and announces
# "Wrote App-Mist-<ver>.tar.gz" from there. On a real release that file goes on
# to be the release; on a dry run the work dir is removed on the way out, so the
# line names a file the project root never receives - and names it for the
# un-bumped version besides. Both are worth one line at the point of confusion,
# rather than being re-derived from the pipeline on every release.
#
# The label is deliberately explained rather than corrected. Minilla copies the
# module source into the work dir verbatim (WorkDir::_rewrite_pod is disabled
# upstream), so renaming the tarball to the version under validation would leave
# it carrying the current $VERSION - and mist resolves on `>=` floors, where a
# tarball claiming a version it does not have satisfies a floor it does not
# meet. Under-labelling cannot break that invariant: it promises less than it
# delivers. Naming the true version is also not free of the source tree, since
# Project::regenerate_files writes back into the project root even when called
# from the work dir.
sub run {
  my ($self, $project, $opts) = @_;

  my $work_dir = $project->work_dir();
  $work_dir->dist;

  return unless $opts->{dry_run};
  infof("DRY-RUN.  That tarball was built inside the work dir to validate the "
      . "manifest, and is discarded with it.\n");
  return;
}

1;
