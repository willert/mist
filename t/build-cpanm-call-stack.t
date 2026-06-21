#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use Mist::Distribution;
use Mist::Environment;

# Build a Mist::Distribution from inline mistfile DSL source. No tempfiles,
# no shared fixtures, fully in-memory and deterministic.
sub dist_from {
  my ( $source ) = @_;
  return Mist::Environment->new->parse( source => $source );
}

PLAIN_PREREQ: {
  my $dist = dist_from( 'perl q{5.20.3};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Plain::Prereq' ) ],
    [ [ 'Plain::Prereq' ] ],
    'plain tested prereq becomes a single [ spec ] entry';
}

NOTEST_TWO_STEP: {
  my $dist = dist_from( 'perl q{5.20.3}; notest q{No::Test};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'No::Test' ) ],
    [ [ '--installdeps', 'No::Test' ], [ '--notest', 'No::Test' ] ],
    'notest module becomes --installdeps then --notest, in that order';
}

NOTEST_BEFORE_PLAIN: {
  my $dist = dist_from( 'perl q{5.20.3}; notest q{Late::Notest};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Plain::A', 'Late::Notest' ) ],
    [ [ '--installdeps', 'Late::Notest' ],
      [ '--notest',      'Late::Notest' ],
      [ 'Plain::A' ] ],
    'notest modules scheduled before plain prereqs regardless of input order';
}

PREPENDED_FIRST_IN_ORDER: {
  my $dist = dist_from(
    'perl q{5.20.3}; prepend q{Pre::One}; prepend q{Pre::Two};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Plain::Prereq' ) ],
    [ [ 'Pre::One' ], [ 'Pre::Two' ], [ 'Plain::Prereq' ] ],
    'prepended modules come first, in mistfile declaration order';
}

VERSION_PIN_FROM_PREREQ: {
  my $dist = dist_from( 'perl q{5.20.3};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Mod::A~2.0', 'Mod::B' ) ],
    [ [ 'Mod::A~2.0' ], [ 'Mod::B' ] ],
    'version pin from a prereq spec flows through as Module~version';
}

VERSION_PIN_FROM_PREPEND: {
  my $dist = dist_from( 'perl q{5.20.3}; prepend q{Aaa::Bbb}, q{1.23};' );
  is_deeply
    [ $dist->build_cpanm_call_stack() ],
    [ [ 'Aaa::Bbb~1.23' ] ],
    'version pin from a prepend with version flows through as Module~version';
}

VERSION_PREPEND_SUPERSEDES_PREREQ: {
  my $dist = dist_from( 'perl q{5.20.3}; prepend q{Conf::Mod}, q{2.0};' );

  my @warnings;
  my @stack;
  {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    @stack = $dist->build_cpanm_call_stack( 'Conf::Mod~1.0' );
  }

  is_deeply
    [ @stack ],
    [ [ 'Conf::Mod~2.0' ] ],
    'prepended version supersedes a conflicting prereq version';
  ok
    ( ( grep { /Conflicting versions for Conf::Mod/ } @warnings ),
      'conflict warning emitted when prepend and prereq versions differ' );
}

SKIP_DEFAULT_MODLIST: {
  # A targeted install (skip-default-modlist, as the host sets for --bundle /
  # inject) skips the mistfile's whole standing module list - prepend, notest and
  # ccflags dists alike - and installs only the named modules. A named module that
  # is itself a notest dist still two-steps via the bulk pass (its decoration is
  # preserved); an unnamed directive'd dist (Pre::One) is not pulled in.
  my $dist = dist_from(
    'perl q{5.20.3}; prepend q{Pre::One}; notest q{No::Test};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'skip-default-modlist' => 1 }, 'Plain::Prereq', 'No::Test' ) ],
    [ [ 'Plain::Prereq' ],
      [ '--installdeps', 'No::Test' ],
      [ '--notest',      'No::Test' ] ],
    'skip-default-modlist drops the directive set; a named notest dist still two-steps, an unnamed prepend is not pulled in';
}

FORCE_TESTS: {
  my $dist = dist_from(
    'perl q{5.20.3}; prepend q{Pre::One}; notest q{No::Test};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'force-tests' => 1 }, 'Plain::Prereq', 'No::Test' ) ],
    [ [ 'Pre::One' ], [ 'No::Test' ], [ 'Plain::Prereq' ] ],
    'force-tests installs a notest module tested (single [ spec ], no two-step)';
}

DEDUP_ACROSS_INPUTS: {
  my $dist = dist_from(
    'perl q{5.20.3}; prepend q{Dup::Mod}; notest q{Dup::Mod};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Dup::Mod', 'Other' ) ],
    [ [ '--installdeps', 'Dup::Mod' ],
      [ '--notest',      'Dup::Mod' ],
      [ 'Other' ] ],
    'module in prepend+notest+prereqs scheduled once, with --notest two-step via prepended pass';
}

SKIP_CORE_SATISFIED_DROPS: {
  my $dist = dist_from( 'perl q{5.20.3};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'skip-core-satisfied' => 1 }, 'strict', 'Non::Core::Module' ) ],
    [ [ 'Non::Core::Module' ] ],
    'skip-core-satisfied drops a core module with no version req, keeps non-core';
}

SKIP_CORE_SATISFIED_OFF: {
  my $dist = dist_from( 'perl q{5.20.3};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'strict', 'Non::Core::Module' ) ],
    [ [ 'strict' ], [ 'Non::Core::Module' ] ],
    'without the flag a core module is scheduled normally (control)';
}

SKIP_CORE_SATISFIED_UNMET_VERSION: {
  my $dist = dist_from( 'perl q{5.20.3};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'skip-core-satisfied' => 1 }, 'strict~999' ) ],
    [ [ 'strict~999' ] ],
    'skip-core-satisfied keeps a core module whose version core cannot meet';
}

PREREQS_AS_ARRAYREF: {
  my $dist = dist_from( 'perl q{5.20.3}; prepend q{Pre::One};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( [ 'Plain::Prereq' ] ) ],
    [ [ 'Pre::One' ], [ 'Plain::Prereq' ] ],
    'prereqs may be passed as a single arrayref';
}

OPTS_PLUS_ARRAYREF_PREREQS: {
  my $dist = dist_from(
    'perl q{5.20.3}; prepend q{Pre::One}; notest q{No::Test};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'skip-default-modlist' => 1 }, [ 'Plain::Prereq', 'No::Test' ] ) ],
    [ [ 'Plain::Prereq' ],
      [ '--installdeps', 'No::Test' ],
      [ '--notest',      'No::Test' ] ],
    'an opts hashref combines with an arrayref prereq list';
}

AS_CODE_ROUND_TRIP: {
  my $src =
    'perl q{5.20.3}; prepend q{Aaa::Bbb}, q{1.23}; notest q{Ccc::Ddd};';
  my $code = Mist::Environment->new->as_code(
    source => $src, package => 'TDist0001' );

  my $err;
  {
    local $@;
    eval $code; ## no critic
    $err = $@;
  }
  is $err, '', 'as_code round-trip evaluates without error';

  my $dist = TDist0001->distinfo;
  isa_ok $dist, 'Mist::Distribution', 'distinfo accessor returns the dist';

  is_deeply
    [ $dist->get_prepended_modules ], [ 'Aaa::Bbb~1.23' ],
    'prepended version pin survives the as_code round-trip';
  is_deeply
    [ $dist->get_modules_not_to_test ], [ 'Ccc::Ddd' ],
    'notest module survives the as_code round-trip';

  is_deeply
    [ $dist->build_cpanm_call_stack( 'Eee::Fff' ) ],
    [ [ 'Aaa::Bbb~1.23' ],
      [ '--installdeps', 'Ccc::Ddd' ],
      [ '--notest',      'Ccc::Ddd' ],
      [ 'Eee::Fff' ] ],
    'call-stack from the as_code-built dist matches';
}

EMPTY_PREREQS: {
  my $dist = dist_from( 'perl q{5.20.3}; prepend q{P1}; notest q{N1};' );
  is_deeply
    [ $dist->build_cpanm_call_stack() ],
    [ [ 'P1' ],
      [ '--installdeps', 'N1' ],
      [ '--notest',      'N1' ] ],
    'an empty prereq list still schedules prepended and notest modules';
}

NOTEST_VERSION_PIN_TWO_STEP: {
  # notest() takes only a module name; the version pin arrives via the prereq
  # spec and must survive into both two-step entries. Guards that lines
  # 214-215 emit $mod_spec (Mod~ver), not the bare $module.
  my $dist = dist_from( 'perl q{5.20.3}; notest q{Pinned::Notest};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Pinned::Notest~2.5' ) ],
    [ [ '--installdeps', 'Pinned::Notest~2.5' ],
      [ '--notest',      'Pinned::Notest~2.5' ] ],
    'a versioned notest module two-steps with the version in both entries';
}

NOTEST_DECLARATION_ORDER: {
  # The notest pass must iterate mistfile declaration order, not hash order.
  # A regression to keys-on-%dont_test would scramble this. Z is declared
  # before A precisely so hash order (which would tend to sort A first under
  # many hashing schemes) cannot accidentally match.
  my $dist = dist_from(
    'perl q{5.20.3}; notest q{Z::Last}; notest q{A::First};' );
  is_deeply
    [ $dist->build_cpanm_call_stack() ],
    [ [ '--installdeps', 'Z::Last' ],
      [ '--notest',      'Z::Last' ],
      [ '--installdeps', 'A::First' ],
      [ '--notest',      'A::First' ] ],
    'notest modules keep mistfile declaration order (Z before A), not hash order';
}

PREPEND_PREREQ_EQUAL_VERSIONS_NO_WARN: {
  # Negative case of the line-236 conflict guard: equal versions in prepend
  # and prereq must NOT warn.
  my $dist = dist_from( 'perl q{5.20.3}; prepend q{Same::Ver}, q{1.0};' );

  my @warnings;
  my @stack;
  {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    @stack = $dist->build_cpanm_call_stack( 'Same::Ver~1.0' );
  }

  is_deeply
    [ @stack ],
    [ [ 'Same::Ver~1.0' ] ],
    'matching prepend and prereq versions resolve to a single pinned entry';
  is_deeply
    [ grep { /Conflicting versions/ } @warnings ],
    [],
    'no conflict warning when prepend and prereq versions are equal';
}

DUPLICATE_PREREQ_DEDUP: {
  # The same module appearing twice in the prereq list must schedule once.
  my $dist = dist_from( 'perl q{5.20.3};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Twice~1.0', 'Twice~1.0' ) ],
    [ [ 'Twice~1.0' ] ],
    'a module listed twice in the prereq list is scheduled only once';
}

FORCE_TESTS_VERSIONED_NOTEST: {
  # force-tests collapses a notest module to the single-entry (tested) branch;
  # the version pin must still survive that branch.
  my $dist = dist_from( 'perl q{5.20.3}; notest q{Forced::Notest};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'force-tests' => 1 }, 'Forced::Notest~3.0' ) ],
    [ [ 'Forced::Notest~3.0' ] ],
    'force-tests on a versioned notest module yields a single versioned entry';
}

# --- ccflags --------------------------------------------------------------

CCFLAGS_IMPLIES_PREPEND_SPLIT: {
  # ccflags scopes a compiler flag to a named build, so it implies prepend: the
  # dist gets its own installdeps-split (deps build undecorated) and its own
  # call carries a { ccflags => ... } marker, scheduled ahead of the prereqs.
  my $dist = dist_from( 'perl q{5.20.3}; ccflags q{Bit::Vector} => q{-std=gnu17};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Other' ) ],
    [ [ '--installdeps', 'Bit::Vector' ],
      [ { ccflags => '-std=gnu17' }, 'Bit::Vector' ],
      [ 'Other' ] ],
    'ccflags implies prepend: installdeps-split + marker on the dist call, ahead of prereqs';
}

CCFLAGS_AND_NOTEST_ONE_SPLIT: {
  # A dist with BOTH notest and ccflags gets a single installdeps-split; the
  # dist call carries both --notest and the ccflags marker, not two splits.
  my $dist = dist_from( 'perl q{5.20.3}; ccflags q{X} => q{-std=gnu17}; notest q{X};' );
  is_deeply
    [ $dist->build_cpanm_call_stack() ],
    [ [ '--installdeps', 'X' ],
      [ { ccflags => '-std=gnu17' }, '--notest', 'X' ] ],
    'notest + ccflags on one dist share a single installdeps-split carrying both decorators';
}

CCFLAGS_DECLARATION_ORDER: {
  # prepend / ccflags / notest schedule in mistfile declaration order, each
  # ahead of the bulk prereqs. The notest dist (Y) is scheduled by the directive
  # pass, so the later bulk prereq Y is already satisfied.
  my $dist = dist_from(
    'perl q{5.20.3}; prepend q{P}; ccflags q{X} => q{-O0}; notest q{Y};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Q', 'Y' ) ],
    [ [ 'P' ],
      [ '--installdeps', 'X' ],
      [ { ccflags => '-O0' }, 'X' ],
      [ '--installdeps', 'Y' ],
      [ '--notest', 'Y' ],
      [ 'Q' ] ],
    'prepend, ccflags and notest schedule in declaration order ahead of bulk prereqs';
}

CCFLAGS_TARGETED_NAMED: {
  # On a targeted install (skip-default-modlist, as the host sets for --bundle /
  # inject), the directive pass is skipped, but a ccflags dist named as a custom
  # module is still decorated by the bulk pass.
  my $dist = dist_from( 'perl q{5.20.3}; ccflags q{X} => q{-std=gnu17};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'skip-default-modlist' => 1 }, 'X' ) ],
    [ [ '--installdeps', 'X' ],
      [ { ccflags => '-std=gnu17' }, 'X' ] ],
    'a ccflags dist named on a targeted install is still decorated via the bulk pass';
}

CCFLAGS_TARGETED_UNRELATED_NOT_PULLED: {
  # The flip side: an unrelated ccflags dist is not dragged into a targeted install.
  my $dist = dist_from( 'perl q{5.20.3}; ccflags q{X} => q{-std=gnu17};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'skip-default-modlist' => 1 }, 'Other' ) ],
    [ [ 'Other' ] ],
    'an unrelated ccflags dist is not pulled into a targeted install';
}

CCFLAGS_FORCE_TESTS_KEEPS_SPLIT: {
  # force-tests drops --notest, but the ccflags split must stay so the flag can
  # still scope to the dist's own build.
  my $dist = dist_from( 'perl q{5.20.3}; ccflags q{X} => q{-g}; notest q{X};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( { 'force-tests' => 1 } ) ],
    [ [ '--installdeps', 'X' ],
      [ { ccflags => '-g' }, 'X' ] ],
    'force-tests removes --notest but keeps the ccflags split (no --notest, marker stays)';
}

CCFLAGS_VERSION_PIN_TWO_STEP: {
  # ccflags() takes only (module, flags); a version pin arrives via the prereq
  # spec and must survive into BOTH the installdeps call and the marked call.
  my $dist = dist_from( 'perl q{5.20.3}; ccflags q{Bit::Vector} => q{-std=gnu17};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'Bit::Vector~7.4' ) ],
    [ [ '--installdeps', 'Bit::Vector~7.4' ],
      [ { ccflags => '-std=gnu17' }, 'Bit::Vector~7.4' ] ],
    'a versioned ccflags dist two-steps with the version pin in both entries';
}

OPERATOR_VERSION_PREPEND_DECORATES: {
  # An operator-prefixed version constraint (==, >=, @, ...) on a prepend has no
  # ~, so a ~-split scheduling token would not match the bare decoration key and
  # would silently drop --notest / ccflags. Scheduling by bare name + emitting the
  # spec verbatim keeps both the constraint and the decoration.
  is_deeply
    [ dist_from( 'perl q{5.20.3}; prepend q{B} => q{==2.0}; notest q{B};' )
        ->build_cpanm_call_stack() ],
    [ [ '--installdeps', 'B==2.0' ], [ '--notest', 'B==2.0' ] ],
    'operator-version (==) prepend keeps its --notest decoration';
  is_deeply
    [ dist_from( 'perl q{5.20.3}; prepend q{C} => q{>=3.0}; ccflags q{C} => q{-g};' )
        ->build_cpanm_call_stack() ],
    [ [ '--installdeps', 'C>=3.0' ], [ { ccflags => '-g' }, 'C>=3.0' ] ],
    'operator-version (>=) prepend keeps its ccflags decoration';
  is_deeply
    [ dist_from( 'perl q{5.20.3}; prepend q{B} => q{==2.0};' )
        ->build_cpanm_call_stack( 'Other' ) ],
    [ [ 'B==2.0' ], [ 'Other' ] ],
    'an undecorated operator-version prepend still emits the spec verbatim, ahead of prereqs';
}

OPERATOR_VERSION_PREPEND_NOT_CORE_DROPPED: {
  # mist's ~-based core check cannot evaluate an operator constraint, so it must
  # not let a core-satisfied verdict reached on a different ~-version of the same
  # module silently drop the prepend. strict is core and satisfies the ~1.0 prereq,
  # but the ==999 pin is opaque, so it is scheduled (cpanm resolves it or fails
  # loudly), not dropped.
  is_deeply
    [ dist_from( 'perl q{5.20.3}; prepend q{strict} => q{==999};' )
        ->build_cpanm_call_stack( { 'skip-core-satisfied' => 1 }, 'strict~1.0' ) ],
    [ [ 'strict==999' ] ],
    'an operator-pinned prepend mist cannot evaluate is scheduled, not core-skipped';

  # Control: the guard is operator-only - a ~-version prepend mist *can* evaluate is
  # still core-skipped when core meets it.
  is_deeply
    [ dist_from( 'perl q{5.20.3}; prepend q{strict} => q{1.0};' )
        ->build_cpanm_call_stack( { 'skip-core-satisfied' => 1 } ) ],
    [],
    'a ~-version prepend mist can evaluate is still core-skipped (guard is operator-only)';
}

NOTEST_BEFORE_PREPEND: {
  # The one ordering case where the unified declaration-order pass deliberately
  # diverges from the old two-phase (all-prepends-then-all-notests) scheduler: a
  # notest dist declared BEFORE a distinct prepend dist now schedules first, in
  # declaration order. The old scheduler would have emitted the prepend first.
  my $dist = dist_from(
    'perl q{5.20.3}; notest q{A::Notest}; prepend q{B::Prepend};' );
  is_deeply
    [ $dist->build_cpanm_call_stack( 'C::Prereq' ) ],
    [ [ '--installdeps', 'A::Notest' ],
      [ '--notest', 'A::Notest' ],
      [ 'B::Prepend' ],
      [ 'C::Prereq' ] ],
    'notest declared before a distinct prepend schedules first (declaration order)';
}

done_testing;
