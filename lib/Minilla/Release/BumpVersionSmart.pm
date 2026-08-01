package Minilla::Release::BumpVersionSmart;
use strict;
use warnings;
use utf8;

use base 'Minilla::Release::BumpVersion';
use Minilla::Logger;
use version 0.77 ();

sub run {
  my ($self, $project, $opts) = @_;

  my $curver = $project->metadata->version;

  # A prerelease line ends at the next stable version. Its own tag is never on
  # origin - prereleases are not published - so the in-flight branch below would
  # hold the trial version and release it as-is, which is the one thing the
  # trial component exists to prevent.
  if ( version->parse( "$curver" )->is_alpha ) {
    my $target = _promote( $curver );

    if ( $opts->{dry_run} ) {
      $opts->{dry_run_version} = $target;
      infof("DRY-RUN.  A real release would promote prerelease %s to %s. The "
          . "bump is not applied here, so everything below is still labelled "
          . "%s.\n", $curver, $target, $curver);
      return;
    }

    infof("Promoting prerelease %s to %s\n", $curver, $target);
    $self->bump_version( $project, $target );
    $project->clear_metadata;
    return;
  }

  my $tag = $project->format_tag($curver);

  unless ( _tag_on_origin($tag) ) {
    infof("Keeping in-flight version %s; tag '%s' is not on origin yet\n",
          $curver, $tag);
    # Nothing is bumped either way, so the current version is also what a real
    # release would tag.
    $opts->{dry_run_version} = $curver if $opts->{dry_run};
    return;
  }

  # A dry run must not write the bump, so metadata keeps the current version and
  # every later step inherits it. Name the version a real release would use, and
  # say that the rest of the run is labelled with the old one - otherwise both
  # have to be re-derived from the pipeline on every release.
  if ( $opts->{dry_run} ) {
    my $next = $self->default_new_version($project);
    $opts->{dry_run_version} = $next;
    infof("DRY-RUN.  A real release would bump %s to %s. The bump is not "
        . "applied here, so everything below is still labelled %s.\n",
          $curver, $next, $curver);
    return;
  }

  return $self->SUPER::run($project, $opts);
}

# 0.52_02 -> 0.53: drop the trial component, then take the next stable version.
# Version::Next alone would give 0.52_03, continuing the prerelease line rather
# than ending it.
sub _promote {
  my ( $curver ) = @_;
  require Version::Next;
  ( my $base = "$curver" ) =~ s/_.*\z//;
  return Version::Next::next_version( $base );
}

sub _tag_on_origin {
  my ($tag) = @_;
  my $rc = system("git ls-remote --exit-code origin refs/tags/$tag >/dev/null");
  my $exit = $rc >> 8;
  return 1 if $exit == 0;
  return 0 if $exit == 2;
  die "git ls-remote origin refs/tags/$tag failed (exit $exit)\n";
}

1;
