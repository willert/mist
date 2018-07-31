package Minilla::Release::CheckChangesNoEdit;
use strict;
use warnings;
use utf8;

use base 'Minilla::Release::CheckChanges';

sub run {
  my ($self, $project, $version) = @_;
  no warnings 'redefine';
  local *Minilla::Release::CheckChanges::prompt = sub { return 'n' };
  $self->SUPER::run( $project, $version );
};


1;
