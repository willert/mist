package Mist::Distribution;
use strict;
use warnings;

use Carp;

sub new {
  bless {
    assert  => [],
    prepend => [],
    notest  => [],
    perl    => undef,
  }, shift;
}

sub assert(&@) {
  my ( $self, $code ) = @_;
  croak "assert needs a block, not " . ref $code
    unless ref $code eq 'CODE';
  push @{ $self->{ assert }}, $code;
}

sub get_assertions { my $self = shift; return @{ $self->{ assert }}; }

sub perl ($) {
  my ( $self, $version ) = @_;
  croak "Perl version has been set before" if $self->{perl};
  $self->{perl} = $version;
}

sub get_default_perl_version { my $self = shift; return $self->{ perl }; }

sub prepend ($;$) {
  my ( $self, $module, $version ) = @_;
  $version = sprintf( q{"%s"}, $version ) if $version and $version =~ /[^\d.]/;
  $module  = sprintf( q{%s~%s}, $module, $version ) if $version;
  push @{ $self->{prepend}}, $module;
}

sub get_prepended_modules { my $self = shift; return @{ $self->{ prepend }}; }

sub notest ($) {
  my ( $self, $module ) = @_;
  push @{ $self->{notest}}, $module;
}

sub get_modules_not_to_test { my $self = shift; return @{ $self->{ notest }}; }

1;
