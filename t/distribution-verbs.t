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

PREPEND_VERSION_SURVIVES_BARE: {
  # One record per dist must not let a bare prepend drop a version pin declared
  # on the same module. The versioned spec wins regardless of declaration order
  # (and a later version supersedes an earlier one) - the merge-triggerable case
  # is a parent bare prepend + a merged sub-dist version pin, or vice versa.
  is_deeply [ parse_source('prepend q{Foo}; prepend q{Foo} => q{1.0};')
              ->get_prepended_modules ], [ 'Foo~1.0' ],
    'bare-then-versioned keeps the version (~1.0), not the bare spec';
  is_deeply [ parse_source('prepend q{Foo} => q{1.0}; prepend q{Foo};')
              ->get_prepended_modules ], [ 'Foo~1.0' ],
    'versioned-then-bare keeps the version (order-independent)';
  is_deeply [ parse_source('prepend q{M} => q{9.9}; prepend q{M} => q{1.1};')
              ->get_prepended_modules ], [ 'M~1.1' ],
    'two versioned prepends of one module: the later declaration wins';
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

# --- ccflags verb ----------------------------------------------------------

CCFLAGS_BASIC: {
  my $dist = parse_source('ccflags q{Bit::Vector} => q{-std=gnu17};');
  is_deeply [ $dist->get_ccflags ], [ [ 'Bit::Vector', '-std=gnu17' ] ],
    'ccflags stored as [ module => flags ] in get_ccflags';
  # ccflags implies prepend *membership* (own call at declared position via the
  # call stack) but is not an explicit prepend spec, so get_prepended_modules
  # stays empty - the spec/version list is unaffected.
  is_deeply [ $dist->get_prepended_modules ], [],
    'ccflags does not add a prepend spec (membership is realised by the call stack)';
}

CCFLAGS_LAST_VALUE_AT_ONE_LEVEL: {
  # No merge: a second ccflags for the same dist at the same level wins (last
  # write at a level is the author's latest intent); dedup keeps one record.
  my $dist = parse_source('ccflags q{M} => q{-a}; ccflags q{M} => q{-b};');
  is_deeply [ $dist->get_ccflags ], [ [ 'M', '-b' ] ],
    'a later ccflags at the same level overrides an earlier one for the same dist';
}

CCFLAGS_OUTERMOST_WINS: {
  # Composition: a build-master (outermost) ccflags overrides a merged dist's.
  my $dist = parse_source(
    'ccflags q{M} => q{-OUTER}; merge D => sub { ccflags q{M} => q{-INNER}; };' );
  is_deeply [ $dist->get_ccflags ], [ [ 'M', '-OUTER' ] ],
    'build-master ccflags overrides a merged dist (outermost wins)';

  # ...and order-independent: outermost wins even when declared after the merge.
  my $after = parse_source(
    'merge D => sub { ccflags q{M} => q{-INNER}; }; ccflags q{M} => q{-OUTER};' );
  is_deeply [ $after->get_ccflags ], [ [ 'M', '-OUTER' ] ],
    'outermost ccflags wins regardless of declaration order vs the merge';
}

CCFLAGS_MERGED_ONLY_APPLIES: {
  # A merged dist's ccflags applies when the build-master sets none.
  my $dist = parse_source('merge D => sub { ccflags q{M} => q{-INNER}; };');
  is_deeply [ $dist->get_ccflags ], [ [ 'M', '-INNER' ] ],
    'a merged dist ccflags applies when the build-master is silent';

  my $sub = $dist->get_merged_dist_info('D');
  is_deeply [ $sub->get_ccflags ], [ [ 'M', '-INNER' ] ],
    'sub-dist holds its own ccflags in isolation';
}

CCFLAGS_MERGED_VS_MERGED: {
  # When two merge blocks set ccflags for the same module and the build-master
  # sets none, neither is the outermost layer, so "outermost wins" does not
  # apply: the later-declared merge wins (FIFO last-write), and it is therefore
  # order-dependent - unlike own-vs-merged. Pinned so the merged-vs-merged path
  # is an explicit decision, not emergent behaviour.
  is_deeply [ parse_source(
      'merge A => sub { ccflags q{M} => q{-AAA}; };'
    . 'merge B => sub { ccflags q{M} => q{-BBB}; };' )->get_ccflags ],
    [ [ 'M', '-BBB' ] ],
    'two merged dists on one module: the later-declared merge wins';
  is_deeply [ parse_source(
      'merge B => sub { ccflags q{M} => q{-BBB}; };'
    . 'merge A => sub { ccflags q{M} => q{-AAA}; };' )->get_ccflags ],
    [ [ 'M', '-AAA' ] ],
    'merged-vs-merged is order-dependent (reversed declaration flips the winner)';
}

CCFLAGS_EMPTY_IS_INERT: {
  # An empty-string ccflags carries no flag: get_ccflags filters it out, so it
  # neither decorates a build nor forces an own call (and a build-master empty
  # can override a merged value back to none).
  is_deeply [ parse_source('ccflags q{X} => q{};')->get_ccflags ], [],
    'empty ccflags is filtered from get_ccflags';
  is_deeply [ parse_source(
      'merge D => sub { ccflags q{M} => q{-INNER}; }; ccflags q{M} => q{};' )
      ->get_ccflags ], [],
    'a build-master empty ccflags overrides a merged value back to none';
}

# --- ccflags :wrapper mode -------------------------------------------------

CCFLAGS_WRAPPER_BASIC: {
  my $dist = parse_source( q{ccflags ':wrapper', q{Clownfish::CFC} => q{-std=gnu11};} );
  is_deeply [ $dist->get_ccflags_wrapper ],
    [ [ 'Clownfish::CFC', '-std=gnu11' ] ],
    ':wrapper flags stored as [ module => flags ] in get_ccflags_wrapper';
  is_deeply [ $dist->get_ccflags ], [],
    ':wrapper does not populate the :env channel';
}

CCFLAGS_ENV_EXPLICIT_EQUALS_DEFAULT: {
  # ':env' is a real, writable token and the implicit default; both forms land in
  # the :env channel and neither touches :wrapper.
  my $explicit = parse_source( q{ccflags ':env', q{M} => q{-O0};} );
  my $implicit = parse_source( q{ccflags q{M} => q{-O0};} );
  is_deeply [ $explicit->get_ccflags ], [ [ 'M', '-O0' ] ],
    'explicit :env stores in the :env channel';
  is_deeply [ $implicit->get_ccflags ], [ [ 'M', '-O0' ] ],
    'omitting the mode defaults to :env';
  is_deeply [ $explicit->get_ccflags_wrapper ], [],
    'explicit :env leaves the :wrapper channel empty';
}

CCFLAGS_BOTH_CHANNELS_COEXIST: {
  # Independent-accumulate: a dist may carry both channels; neither drops the other.
  my $dist = parse_source(
    q{ccflags q{D} => q{-DFOO}; ccflags ':wrapper', q{D} => q{-std=gnu11};} );
  is_deeply [ $dist->get_ccflags ], [ [ 'D', '-DFOO' ] ],
    'the :env channel keeps its flags when :wrapper is also set on the dist';
  is_deeply [ $dist->get_ccflags_wrapper ], [ [ 'D', '-std=gnu11' ] ],
    'the :wrapper channel keeps its flags independently';
}

CCFLAGS_WRAPPER_OUTERMOST_WINS: {
  # The :wrapper channel composes by the same outermost-wins rule as :env.
  my $dist = parse_source(
      q{ccflags ':wrapper', q{M} => q{-OUTER}; }
    . q{merge D => sub { ccflags ':wrapper', q{M} => q{-INNER}; };} );
  is_deeply [ $dist->get_ccflags_wrapper ], [ [ 'M', '-OUTER' ] ],
    'build-master :wrapper overrides a merged dist (outermost wins)';
}

CCFLAGS_WRAPPER_MERGED_ONLY_APPLIES: {
  my $dist = parse_source(
    q{merge D => sub { ccflags ':wrapper', q{M} => q{-INNER}; };} );
  is_deeply [ $dist->get_ccflags_wrapper ], [ [ 'M', '-INNER' ] ],
    'a merged dist :wrapper applies when the build-master is silent';
  is_deeply [ $dist->get_ccflags ], [],
    'a merged :wrapper does not leak into the :env channel';
}

CCFLAGS_WRAPPER_EMPTY_IS_INERT: {
  is_deeply
    [ parse_source( q{ccflags ':wrapper', q{X} => q{};} )->get_ccflags_wrapper ], [],
    'empty :wrapper flags are filtered from get_ccflags_wrapper';
}

CCFLAGS_UNKNOWN_MODE_CROAKS: {
  my $err = parse_expect_die( q{ccflags ':bogus', q{M} => q{-x};} );
  like $err, qr/Unknown ccflags mode/,
    'an unknown ccflags mode token croaks /Unknown ccflags mode/';
}

CCFLAGS_REQUIRES_MODULE_AND_FLAGS: {
  # The no-module form (a would-be global :wrapper) is rejected: after the mode
  # token only one arg remains, so it croaks rather than being silently misread.
  my $err = parse_expect_die( q{ccflags ':wrapper', q{-std=gnu11};} );
  like $err, qr/module name and flags/,
    'a :wrapper with no module (would-be global) croaks';
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
    [ 'M1', 'M2', 'M3', 'P1' ],
    'merge-body prepends fold ahead of parent in declaration order (merged-before-outer, FIFO)';
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
    [ 'Shared', 'ChildOnly', 'ParentOnly' ],
    'a module shared by parent and merge folds to its merged position, declaration order';
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

  # Parent receives every prepend in declaration order (O1, then the nested I1,
  # then O2), ahead of its own P. Merged-before-outer, FIFO within the merged set.
  is_deeply [ $dist->get_prepended_modules ],
    [ 'O1', 'I1', 'O2', 'P' ],
    'nested merge: all prepends fold into parent in declaration order';
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

  # Parent receives both sets in merge declaration order, ahead of its own.
  is_deeply [ $dist->get_prepended_modules ], [ 'F1', 'S1', 'P' ],
    'parent receives both sibling prepends in merge declaration order, ahead of its own';
  is_deeply [ $dist->get_modules_not_to_test ], [ 'Ft', 'St' ],
    'parent receives both sibling notests in merge declaration order';
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

CALLSTACK_SKIP_DEFAULT_MODLIST: {
  my $dist = parse_source('prepend q{Pre1};');
  my @stack = $dist->build_cpanm_call_stack(
    { 'skip-default-modlist' => 1 }, ['RealPrereq'] );
  is_deeply \@stack, [ ['RealPrereq'] ],
    'skip-default-modlist omits the mistfile module list (a targeted install)';
}

done_testing;
