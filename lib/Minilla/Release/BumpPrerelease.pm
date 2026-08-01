package Minilla::Release::BumpPrerelease;
use strict;
use warnings;
use utf8;

use base 'Minilla::Release::BumpVersion';
use Minilla::Logger;
use version 0.77 ();

# Every prerelease is a distinct artifact, so the version advances on every run.
# A consumer can then hold several iterations in its mirror at once and resolve
# the newest deterministically, and no two tarballs ever share a name while
# differing in content.
sub run {
  my ( $self, $project, $opts ) = @_;

  my $curver = $project->metadata->version;
  my $next   = next_prerelease( $curver );

  if ( $opts->{dry_run} ) {
    $opts->{dry_run_version} = $next;
    infof("DRY-RUN.  Would prerelease %s (from %s); nothing is written.\n",
          $next, $curver);
    return;
  }

  $self->bump_version( $project, $next );
  $project->clear_metadata;

  # Perl reads underscores in numeric literals as digit separators and discards
  # them, so an unquoted assignment yields an ordinary decimal that no longer
  # reports is_alpha. Everything downstream keys on that, so a silent stable
  # version here would produce a prerelease indistinguishable from a release.
  my $written = $project->metadata->version;
  # This message deliberately does not spell out an assignment. This module
  # declares no version of its own, so Module::Metadata->provides - which
  # Minilla runs over lib/ at release time - keeps scanning for one and evals
  # the first line carrying that variable and an equals sign. POD and comments
  # are safe (POD is skipped; a comment evals as a no-op), but a heredoc body is
  # code, and the obvious phrasing here killed a release.
  die <<"UNQUOTED" unless version->parse( "$written" )->is_alpha;
prerelease: wrote version $written, which is not a trial release.

  Perl reads underscores in unquoted numeric literals as digit separators and
  discards them, so an unquoted declaration of $written is really an ordinary
  decimal. Quote the version in the main module and re-run.
UNQUOTED

  infof("Prerelease %s\n", $written);
  return;
}

# 0.52 -> 0.52_01, and 0.52_01 -> 0.52_02.
#
# The alpha counter hangs off the CURRENT version rather than the one being
# worked toward, because X_01 sorts ABOVE X: numbering the prereleases of 0.53
# as 0.53_01 would place them above the release they precede, and a consumer
# pinning `>= 0.53` would accept one. 0.52_01 sits between 0.52 and 0.53, which
# is what makes that floor refuse it.
sub next_prerelease {
  my ( $curver ) = @_;
  require Version::Next;
  my $v = version->parse( "$curver" );
  return Version::Next::next_version( "$curver" ) if $v->is_alpha;
  return sprintf '%s_01', "$curver";
}

1;
