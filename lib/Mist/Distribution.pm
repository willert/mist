package Mist::Distribution;
# ABSTRACT: provides access to build parameters for this project

use strict;
use warnings;

use Carp;
use Path::Class ();

sub new {
  my $this = shift;
  bless {
    assert   => [],
    prepend  => [],
    notest   => [],
    perl     => undef,
    dist_path => undef,
    merge    => {},
    script   => {
      prepare  => [],
      finalize => [],
    }
  }, ref( $this ) || $this;
}

our $merging_dist;

sub store_dist_info {
  my ( $self, $stack, $info ) = @_;
  die "Needs an arrayref" unless ref $stack eq 'ARRAY';
  if ( my $dist = $merging_dist ) {

    # store info in merged dist info
    my $md_info = $self->{merge}{ $dist };
    die "Internal: no info about merged dist ${dist} found"
      unless $md_info and $md_info->isa( __PACKAGE__ );
    $md_info->store_dist_info( $info );

    # prepend info for merged distributions
    unshift @$stack, $info;
  } else {
    push @$stack, $info;
  }
}

sub merge($&) {
  my ( $self, $dist, $code ) = @_;
  $self->{merge}{ $dist } = $self->new;
  local $merging_dist = $dist;
  $code->();
}

sub assert(&@) {
  my ( $self, $code ) = @_;
  croak "assert needs a block, not " . ref $code
    unless ref $code eq 'CODE';
  $self->store_dist_info( $self->{ assert }, $code );
}

sub perl ($) {
  my ( $self, $version ) = @_;

  # ignore merged default perl version
  return if $merging_dist;

  croak "Perl version has been set before" if $self->{perl};
  $self->{perl} = $version;
}

sub dist_path ($) {
  my ( $self, $path ) = @_;

  # ignore merged default perl version
  return unless $merging_dist;

  my $md_info = $self->get_merged_distribution( $merging_dist )
    or die "Unknown merged dist ${merging_dist}";

  croak "Dist path has been set before" if $md_info->{dist_path};

  $md_info->{dist_path} = Path::Class::Dir->new( $path );
}

sub prepend ($;$) {
  my ( $self, $module, $version ) = @_;
  $version = sprintf( q{"%s"}, $version ) if $version and $version =~ /[^\d.]/;
  $module  = sprintf( q{%s~%s}, $module, $version ) if $version;
  $self->store_dist_info( $self->{prepend}, $module );
}

sub notest ($) {
  my ( $self, $module ) = @_;
  $self->store_dist_info( $self->{notest}, $module );
}

sub script ($$) {
  my ( $self, $phase, $path, @args ) = @_;
  die "Unknown phase $phase" unless exists $self->{script}{$phase};
  $self->store_dist_info( $self->{script}{$phase}, [ $path, @args ]);
}

sub get_assertions           { my $self = shift; return @{ $self->{assert}}   }
sub get_default_perl_version { my $self = shift; return    $self->{perl}      }
sub get_dist_path            { my $self = shift; return    $self->{dist_path} }
sub get_prepended_modules    { my $self = shift; return @{ $self->{prepend}}  }
sub get_modules_not_to_test  { my $self = shift; return @{ $self->{notest}}   }

sub get_merged_dists { my $self = shift; return keys %{ $self->{merge}} }

sub get_scripts              {
  my $self = shift;  my $phase = shift;
  return @{ $self->{script}{$phase}};
}

sub get_merged_distribution {
  my ( $self, $dist ) = @_;
  croak "No dist name given" unless $dist;
  return undef unless exists $self->{merge}{ $dist };
  return $self->{merge}{ $dist };
};

sub get_relative_merge_path {
  my ( $self, $dist ) = @_;
  croak "No dist name given" unless $dist;
  return undef unless exists $self->{merge}{ $dist };

  my $md_info = $self->{merge}{ $dist };
  return $md_info->get_dist_path ? Path::Class::Dir->new( $md_info->get_dist_path ) : undef;
}

sub get_default_merge_path {
  my ( $self, $dist ) = @_;
  croak "No dist name given" unless $dist;
  return undef unless exists $self->{merge}{ $dist };

  $dist =~ s{::}{-}g;
  my $cwd = Path::Class::Dir->new();
  return $cwd->parent->subdir( lc $dist );
};

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
