package Mist::Distribution;
# ABSTRACT: provides access to build parameters for this project

use strict;
use warnings;

use Carp;
use File::Spec;
use Cwd ();

sub _uniq { my %i = (); grep { not $i{$_}++ } @_; }

sub new {
  my $this = shift;
  my $class = ref( $this ) || $this;
  my $dist_name = shift;

  bless {
    assert      => [],
    prepend     => [],
    notest      => [],
    perl        => undef,
    dist_path   => undef,
    dist_name   => $dist_name,
    merge_dists => [],
    merge_info  => {},
    script      => {
      prepare  => [],
      finalize => [],
    }
  }, $class;
}

our $merging_dist;

sub store_dist_info {
  my ( $self, $key, @info ) = @_;

  $key = [ $key ] unless ref $key eq 'ARRAY';

  my $stash = $self; my @proto_key = @$key;
  while ( my $k = shift @proto_key ) {
    confess "Unknown key ${k}" unless exists $stash->{ $k };
    $stash = $stash->{ $k };
  }

  confess "`@$key` needs to be an arrayref"
    unless ref $stash eq 'ARRAY';

  if ( my $dist = $merging_dist ) {

    # store info in merged dist info
    my $md_info = $self->get_merged_dist_info( $dist );
    confess "Internal: no info about merged dist ${dist} found"
      unless $md_info and $md_info->isa( __PACKAGE__ );

    {
      local $merging_dist;      # undef
      $md_info->store_dist_info( $key, @info );
    }

    # prepend info for merged distributions
    unshift @$stash, @info;
  } else {
    push @$stash, @info;
  }
  @$stash = _uniq( @$stash );

}

sub merge($&) {
  my ( $self, $dist, $code ) = @_;

  if ( $merging_dist ) {
    my @stack = @{ $self->{ merge_dists }};
    $self->{ merge_dists } = [];
    while ( @stack and $stack[0] ne $merging_dist ) {
      push @{ $self->{ merge_dists }}, shift @stack;
    }
    push @{ $self->{ merge_dists }}, $merging_dist, @stack;
  }

  $self->store_dist_info( merge_dists => $dist );
  $self->{ merge_info }{ $dist } = $self->new( $dist );
  local $merging_dist = $dist;
  $code->();
}

sub assert(&@) {
  my ( $self, $code ) = @_;
  croak "assert needs a block, not " . ref $code
    unless ref $code eq 'CODE';
  $self->store_dist_info( assert => $code );
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

  my $md_info = $self->get_merged_dist_info( $merging_dist )
    or die "Unknown merged dist ${merging_dist}";

  croak "Dist path has been set before" if $md_info->{dist_path};

  $md_info->{dist_path} = "$path";
}

sub prepend ($;$) {
  my ( $self, $module, $version ) = @_;
  $version = sprintf( q{~%s}, $version ) if $version and $version !~ /^[=@><~]+/;
  $module  = sprintf( q{%s%s}, $module, $version ) if $version;
  $self->store_dist_info( prepend => $module );
}

sub notest ($) {
  my ( $self, $module ) = @_;
  $self->store_dist_info( notest => $module );
}

sub script ($$) {
  my ( $self, $phase, $path, @args ) = @_;
  die "Unknown phase $phase" unless exists $self->{script}{$phase};
  $self->store_dist_info( [ script => $phase ], [ $path, @args ]);
}

sub get_assertions           { my $self = shift; return @{ $self->{assert}}   }
sub get_default_perl_version { my $self = shift; return    $self->{perl}      }
sub get_dist_path            { my $self = shift; return    $self->{dist_path} }
sub get_prepended_modules    { my $self = shift; return @{ $self->{prepend}}  }
sub get_modules_not_to_test  { my $self = shift; return @{ $self->{notest}}   }


sub get_scripts {
  my $self = shift;  my $phase = shift;
  return @{ $self->{script}{$phase}};
}

sub get_merged_dists {
  my $self = shift;
  return @{ $self->{merge_dists}};
}

sub get_merged_dist_info {
  my ( $self, $dist ) = @_;
  croak "No dist name given" unless $dist;
  return undef unless exists $self->{ merge_info }{ $dist };
  return $self->{merge_info}{ $dist };
};

# ---

sub get_relative_merge_path {
  my ( $self, $dist ) = @_;
  croak "No dist name given" unless $dist;

  my $md_info = $self->get_merged_dist_info( $dist )
    or return undef;

  return $md_info->get_dist_path;
}

sub get_default_merge_path {
  my ( $self, $dist ) = @_;
  croak "No dist name given" unless $dist;

  my $md_info = $self->get_merged_dist_info( $dist )
    or return undef;

  $dist =~ s{::}{-}g;
  my $cwd = Cwd::cwd();
  return File::Spec->catdir( $cwd, File::Spec->updir, lc $dist );
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
