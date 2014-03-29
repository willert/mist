package Mist::ParseDistribution;
use strict;
use warnings;

use base 'CPAN::ParseDistribution';
use Path::Class ();
use Carp;

# Those are dynamically loaded normally. Force pre-loading them
# because we will use mist's local::lib in the process of
# installing distributions
use CPAN::ParseDistribution::Unix;
use Devel::AssertOS::Unix;

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

sub as_module_name {
  my $self = shift;
  my $name = $self->{dist};
  $name =~ s/-/::/g;
  return $name;
}

1;
