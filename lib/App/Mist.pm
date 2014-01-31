package App::Mist;
# ABSTRACT: MPAN distribution manager
use 5.010;
use App::Cmd::Setup -app;

our $VERSION = '0.1';

# preload all commands
# use Module::Pluggable search_path => [ 'App::Mist::Command' ];

use App::Mist::Context;

sub ctx {
  my $self = shift;
  $self->{ctx} //= App::Mist::Context->new;
}


1;
