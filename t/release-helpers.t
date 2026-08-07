#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use File::Spec;
use File::Temp ();
use Cwd ();
use Config;
use Path::Class ();
use Capture::Tiny qw/ capture_stderr /;

# Loading App::Mist::Command::release triggers App::Mist's BEGIN, which resolves
# the project perl5/ relative to $RealBin - absent in the clean-room dist work
# dir. Skip under RELEASE_TESTING (mist's own release dist-test); this runs
# normally via ./mist-run prove, and the pure helpers it covers need no install.
BEGIN {
  plan skip_all => 'needs the full mist install (perl5/); run via ./mist-run prove'
    if $ENV{RELEASE_TESTING};
}

use App::Mist::Command::release;

sub spew {
  my ( $file, $content ) = @_;
  open my $fh, '>', $file or die "open $file: $!";
  print {$fh} $content;
  close $fh;
}

sub slurp {
  my ( $file ) = @_;
  open my $fh, '<', $file or die "open $file: $!";
  local $/;
  return <$fh>;
}

# ---------------------------------------------------------------------------
# _cleanroom_inc: pure string builder. Returns a 2-element list, arch-first,
# derived verbatim from its $dir argument and $Config{archname}. Never hardcode
# the archname - build expected values with the same File::Spec->catdir so
# path separators match on every platform / pinned perl.
# ---------------------------------------------------------------------------

my $dir = File::Spec->catdir( File::Spec->rootdir, qw/ tmp cleanroom_probe / );
my @inc = App::Mist::Command::release::_cleanroom_inc( $dir );

my $e0 = File::Spec->catdir( $dir, qw/ lib perl5 /, $Config{archname} );
my $e1 = File::Spec->catdir( $dir, qw/ lib perl5 / );

is scalar(@inc), 2, 'cleanroom_inc returns exactly two elements';
is $inc[0], $e0, 'cleanroom_inc arch dir first';
is $inc[1], $e1, 'cleanroom_inc plain lib/perl5 second';
is_deeply [ @inc ], [ $e0, $e1 ], 'cleanroom_inc full list value and order';

my $other_dir = File::Spec->catdir( File::Spec->rootdir, qw/ var other_probe / );
my @inc2 = App::Mist::Command::release::_cleanroom_inc( $other_dir );
is_deeply
  [ @inc2 ],
  [ File::Spec->catdir( $other_dir, qw/ lib perl5 /, $Config{archname} ),
    File::Spec->catdir( $other_dir, qw/ lib perl5 / ) ],
  'cleanroom_inc uses its $dir argument verbatim (distinct prefixes)';

# ---------------------------------------------------------------------------
# _args_request_dry_run: must agree with how Minilla::CLI::Release will parse
# the very same @$args. Minilla parses with Getopt::Long's default config
# (auto_abbrev on), so any unambiguous abbreviation of --dry-run counts; a bare
# string-equality check would miss those and let mist run the trailing `dist`
# (leaving a tarball) for what Minilla treated as a dry run. It must also leave
# @$args untouched, since the same arrayref is forwarded to Minilla verbatim.
# ---------------------------------------------------------------------------

{
  my $probe = \&App::Mist::Command::release::_args_request_dry_run;

  my @cases = (
    [ []                       => 0, 'no args' ],
    [ ['--dry-run']            => 1, 'full --dry-run' ],
    [ ['--dry']                => 1, 'abbreviation --dry' ],
    [ ['--dry-r']              => 1, 'abbreviation --dry-r' ],
    [ ['--no-dry-run']         => 0, 'negated --no-dry-run' ],
    [ ['--trial', '--dry-run'] => 1, '--dry-run alongside another option' ],
    [ ['--no-test']            => 0, 'unrelated option only' ],
    [ ['foo', '--dry']         => 1, 'positional arg before the abbreviation' ],
  );

  for my $case ( @cases ) {
    my ( $args, $want, $label ) = @$case;
    my @copy = @$args;
    is( ( $probe->( \@copy ) ? 1 : 0 ), $want, "dry-run probe: $label" );
    is_deeply( \@copy, $args, "dry-run probe leaves args untouched: $label" );
  }
}

# ---------------------------------------------------------------------------
# _changes_has_next_entry: reads ./Changes from CWD. with_changes chdirs into a
# fresh temp dir, optionally writes Changes, calls the sub, then ALWAYS restores
# cwd - including the no-file path. The newdir object is held in a lexical so it
# is not reaped while we are chdir'd inside it.
# ---------------------------------------------------------------------------

sub with_changes {
  my ($content) = @_;
  my $before = Cwd::getcwd();
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  my $r;
  {
    chdir $tmp or die "chdir $tmp: $!";
    if ( defined $content ) {
      open my $fh, '>', 'Changes' or die "open Changes: $!";
      print {$fh} $content;
      close $fh;
    }
    $r = App::Mist::Command::release::_changes_has_next_entry();
    chdir $before or die "chdir back $before: $!";
  }
  return $r;
}

# Marker written with \$NEXT so $NEXT is not interpolated.

ok  with_changes("{{\$NEXT}}\n  - foo\n"),
    'next marker + indented entry is TRUE';

ok !with_changes("{{\$NEXT}}\n\nNot indented line\n"),
    'next marker, blank, then NON-indented line is FALSE';

ok !with_changes("0.01 2020-01-01\n  - foo\n"),
    'no next marker is FALSE even with an indented entry';

is  with_changes(undef), 0,
    'no Changes file returns 0 (numeric, no die)';

ok  with_changes("{{\$NEXT}}\n\n  - foo\n"),
    '\\R+ permits a blank line before an INDENTED entry -> TRUE';

ok  with_changes("{{\$NEXT}}   \n  - foo\n"),
    '\\h* permits trailing whitespace after the marker -> TRUE';

ok !with_changes("{{\$NEXT}}\nNot indented\n"),
    'non-indented line right after marker (no blank) is FALSE';

ok !with_changes("{{\$NEXT}}\n"),
    'marker as final line with nothing after is FALSE';

ok !with_changes("   {{\$NEXT}}\n  - foo\n"),
    'indented (non-column-0) marker is FALSE (/m ^ anchors line start)';

ok !with_changes(""),
    'empty Changes file is FALSE';

ok  with_changes("{{\$NEXT}}\n\t- foo\n"),
    'TAB-indented entry counts as indentation -> TRUE';

# Marker NOT on the first line: a real Minilla layout has a title + blank line
# before {{$NEXT}}. /m's ^ must anchor at the marker's own line, not just the
# string start. This is the only TRUE fixture that kills a dropped-/m mutant -
# every other TRUE case puts the marker on line 1, where ^ matches regardless.
ok  with_changes("Revision history for Foo\n\n{{\$NEXT}}\n  - foo\n"),
    'marker on a later line (title + blank above) is TRUE (/m, kills dropped-/m mutant)';

# Empty {{$NEXT}} section: the marker is immediately followed by a blank line and
# then a NON-indented older-release header. The older release below DOES carry
# indented entries - the match must stay anchored to the marker and NOT drift
# onto that unrelated section's indentation.
ok !with_changes("{{\$NEXT}}\n\n0.35 2025-01-01\n  - old entry\n"),
    'empty NEXT section above an indented older release is FALSE (no drift)';

# CRLF line endings after the marker: \R matches \r\n as one break, \h does not
# swallow the \r, so {{$NEXT}}\r\n + indented entry still matches -> TRUE.
ok  with_changes("{{\$NEXT}}\r\n  - foo\r\n"),
    'CRLF (\\r\\n) line endings after the marker still TRUE';

# A Changes path that exists but cannot be opened for reading must take the
# `open ... or return 0` branch. chmod 0000 a regular file (so -f is TRUE but
# open fails with EACCES). Skip under root, where the perms are ignored.
SKIP: {
  skip 'cannot deny read access as root', 1 if $> == 0;
  my $before = Cwd::getcwd();
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  my $r;
  {
    chdir $tmp or die "chdir $tmp: $!";
    open my $fh, '>', 'Changes' or die "open Changes: $!";
    print {$fh} "{{\$NEXT}}\n  - foo\n";
    close $fh;
    chmod 0000, 'Changes' or die "chmod Changes: $!";
    # Guard against a host where 0000 is still readable (some FS / mount opts).
    if ( open my $probe, '<', 'Changes' ) {
      close $probe;
      chmod 0644, 'Changes';
      chdir $before or die "chdir back $before: $!";
      skip 'chmod 0000 did not deny read on this filesystem', 1;
    }
    $r = App::Mist::Command::release::_changes_has_next_entry();
    chmod 0644, 'Changes';    # let CLEANUP unlink it
    chdir $before or die "chdir back $before: $!";
  }
  is $r, 0, 'unreadable Changes (chmod 0000) returns 0 via open-failure branch';
}

# A directory named Changes is not a plain file: -f is FALSE, so the guard
# `return 0 unless -f 'Changes'` fires before open is even attempted.
{
  my $before = Cwd::getcwd();
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  my $r;
  {
    chdir $tmp or die "chdir $tmp: $!";
    mkdir 'Changes' or die "mkdir Changes: $!";
    $r = App::Mist::Command::release::_changes_has_next_entry();
    chdir $before or die "chdir back $before: $!";
  }
  is $r, 0, 'a directory named Changes returns 0 (not a plain file)';
}

my $before = Cwd::getcwd();
with_changes("{{\$NEXT}}\n  - foo\n");
my $after = Cwd::getcwd();
is $after, $before, 'cwd is restored after a with_changes call';

# ---------------------------------------------------------------------------
# _extract_candidate: pulls --candidate=<id> off a COPY of the args (the caller's
# arrayref is forwarded to Minilla verbatim and must be left intact) and returns
# (id, remaining-args). Minilla does not know --candidate, so it must not survive
# into the forwarded args; --dry-run and every other option must, in order.
# ---------------------------------------------------------------------------
{
  my $extract = \&App::Mist::Command::release::_extract_candidate;

  my ( $id, @rest ) = $extract->( [] );
  is $id, undef, 'no --candidate -> undef id';
  is_deeply \@rest, [], '... and empty rest';

  ( $id, @rest ) = $extract->( [ '--candidate=abc-123' ] );
  is $id, 'abc-123', '--candidate=VALUE extracted';
  is_deeply \@rest, [], '... and removed from the forwarded args';

  ( $id, @rest ) = $extract->( [ '--candidate', 'xyz' ] );
  is $id, 'xyz', 'space-separated --candidate VALUE extracted';

  ( $id, @rest ) = $extract->( [ '--trial', '--candidate=u-1', '--no-test' ] );
  is $id, 'u-1', '--candidate extracted from among other options';
  is_deeply \@rest, [ '--trial', '--no-test' ],
    '... leaving the other options in their original order';

  ( $id, @rest ) = $extract->( [ '--dry-run' ] );
  is $id, undef, '--dry-run alone -> no candidate';
  is_deeply \@rest, [ '--dry-run' ], '... and --dry-run passes through';

  my $orig = [ '--candidate=keep', '--dry-run' ];
  $extract->( $orig );
  is_deeply $orig, [ '--candidate=keep', '--dry-run' ],
    'the caller-supplied arrayref is not mutated';
}

# ---------------------------------------------------------------------------
# _new_candidate_id: a fresh, unique, UUID-shaped ephemeral handle each call.
# ---------------------------------------------------------------------------
{
  my $new = \&App::Mist::Command::release::_new_candidate_id;
  my $a = $new->();
  my $b = $new->();
  like $a, qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
    '_new_candidate_id is 8-4-4-4-12 lowercase hex';
  isnt $a, $b, 'successive ids differ (ephemeral, not re-derivable)';
}

# ---------------------------------------------------------------------------
# _fingerprint: pure SHA of perl + arch + each file's path and contents. Same
# inputs -> identical digest; any change -> different; a missing file is stable.
# This is the staleness guard that lets --candidate refuse a changed dep set.
# ---------------------------------------------------------------------------
{
  my $fp   = \&App::Mist::Command::release::_fingerprint;
  my $spew = sub {
    my ( $f, $c ) = @_;
    open my $fh, '>', $f or die "open $f: $!";
    print {$fh} $c;
    close $fh;
  };

  my $fpdir = File::Temp->newdir( CLEANUP => 1 );
  my $cpan  = File::Spec->catfile( "$fpdir", 'cpanfile' );
  my $mist  = File::Spec->catfile( "$fpdir", 'mistfile' );
  $spew->( $cpan, "requires 'Foo';\n" );
  $spew->( $mist, "perl '5.20.3';\n" );

  my $base = $fp->( 'v5.20.3', 'x86_64-linux', $cpan, $mist );

  is $fp->( 'v5.20.3', 'x86_64-linux', $cpan, $mist ), $base,
    'same perl/arch/files -> identical digest';
  isnt $fp->( 'v5.38.2', 'x86_64-linux', $cpan, $mist ), $base,
    'different perl version -> different digest';
  isnt $fp->( 'v5.20.3', 'aarch64-linux', $cpan, $mist ), $base,
    'different archname -> different digest';

  $spew->( $cpan, "requires 'Foo';\nrequires 'Bar';\n" );
  isnt $fp->( 'v5.20.3', 'x86_64-linux', $cpan, $mist ), $base,
    'changed file content -> different digest';

  my $absent = File::Spec->catfile( "$fpdir", 'nope' );
  is $fp->( 'v5.20.3', 'x86_64-linux', $absent ),
     $fp->( 'v5.20.3', 'x86_64-linux', $absent ),
    'a missing file is handled deterministically (no die)';
  isnt $fp->( 'v5.20.3', 'x86_64-linux', $absent ),
       $fp->( 'v5.20.3', 'x86_64-linux', $mist ),
    'missing vs present file -> different digest';
}

# ---------------------------------------------------------------------------
# Candidate lifecycle: path construction, _gc_release_candidates (ephemeral
# wipe), _remove_release_candidate, and the _write_candidate_fingerprint ->
# _candidate_staleness round-trip. Driven by a minimal fake ctx exposing only
# the accessors these helpers touch, so no real project / perl install is needed.
# ---------------------------------------------------------------------------
{
  package FakeCtx;
  sub new          { my ( $c, %a ) = @_; bless { %a }, $c }
  sub workspace    { $_[0]{workspace} }
  sub cpanfile     { $_[0]{cpanfile} }
  sub project_root { $_[0]{project_root} }
  sub mpan_dist    { $_[0]{mpan_dist} }
}

{
  my $R = 'App::Mist::Command::release';

  my $tmp  = File::Temp->newdir( CLEANUP => 1 );
  my $base = Path::Class::dir( "$tmp" );
  my $ws   = $base->subdir( 'workspace' );
  $ws->mkpath;

  my $proj = $base->subdir( 'proj' );
  $proj->subdir( 'mpan-dist', 'modules' )->mkpath;
  my $cpanfile = $proj->file( 'cpanfile' );
  my $mistfile = $proj->file( 'mistfile' );
  my $mpan     = $proj->subdir( 'mpan-dist' );
  my $index    = $mpan->file(qw/ modules 02packages.details.txt.gz /)->stringify;
  spew( "$cpanfile", "requires 'Foo';\n" );
  spew( "$mistfile", "perl '5.20.3';\n" );
  spew( $index, "idx-v1" );

  my $ctx = FakeCtx->new(
    workspace    => $ws,
    cpanfile     => $cpanfile,
    project_root => $proj,
    mpan_dist    => $mpan,
  );

  my $root = $R->can('_candidates_root')->( $ctx );
  is "$root", $ws->subdir( 'release-candidates' )->stringify,
    '_candidates_root is <workspace>/release-candidates';
  is "${\ $R->can('_candidate_dir')->( $ctx, 'abc' )}",
     $ws->subdir( 'release-candidates', 'abc' )->stringify,
    '_candidate_dir is <root>/<id>';

  # _gc_release_candidates: unstamped candidates are debris - no green
  # dist-test ever vouched for them - and are evicted no matter what else holds.
  $root->subdir( $_ )->mkpath for qw/ one two /;
  ok -d $root->subdir( 'one' )->stringify, 'precondition: candidate "one" exists';
  my $kept;
  capture_stderr { $kept = $R->can('_gc_release_candidates')->( $ctx ) };
  ok !-d $root->subdir( 'one' )->stringify, '_gc_release_candidates removed "one"';
  ok !-d $root->subdir( 'two' )->stringify, '... and "two"';
  is $kept, undef, '... and returned no candidate to reuse';

  # _remove_release_candidate removes just the named one
  my $solo = $R->can('_candidate_dir')->( $ctx, 'solo' );
  $solo->mkpath;
  $R->can('_remove_release_candidate')->( $ctx, 'solo' );
  ok !-d $solo->stringify, '_remove_release_candidate removed "solo"';

  # fingerprint round-trip. EACH file input must flip staleness, or a dropped
  # input from _release_fingerprint would silently weaken the fail-closed guard.
  # (perl + arch are already covered by the _fingerprint primitive test above.)
  my $cdir = $R->can('_candidate_dir')->( $ctx, 'fp' );
  $cdir->mkpath;

  # Staleness now also refuses a candidate with no installed closure, so this
  # fixture needs one - otherwise every assertion below would trip that reason
  # instead of exercising the fingerprint inputs it is here to test.
  $cdir->subdir( 'lib', 'perl5' )->mkpath;
  $cdir->subdir( 'lib', 'perl5' )->file( 'Dummy.pm' )->spew( "1;\n" );

  for my $input ( [ cpanfile => "$cpanfile" ],
                  [ mistfile => "$mistfile" ],
                  [ '02packages index' => $index ] ) {
    my ( $name, $file ) = @$input;
    # rewrite a fresh fingerprint against the current tree, then mutate just
    # this one input and confirm the candidate goes stale.
    $R->can('_write_candidate_fingerprint')->( $ctx, "$cdir" );
    is $R->can('_candidate_staleness')->( $ctx, "$cdir" ), '',
      "fresh fingerprint before touching $name -> not stale";
    spew( $file, slurp( $file ) . "\n# changed\n" );
    ok $R->can('_candidate_staleness')->( $ctx, "$cdir" ),
      "changed $name -> stale (each fingerprint input is wired in)";
  }

  $R->can('_write_candidate_fingerprint')->( $ctx, "$cdir" );
  unlink $R->can('_fingerprint_file')->( "$cdir" );
  like $R->can('_candidate_staleness')->( $ctx, "$cdir" ), qr/no fingerprint/,
    'missing fingerprint -> stale (fail closed)';

  # The observed failure: a candidate carrying a current fingerprint and nothing
  # else passed every check, was promoted, and then starved DistTest of the
  # dist's own prereqs - after the version bump, so the release died mid-pipeline
  # with a dirty tree. A matching fingerprint says the inputs are unchanged, not
  # that anything was installed.
  my $hollow = $R->can('_candidate_dir')->( $ctx, 'hollow' );
  $hollow->mkpath;
  $R->can('_write_candidate_fingerprint')->( $ctx, "$hollow" );
  like $R->can('_candidate_staleness')->( $ctx, "$hollow" ),
    qr/no installed modules/,
    'current fingerprint but empty candidate -> refused, not promoted';
}

# ---------------------------------------------------------------------------
# _gc_release_candidates: keyed eviction. A stamped candidate matching the
# current environment survives the GC and is returned for reuse; a stale
# fingerprint, an over-age stamp, and $evict_all (--fresh) each evict. With
# several valid candidates the most recently stamped wins.
# ---------------------------------------------------------------------------
{
  my $R = 'App::Mist::Command::release';

  my $tmp  = File::Temp->newdir( CLEANUP => 1 );
  my $base = Path::Class::dir( "$tmp" );
  my $ws   = $base->subdir( 'workspace' );
  $ws->mkpath;

  my $proj = $base->subdir( 'proj' );
  $proj->subdir( 'mpan-dist', 'modules' )->mkpath;
  my $cpanfile = $proj->file( 'cpanfile' );
  my $mistfile = $proj->file( 'mistfile' );
  my $mpan     = $proj->subdir( 'mpan-dist' );
  my $index    = $mpan->file(qw/ modules 02packages.details.txt.gz /)->stringify;
  spew( "$cpanfile", "requires 'Foo';\n" );
  spew( "$mistfile", "perl '5.20.3';\n" );
  spew( $index, "idx-v1" );

  my $ctx = FakeCtx->new(
    workspace    => $ws,
    cpanfile     => $cpanfile,
    project_root => $proj,
    mpan_dist    => $mpan,
  );

  # A reusable candidate needs the full two-way promise: an installed closure
  # (one .pm suffices for the presence check) plus a current fingerprint stamp.
  my $stamp_candidate = sub {
    my ( $id ) = @_;
    my $dir = $R->can('_candidate_dir')->( $ctx, $id );
    $dir->subdir( 'lib', 'perl5' )->mkpath;
    $dir->subdir( 'lib', 'perl5' )->file( 'Dummy.pm' )->spew( "1;\n" );
    $R->can('_write_candidate_fingerprint')->( $ctx, "$dir" );
    return $dir;
  };
  my $gc = sub {
    my ( $evict_all ) = @_;
    my $kept;
    capture_stderr {
      $kept = $R->can('_gc_release_candidates')->( $ctx, $evict_all );
    };
    return $kept;
  };

  my $valid = $stamp_candidate->( 'aaa' );
  my $kept  = $gc->();
  ok defined $kept, 'a stamped, matching candidate survives the GC';
  is $kept->basename, 'aaa', '... and is the one returned for reuse';
  ok -d $valid->stringify, '... with its directory still on disk';

  $kept = $gc->( 1 );
  is $kept, undef, '$evict_all (--fresh) returns no candidate';
  ok !-d $valid->stringify, '... and deletes even a valid one';

  my $stale = $stamp_candidate->( 'bbb' );
  spew( "$cpanfile", "requires 'Foo';\nrequires 'Bar';\n" );
  $kept = $gc->();
  is $kept, undef, 'a candidate stamped for a changed environment is not kept';
  ok !-d $stale->stringify, '... and is deleted';

  # Age bound: backdate the stamp past the reuse window. The mtime is the
  # "last validated" clock, so utime is the honest way to age a candidate.
  my $aged = $stamp_candidate->( 'ccc' );
  my $old  = time
    - ( App::Mist::Command::release::CANDIDATE_MAX_AGE_DAYS() + 1 ) * 86400;
  utime $old, $old, $R->can('_fingerprint_file')->( "$aged" ) or die "utime: $!";
  like $R->can('_candidate_staleness')->( $ctx, "$aged" ), qr/days ago/,
    'an over-age stamp reads as stale, naming the age';
  $kept = $gc->();
  is $kept, undef, '... and the GC evicts it';
  ok !-d $aged->stringify, '... deleting the directory';

  my $older = $stamp_candidate->( 'ddd' );
  my $newer = $stamp_candidate->( 'eee' );
  my $past  = time - 1_000;
  utime $past, $past, $R->can('_fingerprint_file')->( "$older" ) or die "utime: $!";
  $kept = $gc->();
  is $kept->basename, 'eee', 'with two valid candidates the newest stamp wins';
  ok !-d $older->stringify, '... the older one is evicted as superseded';
  ok -d $newer->stringify, '... and the winner stays on disk';
}

# ---------------------------------------------------------------------------
# _extract_fresh: boolean sibling of _extract_candidate - same copy-and-return
# contract, for the same reason (the arrayref is forwarded to Minilla verbatim,
# and Minilla does not know --fresh).
# ---------------------------------------------------------------------------
{
  my $extract = \&App::Mist::Command::release::_extract_fresh;

  my ( $fresh, @rest ) = $extract->( [] );
  is $fresh, 0, 'no --fresh -> 0';
  is_deeply \@rest, [], '... and empty rest';

  ( $fresh, @rest ) = $extract->( [ '--fresh' ] );
  is $fresh, 1, '--fresh extracted as 1';
  is_deeply \@rest, [], '... and removed from the forwarded args';

  ( $fresh, @rest ) = $extract->( [ '--dry-run', '--fresh', '--trial' ] );
  is $fresh, 1, '--fresh extracted from among other options';
  is_deeply \@rest, [ '--dry-run', '--trial' ],
    '... leaving the others in their original order';

  my $orig = [ '--fresh', '--dry-run' ];
  $extract->( $orig );
  is_deeply $orig, [ '--fresh', '--dry-run' ],
    'the caller-supplied arrayref is not mutated';
}

# ---------------------------------------------------------------------------
# _valid_candidate_id: the path-traversal guard. Accept the hex+dash shape
# _new_candidate_id emits; reject empty, over-long, and anything with path or
# option characters that could escape the workspace dir.
# ---------------------------------------------------------------------------
{
  my $ok = \&App::Mist::Command::release::_valid_candidate_id;

  ok $ok->( App::Mist::Command::release::_new_candidate_id() ),
    '_new_candidate_id output passes its own guard';
  ok $ok->( 'abc-123' ),       'short hex-ish id accepted';
  ok $ok->( 'F' x 64 ),        '64 chars accepted (boundary)';

  ok !$ok->( undef ),          'undef rejected';
  ok !$ok->( '' ),             'empty rejected';
  ok !$ok->( 'F' x 65 ),       '65 chars rejected (boundary)';
  ok !$ok->( '..' ),           'parent-dir rejected';
  ok !$ok->( '../../etc' ),    'path traversal rejected';
  ok !$ok->( 'a/b' ),          'slash rejected';
  ok !$ok->( '--dry-run' ),    'option-shaped value rejected';
  ok !$ok->( 'has space' ),    'whitespace rejected';
}

# _candidate_holds_closure / the staleness guard that uses it.
#
# The fingerprint attests only to the inputs that decide the closure - cpanfile,
# mistfile, mpan-dist index, perl - never that the closure was actually
# installed. A candidate holding just a fingerprint therefore passed every check
# and was promoted, whereupon DistTest starved for the dist's own prereqs. That
# happens after RegenerateFiles has bumped the version, so the release dies
# mid-pipeline and leaves lib/*.pm and META.json dirty. Refuse it up front.
CANDIDATE_MUST_HOLD_A_CLOSURE: {
  my $holds = \&App::Mist::Command::release::_candidate_holds_closure;

  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  my $dir = Path::Class::dir( "$tmp" );

  ok !$holds->( $dir ), 'an empty candidate holds no closure';

  $dir->subdir( 'lib', 'perl5' )->mkpath;
  ok !$holds->( $dir ), 'a candidate with an empty lib/perl5 holds no closure';

  $dir->subdir( 'lib', 'perl5' )->file( 'README' )->spew( "not a module\n" );
  ok !$holds->( $dir ), 'non-module files do not count';

  $dir->subdir( 'lib', 'perl5', 'Deep', 'Nested' )->mkpath;
  $dir->subdir( 'lib', 'perl5', 'Deep', 'Nested' )->file( 'Mod.pm' )
      ->spew( "1;\n" );
  ok $holds->( $dir ), 'a .pm anywhere under lib/perl5 counts';

  # Callers pass a Path::Class::Dir or a plain path interchangeably, as the
  # staleness helpers already do.
  ok $holds->( "$dir" ), 'accepts a plain string path too';
}

done_testing;
