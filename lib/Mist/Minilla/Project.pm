package Mist::Minilla::Project;
use strict;
use warnings;
use utf8;

use File::Path ();
use Minilla::Logger;

use Moo;
extends 'Minilla::Project';

sub _build_work_dir {
  my $self = shift;
  Minilla::WorkDir->new(
    project  => $self, cleanup => 0,
  );
}

sub cleanup {
  my $self = shift;
  infof( "Removing %s\n", $self->work_dir->dir );
  File::Path::rmtree( $self->work_dir->dir );

}

1;
