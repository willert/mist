package Mist::ParseDistribution;
use strict;
use warnings;

use base 'CPAN::ParseDistribution';
use Path::Class ();
use Carp;

sub new {
  my ( $class, $file, %extra_params ) = @_;

  my $repo = delete $extra_params{repository}
    or croak "missing 'repository' parameter pointing to a Mist repository";

  my $self = $class->SUPER::new( $file, %extra_params );
  $self->{pathname}   = Path::Class::file( $file )->absolute->resolve;
  $self->{repository} = Path::Class::dir(  $repo )->absolute->resolve;

  $self->modules; # force vivification of module hash

  return $self;
}

sub pathname {
  my $self = shift;
  return $self->{pathname};
}

sub repository {
  my $self = shift;
  return $self->{repository};
}

sub repository_path {
  my $self = shift;
  Path::Class::file( $self->pathname )->relative( $self->repository );
}

sub module_path {
  my $self = shift;
  Path::Class::file( $self->pathname )->relative(
    $self->repository->subdir(qw/ authors id /)
  );
}

1;
