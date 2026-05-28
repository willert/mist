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

  if ( _tag_on_origin($tag) ) {
    return $self->SUPER::run($project, $opts);
  }

  infof("Keeping in-flight version %s; tag '%s' is not on origin yet\n",
        $curver, $tag);
  return;
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
