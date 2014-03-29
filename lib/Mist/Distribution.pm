package Mist::Distribution;
# ABSTRACT: provides access to build parameters for this project

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

our $for_distribution;

sub store_dist_info {
  my ( $stack, $info ) = @_;
  die "Needs an arrayref" unless ref $stack eq 'ARRAY';
  if ( $for_distribution ) {
    # prepend info for merged distributions
    unshift @$stack, $info;
  } else {
    push @$stack, $info;
  }
}

sub merge(&$$) {
  my ( $self, $code, $guard, $dist ) = @_;

  die "Invalid merge block" unless $guard eq 'dist';

  {
    local $for_distribution = $dist;
    $code->();
  }
}

sub assert(&@) {
  my ( $self, $code ) = @_;
  croak "assert needs a block, not " . ref $code
    unless ref $code eq 'CODE';
  store_dist_info( $self->{ assert }, $code );
}

sub perl ($) {
  my ( $self, $version ) = @_;

  # ignore merged default perl version
  return if $for_distribution;

  croak "Perl version has been set before" if $self->{perl};
  $self->{perl} = $version;
}

sub prepend ($;$) {
  my ( $self, $module, $version ) = @_;
  $version = sprintf( q{"%s"}, $version ) if $version and $version =~ /[^\d.]/;
  $module  = sprintf( q{%s~%s}, $module, $version ) if $version;
  store_dist_info( $self->{prepend}, $module );
}

sub notest ($) {
  my ( $self, $module ) = @_;
  store_dist_info( $self->{notest}, $module );
}


sub get_assertions           { my $self = shift; return @{ $self->{assert}}  }
sub get_default_perl_version { my $self = shift; return    $self->{perl}     }
sub get_prepended_modules    { my $self = shift; return @{ $self->{prepend}} }
sub get_modules_not_to_test  { my $self = shift; return @{ $self->{notest}}  }

sub build_cpanm_call_stack {
  my ( $self, @prereqs ) = @_;

  my %opts;
  %opts = %{ shift @prereqs }
    if @prereqs and ref $prereqs[0] eq 'HASH';

  @prereqs = @{ shift @prereqs }
    if @prereqs == 1 and ref $prereqs[0] eq 'ARRAY';

  my @prepended = $self->get_prepended_modules;

  # state variables
  my ( %version, %scheduled, %dont_test, @callstack );

  # build hash of modules we don't want to test
  %dont_test = map{ $_ => 1 } $self->get_modules_not_to_test;

  # push a module on the call stack according to state vars
  my $push_module_on_stack = sub{
    my $module = shift;
    return if $scheduled{ $module };

    my $mod_spec = $version{ $module } ?
      join( q{~}, $module, $version{$module} ) : $module;

    if ( $dont_test{ $module } and not $opts{'force-tests'} ) {
      push @callstack, [ '--installdeps', $mod_spec ];
      push @callstack, [ '--notest', $mod_spec ];
    } else {
      push @callstack, [ $mod_spec ];
    }

    $scheduled{ $module } = 1;
  };

  # pre-parse version spec from prerequisites
  for ( @prereqs ) {
    my ( $module, $version ) = split( q{~}, $_, 2 );
    $_ = $module;
    $version{ $module } = $version;
  }

  # pre-parse version spec from prepended modules
  for ( @prepended ) {
    my ( $module, $version ) = split( q{~}, $_, 2 );
    $_ = $module;

    warn "Conflicting versions for $module in mistfile and cpanfile\n"
      if $version and $version{$module} and $version ne $version{$module};

    # prepended version requirement superseded cpanfile requirement
    $version{ $module } = $version if $version;
  }

  # schedule prepended modules
  unless ( $opts{'skip-prepended'} ) {
    $push_module_on_stack->( $_ ) for @prepended;
  }

  # schedule remaining modules that are not tested before the remaining
  # prerequisites to avoid prereqs pulling in this module without --notest
  unless ( $opts{'skip-notest'} ) {
    $push_module_on_stack->( $_ ) for keys %dont_test;
  }

  # schedule remaining prerequisites
  $push_module_on_stack->( $_ ) for @prereqs;

  return @callstack;
}

1;
