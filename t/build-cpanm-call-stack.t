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

SKIP_PREPENDED: {
  my $dist = dist_from(
    'perl q{5.20.3}; prepend q{Pre::One}; notest q{No::Test};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'skip-prepended' => 1 }, 'Plain::Prereq' ) ],
    [ [ '--installdeps', 'No::Test' ],
      [ '--notest',      'No::Test' ],
      [ 'Plain::Prereq' ] ],
    'skip-prepended omits prepended modules from the pre-schedule pass';
}

SKIP_NOTEST_PASS_ONLY: {
  my $dist = dist_from(
    'perl q{5.20.3}; prepend q{Pre::One}; notest q{No::Test};' );
  is_deeply
    [ $dist->build_cpanm_call_stack(
        { 'skip-notest' => 1 }, 'Plain::Prereq', 'No::Test' ) ],
    [ [ 'Pre::One' ],
      [ 'Plain::Prereq' ],
      [ '--installdeps', 'No::Test' ],
      [ '--notest',      'No::Test' ] ],
    'skip-notest skips only the early notest pass; notest prereq still two-steps, ordered after plain prereqs';
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
        { 'skip-prepended' => 1 }, [ 'Plain::Prereq', 'No::Test' ] ) ],
    [ [ '--installdeps', 'No::Test' ],
      [ '--notest',      'No::Test' ],
      [ 'Plain::Prereq' ] ],
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

done_testing;
