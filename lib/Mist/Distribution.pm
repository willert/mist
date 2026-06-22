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
    perl        => undef,
    dist_path   => undef,
    dist_name   => $dist_name,
    merge_dists => [],
    merge_info  => {},
    # Per-dist build directives. One record per dist keyed by its bare module
    # name (so prepend/notest/ccflags on the same dist reconcile into a single
    # record), plus two ordered name lists. The folded view (_ordered_directive_names)
    # is merged names then own names, deduped first-occurrence: merged-before-outer,
    # declaration order within each. prepend is the base; notest and both ccflags
    # channels (:env and :wrapper) are decorators that imply membership.
    directives             => {},
    directive_order_merged => [],
    directive_order_own    => [],
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
  # The (&@) prototype (mirrored onto the mistfile DSL verb by
  # Mist::Environment::_bind) already forces a block/sub at compile time, so
  # $code is always a coderef here - no runtime type check is reachable.
  my ( $self, $code ) = @_;
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
  my $spec = $version ? sprintf( q{%s%s}, $module, $version ) : $module;
  $self->_record_directive( $module, prepend => $spec );
}

sub notest ($) {
  my ( $self, $module ) = @_;
  $self->_record_directive( $module, notest => 1 );
}

# ccflags [ ':env' | ':wrapper' ], $module => $flags
#
# Two independent per-dist compiler-flag channels, selected by an optional leading
# mode token (default :env, which is also writable explicitly):
#   :env     - flags reach the dist's own XS compile via --extra_compiler_flags /
#              a CCFLAGS= override (the surgical default).
#   :wrapper - flags are forced onto every compile in the dist's build through a
#              $Config{cc} PATH shim - the only lever that reaches a dist's internal
#              sub-makes (lemon, charmonizer, ...), which invoke $Config{cc} directly,
#              past --extra_compiler_flags. A last-resort tool for abandoned dists
#              whose pre-C23 C no longer compiles; it forces an older C standard so
#              the compiler keeps tolerating the code, it does not fix the dist.
# Both channels compose by the same outermost-wins rule and coexist on one dist, so
# neither silently drops the other.
sub ccflags {
  my ( $self, @args ) = @_;
  my $mode = ( @args and defined $args[0] and $args[0] =~ /\A:/ )
    ? shift @args : ':env';
  croak "Unknown ccflags mode '$mode' (expected ':env' or ':wrapper')"
    unless $mode eq ':env' or $mode eq ':wrapper';
  croak "ccflags expects a module name and flags"
    unless @args == 2 and defined $args[0] and defined $args[1];
  my ( $module, $flags ) = @args;
  my $field = $mode eq ':wrapper' ? 'ccflags_wrapper' : 'ccflags';
  $self->_record_directive( $module, $field => $flags );
}

# Route a directive into this dist's records. Mirrors store_dist_info's merge
# fold: inside a merge block the directive is recorded both in the merged
# sub-dist's own isolated view (the recursion with $merging_dist cleared) and
# folded into this (parent) dist's merged-name list; at top level it lands in
# the own-name list.
sub _record_directive {
  my ( $self, $module, $field, $value ) = @_;

  if ( my $dist = $merging_dist ) {
    my $md_info = $self->get_merged_dist_info( $dist );
    confess "Internal: no info about merged dist ${dist} found"
      unless $md_info and $md_info->isa( __PACKAGE__ );
    {
      local $merging_dist;      # undef: record in the sub-dist's own view
      $md_info->_record_directive( $module, $field, $value );
    }
    $self->_apply_directive( $module, $field, $value, 1 );
  } else {
    $self->_apply_directive( $module, $field, $value, 0 );
  }
}

# Update the record for $module and register its declaration position. Composition
# follows the one rule: a valued directive (ccflags / ccflags_wrapper) is
# outermost-wins - a build-master (own) value overrides a merged dist's; a
# no-negation directive (prepend membership, notest) is on-if-found-anywhere. The
# two ccflags channels are independent (each tracks its own from-own guard), so
# setting one never disturbs the other.
my %_valued_outermost = (
  ccflags         => 'ccflags_from_own',
  ccflags_wrapper => 'ccflags_wrapper_from_own',
);
sub _apply_directive {
  my ( $self, $module, $field, $value, $merged ) = @_;
  my $rec = $self->{directives}{ $module } ||= { module => $module };

  if ( my $own_guard = $_valued_outermost{ $field } ) {
    if ( !$merged ) {
      $rec->{ $field }     = $value;
      $rec->{ $own_guard } = 1;
    } elsif ( !$rec->{ $own_guard } ) {
      $rec->{ $field } = $value;
    }
  } elsif ( $field eq 'prepend' ) {
    # Keep the versioned spec: a later versioned prepend supersedes an earlier
    # one (the historical last-version-wins), and a bare prepend never clobbers a
    # stored version - so the pin survives regardless of declaration order or
    # which side of a merge carries it.
    my $has_version = $value ne $module;
    $rec->{prepend} = $value if $has_version or not defined $rec->{prepend};
  } elsif ( $field eq 'notest' ) {
    $rec->{notest} = 1;
  }

  push @{ $merged
    ? $self->{directive_order_merged}
    : $self->{directive_order_own} }, $module;
}

# The folded directive order: merged names (declaration order) ahead of own names
# (declaration order), deduped to the first occurrence. A dist named in both folds
# to its merged position.
sub _ordered_directive_names {
  my $self = shift;
  return _uniq(
    @{ $self->{directive_order_merged} },
    @{ $self->{directive_order_own} },
  );
}

# ($$@): phase + path, then any number of arguments for the script. The DSL
# verb mirrors this prototype, so the trailing args are reachable from a
# mistfile (`script prepare => q{x.pl}, q{--flag};`); install.pm runs each
# entry as system( $path, @args ).
sub script ($$@) {
  my ( $self, $phase, $path, @args ) = @_;
  die "Unknown phase $phase" unless exists $self->{script}{$phase};
  $self->store_dist_info( [ script => $phase ], [ $path, @args ]);
}

sub get_assertions           { my $self = shift; return @{ $self->{assert}}   }
sub get_default_perl_version { my $self = shift; return    $self->{perl}      }
sub get_dist_path            { my $self = shift; return    $self->{dist_path} }
sub get_prepended_modules {
  my $self = shift;
  return
    map  { $self->{directives}{$_}{prepend} }
    grep { defined $self->{directives}{$_}{prepend} }
    $self->_ordered_directive_names;
}

sub get_modules_not_to_test {
  my $self = shift;
  return
    grep { $self->{directives}{$_}{notest} }
    $self->_ordered_directive_names;
}

# Per-dist compiler flags, as [ module => flags ] pairs in directive order. An
# empty-string ccflags is inert (it carries no flag, but a build-master empty can
# still override a merged value back to none), so it is filtered out here - keeping
# this aligned with run_cpanm's defined-and-length gate and the directive pass.
sub get_ccflags {
  my $self = shift;
  return
    map  { [ $_ => $self->{directives}{$_}{ccflags} ] }
    grep { defined $self->{directives}{$_}{ccflags}
             and length $self->{directives}{$_}{ccflags} }
    $self->_ordered_directive_names;
}

# The :wrapper channel, as [ module => flags ] pairs in directive order. Same
# empty-is-inert filter as get_ccflags; independent of the :env channel above.
sub get_ccflags_wrapper {
  my $self = shift;
  return
    map  { [ $_ => $self->{directives}{$_}{ccflags_wrapper} ] }
    grep { defined $self->{directives}{$_}{ccflags_wrapper}
             and length $self->{directives}{$_}{ccflags_wrapper} }
    $self->_ordered_directive_names;
}


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
  my ( %version, %scheduled, %dont_test, %ccflags, %ccflags_wrapper,
       %core_satisfies, @callstack );

  # decorations keyed by bare module name
  %dont_test       = map { $_      => 1        } $self->get_modules_not_to_test;
  %ccflags         = map { $_->[0] => $_->[1]  } $self->get_ccflags;
  %ccflags_wrapper = map { $_->[0] => $_->[1]  } $self->get_ccflags_wrapper;

  # push a module on the call stack according to state vars. notest and the two
  # ccflags channels are decorators: any of them splits the build into
  # `--installdeps X` (deps, undecorated) then `X` carrying --notest and a
  # { ccflags => ..., ccflags_wrapper => ... } marker, so the flags/skip-test scope
  # to X alone and never leak onto its deps.
  my $push_module_on_stack = sub{
    my ( $module, $explicit_spec, $force ) = @_;
    return if $scheduled{ $module };
    # $force schedules a module mist cannot core-evaluate (an opaque operator
    # constraint), so a core-satisfied decision made on a different version of it
    # never silently drops it.
    return if $core_satisfies{ $module } && !$force;

    # $module is always the bare name - the key shared by every map below. The
    # emitted spec is an explicit prepend spec when one carries a version
    # constraint (the only faithful way to round-trip an operator-prefixed
    # constraint, which the ~-based %version map cannot represent), otherwise it
    # is reconstructed from %version (which still picks up a prereq's pin).
    my $mod_spec = defined $explicit_spec ? $explicit_spec
      : ( $version{ $module } ? join( q{~}, $module, $version{$module} ) : $module );

    my $notest    = $dont_test{ $module } && !$opts{'force-tests'};
    my $flags     = $ccflags{ $module };
    my $wrapflags = $ccflags_wrapper{ $module };

    if ( $notest or defined $flags or defined $wrapflags ) {
      push @callstack, [ '--installdeps', $mod_spec ];
      my @decorated = ( $mod_spec );
      unshift @decorated, '--notest' if $notest;
      my %mark;
      $mark{ccflags}         = $flags     if defined $flags;
      $mark{ccflags_wrapper} = $wrapflags if defined $wrapflags;
      unshift @decorated, \%mark if %mark;
      push @callstack, \@decorated;
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

  # filter out modules already satisfied by core for the running perl
  if ( $opts{'skip-core-satisfied'} ) {
    require Module::CoreList;
    require CPAN::Meta::Requirements;
    my $core = $Module::CoreList::version{ $] + 0 } || {};
    for my $module ( @prepended, @prereqs ) {
      my $core_ver = $core->{ $module };
      next unless defined $core_ver;
      my $want = $version{ $module };
      if ( not defined $want or not length $want ) {
        $core_satisfies{ $module } = 1;
        next;
      }
      my $accepted = eval {
        my $req = CPAN::Meta::Requirements->new;
        $req->add_string_requirement( $module, $want );
        $req->accepts_module( $module, $core_ver );
      };
      $core_satisfies{ $module } = 1 if $accepted;
    }
  }

  # Directive pass: schedule the mistfile's standing module list - its prepend /
  # notest / ccflags dists (either ccflags mode) - ahead of the bulk prereqs, in
  # declaration order (merged-before-outer), so a decorated dist installs before a
  # prereq could pull it in undecorated, and a decorated dist that depends on
  # another can be ordered first by declaring it first.
  #
  # A targeted install (skip-default-modlist) skips this whole pass and installs
  # only the named modules; their per-module decorations still apply through the
  # bulk pass below, so e.g. injecting a ccflags'd dist by name still flags it.
  unless ( $opts{'skip-default-modlist'} ) {
    for my $name ( $self->_ordered_directive_names ) {
      my $rec = $self->{directives}{ $name };
      my $has_ccflags = defined $rec->{ccflags} && length $rec->{ccflags};
      my $has_wrapper = defined $rec->{ccflags_wrapper}
                          && length $rec->{ccflags_wrapper};
      next unless defined $rec->{prepend} || $rec->{notest}
                    || $has_ccflags || $has_wrapper;

      # Schedule by the bare module name ($name = the record key), so %version,
      # %dont_test, %ccflags and %ccflags_wrapper - all keyed by bare name - line up.
      # When the prepend
      # spec carries a version constraint, pass it explicitly so it is emitted
      # verbatim; this is what lets an operator-prefixed constraint like B==2.0 keep
      # its --notest / ccflags decoration (a ~-split token would not match the bare
      # decoration key and would silently drop it). A bare prepend passes no explicit
      # spec and falls back to %version, still picking up a version pinned on a prereq.
      my $spec = ( defined $rec->{prepend} && $rec->{prepend} ne $name )
        ? $rec->{prepend} : undef;
      # A constraint whose first character after the bare name is not `~` (an
      # operator prefix: ==, >=, @, ...) is opaque to the ~-based version machinery,
      # so any core-satisfied verdict for this module was reached on a different
      # ~-version of it. Force it onto the stack and let cpanm resolve the
      # constraint (or fail loudly) rather than silently dropping the prepend.
      my $force = defined $spec && substr( $spec, length $name, 1 ) ne q{~};
      $push_module_on_stack->( $name, $spec, $force );
    }
  }

  # schedule remaining prerequisites
  $push_module_on_stack->( $_ ) for @prereqs;

  return @callstack;
}

1;
