#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Temp ();
use File::Spec;

use Mist::Distribution;
use Mist::Environment;

# Helper: parse source directly into a Mist::Distribution.
sub parse_src {
  my $src = shift;
  return Mist::Environment->new->parse( source => $src );
}

# Helper: round-trip a source through as_code -> eval -> distinfo and return
# the resulting Mist::Distribution. Uses a caller-supplied package name so each
# case gets its own package and there is no cross-test contamination.
sub roundtrip {
  my ( $src, $package ) = @_;
  my $code = Mist::Environment->new->as_code( source => $src, package => $package );
  my $ret  = eval $code;
  die "eval of generated code failed: $@" if $@;
  return ( $ret, $package->distinfo );
}

ROUND_TRIP_PERL_VERSION: {
  my $src = 'perl q{5.20.3}; prepend q{Foo::Bar};';
  my $d1 = parse_src( $src );
  my ( undef, $d2 ) = roundtrip( $src, 'TDistPV' );

  is $d1->get_default_perl_version, '5.20.3',
    'direct parse: perl version captured';
  is $d2->get_default_perl_version, $d1->get_default_perl_version,
    'round-trip: perl version identical to direct parse';
}

ROUND_TRIP_PREPENDED_MODULES: {
  my $src = 'perl q{5.20.3}; prepend q{Foo::Bar}; prepend q{Baz}, q{1.20}; prepend q{Need::Op}, q{>=2.0};';
  my @p1 = parse_src( $src )->get_prepended_modules;
  my ( undef, $d2 ) = roundtrip( $src, 'TDistPM' );
  my @p2 = $d2->get_prepended_modules;

  is_deeply \@p1, [qw/Foo::Bar Baz~1.20 Need::Op>=2.0/],
    'direct parse: prepend version normalization (bare, ~version, operator passthrough)';
  is_deeply \@p2, \@p1,
    'round-trip: prepended modules + normalized versions + order identical';
}

ROUND_TRIP_MODULES_NOT_TO_TEST: {
  my $src = 'notest q{Term::ReadKey}; notest q{DBD::mysql};';
  my @n1 = parse_src( $src )->get_modules_not_to_test;
  my ( undef, $d2 ) = roundtrip( $src, 'TDistNT' );
  my @n2 = $d2->get_modules_not_to_test;

  is_deeply \@n1, [qw/Term::ReadKey DBD::mysql/],
    'direct parse: notest list captured in order';
  is_deeply \@n2, \@n1,
    'round-trip: notest list identical';
}

ROUND_TRIP_CPANM_CALL_STACK: {
  my $src = 'perl q{5.20.3}; prepend q{Foo::Bar}; prepend q{Baz}, q{1.20}; notest q{Term::ReadKey};';
  my $d1 = parse_src( $src );
  my ( undef, $d2 ) = roundtrip( $src, 'TDistCS' );

  my @cs1 = $d1->build_cpanm_call_stack([qw/A B Term::ReadKey/]);
  my @cs2 = $d2->build_cpanm_call_stack([qw/A B Term::ReadKey/]);

  is_deeply \@cs1,
    [
      ['Foo::Bar'],
      ['Baz~1.20'],
      ['--installdeps', 'Term::ReadKey'],
      ['--notest', 'Term::ReadKey'],
      ['A'],
      ['B'],
    ],
    'direct parse: call stack = prepends first, notest pair, prereqs last';
  is_deeply \@cs2, \@cs1,
    'round-trip: full cpanm call stack identical';
}

GENERATED_CODE_IS_VALID_PERL: {
  my $src = 'perl q{5.20.3}; prepend q{A}; prepend q{B}, q{1.0}; notest q{C}; assert { 1 };';
  my $code = Mist::Environment->new->as_code( source => $src, package => 'TDistSyn' );
  local $@;
  my $ret = eval $code;
  is $@, '', 'generated code eval has no error';
  isa_ok $ret, 'Mist::Distribution', 'generated code yields a';
}

EXPLICIT_PACKAGE_NAME_HONOURED: {
  my $code = Mist::Environment->new->as_code(
    source => 'perl q{5.20.3};', package => 'My::Chosen::Pkg' );
  like $code, qr/package My::Chosen::Pkg;/,
    'package= literally names the generated package';
  eval $code;
  is $@, '', 'generated code with explicit package evals cleanly';
  can_ok 'My::Chosen::Pkg', 'distinfo';
  isa_ok My::Chosen::Pkg->distinfo, 'Mist::Distribution',
    'explicit package distinfo returns a';
  is My::Chosen::Pkg->distinfo->get_default_perl_version, '5.20.3',
    'explicit package distinfo carries the parsed perl version';
}

DEFAULT_PACKAGE_USES_SANDBOX_NAME: {
  my $code = Mist::Environment->new->as_code( source => 'perl q{5.30.0};' );
  like $code, qr/package Mist::Environment::Sandbox\d+;/,
    'omitting package= yields an auto-generated Sandbox<N> package name';
}

EVAL_RETURN_AND_DISTINFO_SAME_OBJECT: {
  my $code = Mist::Environment->new->as_code(
    source => 'perl q{5.20.3}; prepend q{Z};', package => 'TDistRet' );
  my $ret = eval $code;
  die $@ if $@;
  isa_ok $ret, 'Mist::Distribution', 'eval return value is a';
  ok $ret == TDistRet->distinfo,
    'eval return value is the same object as distinfo()';
}

EMPTY_SOURCE_ROUND_TRIP: {
  my $d1 = parse_src( '' );
  my ( undef, $d2 ) = roundtrip( '', 'TDistEmpty' );

  ok !defined $d1->get_default_perl_version,
    'direct parse: empty source => undef perl version';
  is_deeply [$d1->get_prepended_modules], [],
    'direct parse: empty source => empty prepend list';
  is_deeply [$d1->get_modules_not_to_test], [],
    'direct parse: empty source => empty notest list';

  ok !defined $d2->get_default_perl_version,
    'round-trip: empty source => undef perl version';
  is_deeply [$d2->get_prepended_modules], [],
    'round-trip: empty source => empty prepend list';
  is_deeply [$d2->get_modules_not_to_test], [],
    'round-trip: empty source => empty notest list';
}

AS_CODE_NO_ARGS_DOES_NOT_CROAK: {
  my $code = Mist::Environment->new->as_code();
  local $@;
  my $ret = eval $code;
  is $@, '', 'as_code() with no args defaults source to empty and evals cleanly';
  isa_ok $ret, 'Mist::Distribution', 'as_code() with no args yields a';
}

PREPEND_DEDUP_PRESERVED: {
  my $src = 'prepend q{Dup}; prepend q{Other}; prepend q{Dup};';
  my @p1 = parse_src( $src )->get_prepended_modules;
  my ( undef, $d2 ) = roundtrip( $src, 'TDistDup' );
  my @p2 = $d2->get_prepended_modules;

  is_deeply \@p1, [qw/Dup Other/],
    'direct parse: duplicate prepends collapse, first-occurrence order';
  is_deeply \@p2, \@p1,
    'round-trip: dedup\'d prepend list survives serialization';
}

CALLSTACK_NOTEST_ORDERING: {
  my $src = 'notest q{A::Dep}; notest q{B::Dep};';
  my $d1 = parse_src( $src );
  my ( undef, $d2 ) = roundtrip( $src, 'TDistNTOrd' );

  my @cs1 = $d1->build_cpanm_call_stack([qw/Plain::One A::Dep/]);
  my @cs2 = $d2->build_cpanm_call_stack([qw/Plain::One A::Dep/]);

  is_deeply \@cs1,
    [
      ['--installdeps', 'A::Dep'],
      ['--notest', 'A::Dep'],
      ['--installdeps', 'B::Dep'],
      ['--notest', 'B::Dep'],
      ['Plain::One'],
    ],
    'direct parse: notest pairs scheduled before plain prereqs, declaration order';
  is_deeply \@cs2, \@cs1,
    'round-trip: notest-before-prereqs ordering identical';
}

CALLSTACK_FORCE_TESTS: {
  my $src = 'notest q{N::Mod};';
  my $d1 = parse_src( $src );
  my ( undef, $d2 ) = roundtrip( $src, 'TDistForce' );

  my @cs1 = $d1->build_cpanm_call_stack( {'force-tests' => 1}, [qw/N::Mod/] );
  my @cs2 = $d2->build_cpanm_call_stack( {'force-tests' => 1}, [qw/N::Mod/] );

  is_deeply \@cs1, [['N::Mod']],
    'direct parse: force-tests degrades notest to a single plain entry';
  is_deeply \@cs2, \@cs1,
    'round-trip: force-tests behavior identical';
}

# --- Coverage of the ACTUALLY-SHIPPED code path -----------------------------
#
# Both compile.pm and Context.pm construct Mist::Environment->new($mistfile)
# and then read the DSL from that FILE on disk (parse with no source arg, or
# as_code(package => 'DISTRIBUTION') with no source). The source=>STRING path
# exercised above is convenient for testing but is never used in production.
# The blocks below drive the real file-reading branch in as_code (lib/Mist/
# Environment.pm ~line 35-43).

# Helper: write $src to a fresh temp file and return ( $env, $path ). The
# File::Temp object is captured in the returned env's closure-free struct via
# an extra ref so it outlives the call and the file is not unlinked early.
sub env_from_tempfile {
  my $src = shift;
  my $tmp = File::Temp->new( UNLINK => 1, SUFFIX => '.mistfile' );
  print {$tmp} $src;
  $tmp->flush;
  my $env = Mist::Environment->new( "$tmp" );
  # keep the File::Temp guard alive for as long as the env is referenced
  $env->{_tmp_guard} = $tmp;
  return ( $env, "$tmp" );
}

FILE_READING_PARSE_PATH: {
  my $src = 'perl q{5.20.3}; prepend q{File::Read::Mod}; prepend q{Verd}, q{2.5}; notest q{No::Test::Mod};';
  my ( $env, $path ) = env_from_tempfile( $src );

  ok -f $path, 'temp mistfile exists on disk';

  # parse() with NO source arg => must read the file off disk
  my $dist = $env->parse;

  isa_ok $dist, 'Mist::Distribution',
    'parse() of a file-backed env yields a';
  is $dist->get_default_perl_version, '5.20.3',
    'file path: perl version read from the file on disk';
  is_deeply [ $dist->get_prepended_modules ], [qw/File::Read::Mod Verd~2.5/],
    'file path: prepends (with version normalization) read from the file';
  is_deeply [ $dist->get_modules_not_to_test ], [qw/No::Test::Mod/],
    'file path: notest list read from the file';
}

FILE_PATH_MATCHES_SOURCE_PATH: {
  # Reading from a file must yield the same result as feeding the same bytes
  # as source=>STRING; this pins the two branches of as_code together.
  my $src = 'perl q{5.20.3}; prepend q{Same::Mod}, q{>=1.1}; notest q{Skip::Me};';
  my ( $env, undef ) = env_from_tempfile( $src );

  my $from_file = $env->parse;
  my $from_src  = parse_src( $src );

  is $from_file->get_default_perl_version, $from_src->get_default_perl_version,
    'file vs source: identical perl version';
  is_deeply [ $from_file->get_prepended_modules ],
            [ $from_src->get_prepended_modules ],
    'file vs source: identical prepend list';
  is_deeply [ $from_file->get_modules_not_to_test ],
            [ $from_src->get_modules_not_to_test ],
    'file vs source: identical notest list';
}

AS_CODE_NOTHING_TO_PARSE_CROAKS: {
  # No file (default new()) and no source => the 'Nothing to parse' guard.
  # Note: that guard only fires when the file-read do-block returns undef
  # while source is also absent. A fileless env with no source produces ''
  # (empty source) which is defined, so as_code() itself does not croak there.
  # The croak is reachable when {file} is set but the open yields undef; to
  # exercise the documented guard deterministically we point at a missing file
  # and confirm as_code dies before producing code.
  my $env = Mist::Environment->new( '/nonexistent/path/should/not/exist.mistfile' );
  local $@;
  my $code = eval { $env->as_code };
  ok !defined $code, 'as_code on a missing file does not return code';
  like $@, qr/could not open/,
    'as_code on a missing file dies trying to open it';
}

NOTHING_TO_PARSE_GUARD_FILELESS: {
  # A truly file-less, source-less env: the source defaults to '' (defined),
  # so as_code returns valid code rather than croaking. This documents that
  # the literal 'Nothing to parse' croak is effectively unreachable via the
  # public constructor - {file} is the only way to get an undef $code, and a
  # set-but-unreadable {file} dies at open() first.
  my $env = Mist::Environment->new;
  local $@;
  my $code = eval { $env->as_code };
  is $@, '', 'file-less, source-less as_code() does not croak';
  isa_ok eval $code, 'Mist::Distribution',
    'file-less as_code() yields runnable code for an empty dist';
}

EXPLICIT_PACKAGE_DISTINFO_ISA: {
  my $src = 'perl q{5.20.3}; prepend q{Round::Trip::Mod}; notest q{Rt::Skip};';
  my $code = Mist::Environment->new->as_code(
    source => $src, package => 'My::Roundtrip::Pkg' );
  like $code, qr/package My::Roundtrip::Pkg;/,
    'explicit package name appears verbatim in generated code';

  local $@;
  eval $code;
  is $@, '', 'generated code for explicit package evals cleanly';

  can_ok 'My::Roundtrip::Pkg', 'distinfo';
  my $dist = My::Roundtrip::Pkg->distinfo;
  isa_ok $dist, 'Mist::Distribution',
    'My::Roundtrip::Pkg->distinfo is a';
  is $dist->get_default_perl_version, '5.20.3',
    'explicit-package distinfo carries the parsed perl verb';
  is_deeply [ $dist->get_prepended_modules ], [qw/Round::Trip::Mod/],
    'explicit-package distinfo carries the prepend verb';
  is_deeply [ $dist->get_modules_not_to_test ], [qw/Rt::Skip/],
    'explicit-package distinfo carries the notest verb';
}

LINE_DIRECTIVE_EMITTED_FOR_FILE: {
  # When the env is file-backed AND no explicit package is given, as_code must
  # emit a `# line 1 "<file>"` directive so that mistfile syntax errors report
  # the real file/line. This is the parse() path (Context.pm), not compile.pm
  # (which passes package => 'DISTRIBUTION' and thus suppresses the directive).
  my ( $env, $path ) = env_from_tempfile( 'perl q{5.20.3};' );

  my $code = $env->as_code;            # no package arg
  like $code, qr/\Q# line 1 "$path"\E/,
    'file-backed as_code (no package) emits a "# line 1 <file>" directive';

  # And the directive is suppressed when an explicit package is supplied,
  # matching compile.pm's behavior.
  my $code_pkg = $env->as_code( package => 'DISTRIBUTION' );
  unlike $code_pkg, qr/# line 1/,
    'explicit package suppresses the line directive (compile.pm path)';
}

LINE_DIRECTIVE_NOT_EMITTED_FOR_SOURCE: {
  # A source-only env has no {file}, so even without a package there is no
  # line directive to emit.
  my $code = Mist::Environment->new->as_code( source => 'perl q{5.20.3};' );
  unlike $code, qr/# line 1/,
    'source-backed as_code emits no line directive (no file to point at)';
}

done_testing;
