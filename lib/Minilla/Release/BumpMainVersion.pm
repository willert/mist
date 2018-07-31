package Minilla::Release::BumpMainVersion;
use strict;
use warnings;
use utf8;

use base 'Minilla::Release::BumpVersion';

sub bump_version {
  my ($self, $project, $version) = @_;

  my $file = $project->main_module_path;
  my $bump = Module::BumpVersion->load($file);
  $bump->set_version($version);
};


1;
