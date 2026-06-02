#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Spec;
use Cwd ();

use Mist::Distribution;
use Mist::Environment;

# Parse mistfile DSL source from an in-memory string (no fixtures, no tempfiles).
sub parse_source {
  my ($src) = @_;
  return Mist::Environment->new->parse( source => $src );
}

# Parse source that is expected to die; return the error message.
# Mist::Environment::parse builds its die string from $self->{file}, which is
# undef when we parse from source, so it emits an "uninitialized value ...
# Environment.pm line 87" warning. Suppress exactly that warning so prove
# output stays clean. A single combined /.../ regex does not match reliably,
# so test the two halves separately.
sub parse_expect_die {
  my ($src) = @_;
  my $err;
  {
    local $SIG{__WARN__} = sub {
      my $w = shift;
      return if $w =~ /uninitialized value/ && $w =~ /Environment\.pm/;
      warn $w;
    };
    local $@;
    eval { parse_source($src); 1 };
    $err = $@;
  }
  return $err;
}

# --- perl verb -------------------------------------------------------------

DEFAULT_PERL: {
  my $dist = parse_source('perl q{5.20.3};');
  is $dist->get_default_perl_version, '5.20.3', 'perl verb sets default perl version';
}

PERL_SET_TWICE: {
  my $err = parse_expect_die('perl q{5.20.3}; perl q{5.30.0};');
  like $err, qr/set before/, 'declaring perl twice croaks /set before/';
  like $err, qr/Perl version has been set/,
    'perl-twice croak carries the full "Perl version has been set" message';
}

# --- prepend verb ----------------------------------------------------------

PREPEND_PLAIN: {
  my $dist = parse_source('prepend q{Foo::Bar};');
  is_deeply [ $dist->get_prepended_modules ], ['Foo::Bar'],
    'prepend without version stores bare name';
}

PREPEND_VERSIONED: {
  my $dist = parse_source('prepend q{Baz::Qux} => q{1.23};');
  is_deeply [ $dist->get_prepended_modules ], ['Baz::Qux~1.23'],
    'bare version normalized with leading ~';
}

PREPEND_VERSION_OPERATORS: {
  my $dist = parse_source(<<'MIST');
prepend q{A} => q{1.0};
prepend q{B} => q{==2.0};
prepend q{C} => q{>=3.0};
prepend q{D} => q{~4.0};
prepend q{E} => q{@5.0};
MIST
  is_deeply [ $dist->get_prepended_modules ],
    [ 'A~1.0', 'B==2.0', 'C>=3.0', 'D~4.0', 'E@5.0' ],
    'versions starting with =@><~ left untouched, bare gets leading ~';
}

PREPEND_FALSY_VERSION: {
  # Foot-gun pin: prepend gates on `if $version`, so a defined-but-falsy
  # version of '0' is silently dropped -- you get bare 'Foo', NOT 'Foo~0'.
  # (Distribution.pm:122-123 both guard on truthiness, not definedness.)
  my $dist = parse_source('prepend q{Foo}, q{0};');
  is_deeply [ $dist->get_prepended_modules ], ['Foo'],
    q{prepend with falsy version '0' silently drops the version (bare 'Foo')};
}

PREPEND_ORDER: {
  my $dist = parse_source('prepend q{A}; prepend q{B}; prepend q{C};');
  is_deeply [ $dist->get_prepended_modules ], [ 'A', 'B', 'C' ],
    'plain prepends keep declaration order';
}

PREPEND_DEDUP: {
  my $dist = parse_source('prepend q{Foo}; prepend q{Bar}; prepend q{Foo};');
  is_deeply [ $dist->get_prepended_modules ], [ 'Foo', 'Bar' ],
    'duplicate prepend uniq-ed, first occurrence kept';
}

# --- notest verb -----------------------------------------------------------

NOTEST: {
  my $dist = parse_source('notest q{Term::ReadKey};');
  is_deeply [ $dist->get_modules_not_to_test ], ['Term::ReadKey'],
    'notest stored in get_modules_not_to_test';
}

NOTEST_DEDUP_ORDER: {
  my $dist = parse_source('notest q{X}; notest q{X}; notest q{Y};');
  is_deeply [ $dist->get_modules_not_to_test ], [ 'X', 'Y' ],
    'notest dedups and keeps declaration order';
}

# --- assert verb -----------------------------------------------------------

ASSERT: {
  my $dist = parse_source('assert { 42 };');
  my @assertions = $dist->get_assertions;
  is scalar(@assertions), 1, 'one assertion stored';
  is ref($assertions[0]), 'CODE', 'assertion is a coderef';
  is $assertions[0]->(), 42, 'assertion body is the block (returns 42)';
}

ASSERT_MULTIPLE: {
  my $dist = parse_source('assert { 1 }; assert { 2 };');
  is scalar($dist->get_assertions), 2, 'multiple assertions accumulate';
}

ASSERT_NON_CODEREF: {
  # assert() requires a block: the (&@) prototype (mirrored onto the DSL verb
  # by Mist::Environment::_bind) rejects any non-block first argument at compile
  # time. That prototype is the sole guard - the redundant runtime CODE-ref
  # croak that used to sit in the body was unreachable from the DSL and has been
  # removed.
  my $err = parse_expect_die('assert q{not a coderef};');
  like $err, qr/must be block or sub \{\}/,
    'assert with a non-coderef argument dies (prototype rejects it at compile time)';
}

# --- script verb -----------------------------------------------------------

SCRIPT_PHASES: {
  my $dist = parse_source(
    'script prepare => q{bin/pre.pl}; script finalize => q{bin/post.pl};'
  );
  is_deeply [ $dist->get_scripts('prepare') ], [ ['bin/pre.pl'] ],
    'prepare-phase script stored as arrayref';
  is_deeply [ $dist->get_scripts('finalize') ], [ ['bin/post.pl'] ],
    'finalize-phase script stored as arrayref';
}

SCRIPT_EMPTY_PHASE: {
  my $dist = parse_source('script prepare => q{x.pl};');
  is_deeply [ $dist->get_scripts('finalize') ], [],
    'undeclared phase yields empty list';
}

SCRIPT_UNKNOWN_PHASE: {
  my $err = parse_expect_die('script bogus => q{x.pl};');
  like $err, qr/Unknown phase/, 'unknown script phase dies /Unknown phase/';
}

SCRIPT_NOT_DEDUPED: {
  my $dist = parse_source(
    'script prepare => q{a.pl}; script prepare => q{a.pl}; script prepare => q{b.pl};'
  );
  is_deeply [ $dist->get_scripts('prepare') ],
    [ ['a.pl'], ['a.pl'], ['b.pl'] ],
    'identical script entries are NOT deduped (distinct arrayrefs vs _uniq)';
}

SCRIPT_SINGLE_PATH_SUPPORTED: {
  # The single-path form (no trailing args).
  my $dist = parse_source('script prepare => q{only.pl};');
  is_deeply [ $dist->get_scripts('prepare') ], [ ['only.pl'] ],
    'script with a single path is stored as a one-element arrayref';
}

SCRIPT_EXTRA_ARGS: {
  # script accepts trailing arguments after the path: the ($$@) prototype lets
  # the DSL pass them and the body stores [ $path, @args ] (install.pm runs each
  # entry as system( $path, @args )).
  my $dist = parse_source('script prepare => q{x.pl}, q{--flag}, q{--more};');
  is_deeply [ $dist->get_scripts('prepare') ],
    [ [ 'x.pl', '--flag', '--more' ] ],
    'script stores trailing args alongside the path';
}

# --- dist_path verb --------------------------------------------------------

DISTPATH_OUTSIDE_MERGE: {
  my $dist = parse_source('dist_path q{../x};');
  is $dist->get_dist_path, undef, 'dist_path outside a merge is silently ignored';
}

DISTPATH_TWICE_IN_MERGE: {
  my $err = parse_expect_die(
    'merge D => sub { dist_path q{a}; dist_path q{b} };'
  );
  like $err, qr/set before/, 'dist_path set twice in one merge croaks /set before/';
}

# --- merge verb ------------------------------------------------------------

my $MERGE_SRC = <<'MIST';
perl q{5.14.2};
prepend q{An::Module};
merge 'Other::Dist' => sub {
  perl q{5.10.0};
  dist_path q{../other};
  assert { 1 };
  prepend q{Another::Module};
  notest q{Some::Test};
};
MIST

MERGE_FOLDS_INTO_PARENT: {
  my $dist = parse_source($MERGE_SRC);

  is_deeply [ $dist->get_merged_dists ], ['Other::Dist'],
    'merge registers the sub-dist name';
  is_deeply [ $dist->get_prepended_modules ],
    [ 'Another::Module', 'An::Module' ],
    'merge-body prepend folds to FRONT of parent list';
  is_deeply [ $dist->get_modules_not_to_test ], ['Some::Test'],
    'merge-body notest folds into parent';
  is scalar($dist->get_assertions), 1, 'merge-body assertion folds into parent';
  is $dist->get_default_perl_version, '5.14.2',
    'perl inside merge is ignored; parent default perl unchanged';
}

MERGE_SUBDIST_INFO: {
  my $dist = parse_source($MERGE_SRC);
  my $sub  = $dist->get_merged_dist_info('Other::Dist');

  isa_ok $sub, 'Mist::Distribution', 'sub-dist info';
  is_deeply [ $sub->get_prepended_modules ], ['Another::Module'],
    'sub-dist holds only its own prepend';
  is_deeply [ $sub->get_modules_not_to_test ], ['Some::Test'],
    'sub-dist holds only its own notest';
  is scalar($sub->get_assertions), 1, 'sub-dist holds its own assertion';
  is $sub->get_default_perl_version, undef,
    'perl inside merge is ignored even for the sub-dist';
  is $sub->get_dist_path, '../other', 'dist_path sets the sub-dist path';
  is $dist->get_relative_merge_path('Other::Dist'), '../other',
    'get_relative_merge_path returns sub-dist dist_path';
}

MERGE_MULTI_PREPEND_ORDER: {
  my $dist = parse_source(<<'MIST');
prepend q{P1};
merge 'Sub' => sub {
  prepend q{M1};
  prepend q{M2};
  prepend q{M3};
};
MIST
  is_deeply [ $dist->get_prepended_modules ],
    [ 'M3', 'M2', 'M1', 'P1' ],
    'unshift: merge-body prepends reversed and ahead of parent entries';
  my $sub = $dist->get_merged_dist_info('Sub');
  is_deeply [ $sub->get_prepended_modules ], [ 'M1', 'M2', 'M3' ],
    'sub-dist keeps declaration order';
}

MERGE_SHARED_MODULE_DEDUP: {
  my $dist = parse_source(<<'MIST');
prepend q{Shared};
prepend q{ParentOnly};
merge 'Sub' => sub {
  prepend q{Shared};
  prepend q{ChildOnly};
};
MIST
  is_deeply [ $dist->get_prepended_modules ],
    [ 'ChildOnly', 'Shared', 'ParentOnly' ],
    'module shared by parent and merge dedups to first (front) position';
}

MERGE_UNKNOWN_DIST_INFO: {
  my $dist = parse_source('prepend q{X};');
  is $dist->get_merged_dist_info('Nope'), undef,
    'get_merged_dist_info returns undef for unknown dist';
}

# --- nested merge ----------------------------------------------------------

MERGE_NESTED: {
  # A merge body that itself contains a merge. The inner merge runs while
  # $merging_dist is already set, so it hits the reorder branch at
  # Distribution.pm:74-81 (only reachable for an already-in-progress merge).
  my $dist = parse_source(<<'MIST');
prepend q{P};
merge Outer => sub {
  prepend q{O1};
  merge Inner => sub {
    prepend q{I1};
  };
  prepend q{O2};
};
MIST

  # Both sub-dists registered. The inner dist is unshifted ahead of the
  # currently-merging outer dist by the reorder branch.
  is_deeply [ $dist->get_merged_dists ], [ 'Inner', 'Outer' ],
    'nested merge: both sub-dists registered, inner sequenced before outer';

  my $outer = $dist->get_merged_dist_info('Outer');
  my $inner = $dist->get_merged_dist_info('Inner');
  isa_ok $outer, 'Mist::Distribution', 'outer sub-dist';
  isa_ok $inner, 'Mist::Distribution', 'inner sub-dist';

  is_deeply [ $outer->get_prepended_modules ], [ 'O1', 'O2' ],
    'outer sub-dist holds only its own prepends';
  is_deeply [ $inner->get_prepended_modules ], [ 'I1' ],
    'inner sub-dist holds only its own prepend';

  # Parent receives every prepend, inner-most folded furthest to the front.
  is_deeply [ $dist->get_prepended_modules ],
    [ 'O2', 'I1', 'O1', 'P' ],
    'nested merge: all prepends fold into parent (unshift order)';
}

MERGE_NESTED_REORDER_LOOP: {
  # A sibling merge (A) is already registered before the nesting merge, so
  # the while-loop inside the reorder branch (Distribution.pm:77-79) actually
  # iterates past A to find the in-progress Outer. Inner is then unshifted to
  # the very front, A and Outer keep their relative order.
  my $dist = parse_source(<<'MIST');
merge A => sub { prepend q{A1}; };
merge Outer => sub {
  prepend q{O1};
  merge Inner => sub { prepend q{I1}; };
};
MIST
  is_deeply [ $dist->get_merged_dists ], [ 'Inner', 'A', 'Outer' ],
    'reorder branch loop walks past a prior sibling to seat the nested dist';
}

# --- two sibling merge blocks ----------------------------------------------

MERGE_TWO_SIBLINGS: {
  my $dist = parse_source(<<'MIST');
prepend q{P};
merge First  => sub { prepend q{F1}; notest q{Ft}; };
merge Second => sub { prepend q{S1}; notest q{St}; };
MIST

  # Both top-level merges -> push order, no reorder branch involved.
  is_deeply [ $dist->get_merged_dists ], [ 'First', 'Second' ],
    'two sibling merges keep declaration order';

  # Each sub-dist holds only its own entries.
  my $first  = $dist->get_merged_dist_info('First');
  my $second = $dist->get_merged_dist_info('Second');
  is_deeply [ $first->get_prepended_modules ],  [ 'F1' ], 'First sub-dist isolated prepend';
  is_deeply [ $first->get_modules_not_to_test ],[ 'Ft' ], 'First sub-dist isolated notest';
  is_deeply [ $second->get_prepended_modules ], [ 'S1' ], 'Second sub-dist isolated prepend';
  is_deeply [ $second->get_modules_not_to_test ],[ 'St' ],'Second sub-dist isolated notest';

  # Parent receives both sets (each merge unshifts its own).
  is_deeply [ $dist->get_prepended_modules ], [ 'S1', 'F1', 'P' ],
    'parent receives both sibling prepends, latest merge furthest front';
  is_deeply [ $dist->get_modules_not_to_test ], [ 'St', 'Ft' ],
    'parent receives both sibling notests';
}

# --- merge path accessors --------------------------------------------------

MERGE_PATHS: {
  my $dist = parse_source(<<'MIST');
merge q{With::Path} => sub { dist_path q{../wp}; prepend q{W1}; };
merge q{No::Path}   => sub { prepend q{N1}; };
MIST

  # relative path = the sub-dist's declared dist_path
  is $dist->get_relative_merge_path('With::Path'), '../wp',
    'get_relative_merge_path returns the declared dist_path';

  # merged dist with NO dist_path -> undef (sub-dist exists, dist_path undef)
  is $dist->get_relative_merge_path('No::Path'), undef,
    'get_relative_merge_path is undef when the merged dist has no dist_path';

  # unknown dist -> undef (early return, before touching dist_path)
  is $dist->get_relative_merge_path('Nope'), undef,
    'get_relative_merge_path is undef for an unknown dist';

  # default path is derived from cwd, updir, and lc(dist with :: -> -),
  # independent of any declared dist_path. Compute the expectation from the
  # live cwd so the test is location-independent.
  my $expect_default =
    File::Spec->catdir( Cwd::cwd(), File::Spec->updir, 'no-path' );
  is $dist->get_default_merge_path('No::Path'), $expect_default,
    'get_default_merge_path derives <cwd>/../<lc dashed-name>';
  is $dist->get_default_merge_path('With::Path'),
    File::Spec->catdir( Cwd::cwd(), File::Spec->updir, 'with-path' ),
    'get_default_merge_path ignores the declared dist_path';

  # unknown dist -> undef
  is $dist->get_default_merge_path('Nope'), undef,
    'get_default_merge_path is undef for an unknown dist';
}

# --- whole-distribution invariants -----------------------------------------

EMPTY_SOURCE: {
  my $dist = parse_source('');
  isa_ok $dist, 'Mist::Distribution', 'empty source';
  is $dist->get_default_perl_version, undef, 'empty: perl undef';
  is_deeply [ $dist->get_prepended_modules ], [], 'empty: no prepends';
  is_deeply [ $dist->get_modules_not_to_test ], [], 'empty: no notest';
  is_deeply [ $dist->get_assertions ], [], 'empty: no assertions';
  is_deeply [ $dist->get_merged_dists ], [], 'empty: no merged dists';
}

PARSE_ISOLATION: {
  my $a = parse_source('prepend q{AAA};');
  my $b = parse_source('prepend q{BBB};');
  is_deeply [ $a->get_prepended_modules ], ['AAA'], 'first parse isolated';
  is_deeply [ $b->get_prepended_modules ], ['BBB'], 'second parse isolated';
}

# --- as_code round-trip ----------------------------------------------------

AS_CODE_ROUNDTRIP: {
  my $src  = 'perl q{5.20.3}; prepend q{Foo::Bar}; notest q{Term::ReadKey};';
  my $code = Mist::Environment->new->as_code( source => $src, package => 'TDist0001' );
  my $ok   = eval "$code; 1";
  ok $ok, 'as_code-generated code compiles and runs' or diag $@;

  my $dist = TDist0001->distinfo;
  isa_ok $dist, 'Mist::Distribution', 'distinfo()';
  is $dist->get_default_perl_version, '5.20.3', 'round-trip: perl';
  is_deeply [ $dist->get_prepended_modules ], ['Foo::Bar'], 'round-trip: prepend';
  is_deeply [ $dist->get_modules_not_to_test ], ['Term::ReadKey'], 'round-trip: notest';
}

# --- build_cpanm_call_stack ------------------------------------------------

CALLSTACK_BASIC: {
  my $dist = parse_source(<<'MIST');
prepend q{First};
prepend q{Second} => q{1.5};
notest q{NoTest::Mod};
MIST
  my @stack = $dist->build_cpanm_call_stack( 'Extra::Prereq', 'NoTest::Mod' );
  is_deeply \@stack, [
    ['First'],
    ['Second~1.5'],
    ['--installdeps', 'NoTest::Mod'],
    ['--notest', 'NoTest::Mod'],
    ['Extra::Prereq'],
  ], 'call stack: prepends, then notest installdeps+notest pair, then prereqs';
}

CALLSTACK_SKIP_PREPENDED: {
  my $dist = parse_source('prepend q{Pre1};');
  my @stack = $dist->build_cpanm_call_stack(
    { 'skip-prepended' => 1 }, ['RealPrereq'] );
  is_deeply \@stack, [ ['RealPrereq'] ],
    'skip-prepended opt omits prepended modules';
}

done_testing;
