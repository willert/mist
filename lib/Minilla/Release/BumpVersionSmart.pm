package Minilla::Release::BumpVersionSmart;
use strict;
use warnings;
use utf8;

use base 'Minilla::Release::BumpVersion';
use Minilla::Logger;

sub run {
  my ($self, $project, $opts) = @_;

  my $curver = $project->metadata->version;
  my $tag    = $project->format_tag($curver);

  unless ( _tag_on_origin($tag) ) {
    infof("Keeping in-flight version %s; tag '%s' is not on origin yet\n",
          $curver, $tag);
    # Nothing is bumped either way, so the current version is also what a real
    # release would tag.
    $opts->{dry_run_version} = $curver if $opts->{dry_run};
    return;
  }

  # A dry run must not write the bump, so metadata keeps the current version and
  # every later step inherits it: the tarball is named for it and the metadata
  # banner prints it. Name the version a real release would use, and say that
  # the rest of the run is labelled with the old one - otherwise both have to be
  # re-derived from the pipeline on every release.
  if ( $opts->{dry_run} ) {
    my $next = $self->default_new_version($project);
    $opts->{dry_run_version} = $next;
    infof("DRY-RUN.  A real release would bump %s to %s. The bump is not "
        . "applied, so the tarball and metadata below still say %s.\n",
          $curver, $next, $curver);
    return;
  }

  return $self->SUPER::run($project, $opts);
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
