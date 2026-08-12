package App::Mist::Command::release;
# ABSTRACT: run full release of the distribution package

use 5.010;

use App::Mist -command;
use Minilla::CLI;
use Minilla::Project;

use Config;
use File::Find ();
use File::Spec;
use File::Temp ();
use Getopt::Long ();
use Digest::SHA ();

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $INC{'CPAN/Uploader.pm'} //= __FILE__; }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->refuse_forced_system_perl( 'release' );
  $ctx->ensure_correct_perlbrew_context;

  # --candidate=<id> promotes a build a previous --dry-run left on disk (see the
  # "Reusing a dry-run's build" POD section). Pull it off a copy of the args;
  # @minil_args is what we forward to Minilla, with --candidate removed because
  # Minilla does not know it. --fresh (dry-run only: rebuild instead of reusing
  # a cached candidate) is extracted the same way. --dry-run and everything else
  # pass through.
  my ( $candidate, @minil_args ) = _extract_candidate( $args );
  my $fresh;
  ( $fresh, @minil_args ) = _extract_fresh( \@minil_args );
  my $dry_run = _args_request_dry_run( \@minil_args );

  # --candidate takes a value, and two malformed forms slip past Getopt's
  # pass_through: a bare `--candidate` (no value) survives in @minil_args, and
  # `--candidate --foo` swallows the next option as its "value" (so $candidate
  # starts with a dash). Left alone, the bare form would fall through to a normal
  # release with `--candidate` forwarded to Minilla - i.e. a fat-fingered promote
  # silently becomes a real release. Demand a real value.
  if ( ( defined $candidate and $candidate =~ /\A-/ )
       or grep { /\A--candidate\b/ } @minil_args ) {
    die "mist release: --candidate needs an id value, e.g. --candidate=<ID>.\n";
  }

  die "mist release: --dry-run and --candidate are mutually exclusive.\n"
    if $dry_run and defined $candidate;

  # --fresh evicts even a still-valid candidate before the dry-run builds; on a
  # promote or a normal release there is nothing it could mean.
  die "mist release: --fresh only applies to --dry-run.\n"
    if $fresh and not $dry_run;

  if ( defined $candidate ) {
    # Used unsanitised as a directory name below; keep it to the shape
    # _new_candidate_id emits so a crafted value can't escape the workspace.
    _valid_candidate_id( $candidate )
      or die "mist release: invalid candidate id '$candidate'.\n";
  }

  Minilla::Project->new->config->{release}{do_not_upload_to_cpan}
    or die "mist release: refusing to run.\n"
         . "minil.toml does not set [release] do_not_upload_to_cpan, so this\n"
         . "release could push to CPAN -- which mist no longer supports.\n"
         . "For a genuine CPAN upload, run `minil release` directly.\n";

  # Changelog gate, hardened. Stock Minilla CheckChanges prompts to edit Changes
  # when {{$NEXT}} has no entry and loops forever without a TTY (its prompt
  # panics, then retries). Fail fast instead for a --dry-run and for any
  # non-interactive run; a real release on a terminal still falls through to
  # Minilla's interactive prompt below. A dry-run thus fails here exactly as the
  # real release would, rather than silently passing.
  if ( not _changes_has_next_entry() and ( $dry_run or not -t STDIN ) ) {
    die "mist release: Changes has no entry under {{\$NEXT}}.\n"
      . "Add this release's changes under the {{\$NEXT}} line first"
      . ( $dry_run ? " (a real release would block here too).\n" : ".\n" );
  }

  # Seal the clean-room dist-test to the project's pinned mpan-dist mirror.
  # Stock Minilla::Project::verify_prereqs shells `cpanm --installdeps
  # --with-develop .`, which resolves against live CPAN -- defeating the
  # pinning, and pulling a develop closure that mpan-dist does not vendor.
  # Resolve runtime/test prereqs from mpan-dist only, drop --with-develop,
  # and run cpanm under $^X so a foreign-perl cpanm shebang cannot apply.
  # --notest: the clean-room dist-test's subject is core itself; the pinned
  # mpan-dist set is already the vetting, so a dependency's own (often
  # abandoned/fragile) test suite must not be able to block core's release.
  my $mpan_mirror = 'file://' . $ctx->mpan_dist;
  my $cpanm       = $ctx->cpanm_executable;

  # Choose where the dist's dependency closure lives, and whether to (re)install
  # it. In every mode the dist-test runs against this contained lib only, so a
  # release never mutates - or, on a failed install, corrupts - mist's own perl5,
  # the env the mist CLI itself runs under.
  #   normal release   throwaway tempdir, installed fresh, gone at exit
  #   --dry-run        a persisted candidate dir under the project workspace:
  #                    a prior candidate whose fingerprint still matches is
  #                    reused (install skipped), otherwise one is installed
  #                    fresh; kept for a later --candidate promote and for
  #                    later dry-runs
  #   --candidate=ID   an existing candidate dir, REUSED as-is (install skipped)
  #                    after a fingerprint check proves it still matches the
  #                    current cpanfile/mistfile/mpan-dist/perl
  # See _candidate_dir, _release_fingerprint and the candidate helpers below.
  my ( $lib_dir, $tmp, $reuse );
  if ( defined $candidate ) {
    my $dir = _candidate_dir( $ctx, $candidate );
    -d $dir->stringify
      or die "mist release: unknown release candidate '$candidate'.\n"
           . "Run `mist release --dry-run` to build one.\n";
    if ( my $why = _candidate_staleness( $ctx, $dir ) ) {
      die "mist release: release candidate '$candidate' is stale - $why.\n"
        . "Run `mist release --dry-run` to rebuild it.\n";
    }
    $lib_dir = $dir->stringify;
    $reuse   = 1;
  }
  elsif ( $dry_run ) {
    my $kept = _gc_release_candidates( $ctx, $fresh );
    if ( $kept ) {
      $candidate = $kept->basename;
      $lib_dir   = $kept->stringify;
      $reuse     = 1;
      printf STDERR
          "mist release: reusing the validated closure of candidate %s\n"
        . "  (environment unchanged since %s - pass --fresh to rebuild)\n",
        $candidate, scalar localtime _candidate_stamp_mtime( $kept );
    }
    else {
      $candidate = _new_candidate_id();
      my $dir = _candidate_dir( $ctx, $candidate );
      $dir->mkpath;
      $lib_dir = $dir->stringify;
    }
  }
  else {
    $tmp     = File::Temp->newdir( CLEANUP => 1 );
    $lib_dir = "$tmp";
  }

  my @cleanroom_inc = _cleanroom_inc( $lib_dir );

  {
    no warnings 'redefine';
    *Minilla::Project::verify_prereqs = sub {
      return unless $Minilla::AUTO_INSTALL;
      return if $reuse;    # the candidate already holds the validated closure
      _install_prereqs_contained( $cpanm, $mpan_mirror, $lib_dir );
    };
  }

  # Skip Minilla's release-test generation. Minilla::WorkDir writes
  # xt/minilla/*.t (POD, CPAN::Meta, MinimumVersion, Spellunker,
  # PAUSE-Permissions) into the dist work dir and proves them under
  # RELEASE_TESTING=1 before MakeDist. A failure there interrupts the
  # pipeline AFTER BumpVersion/RegenerateFiles have modified lib/*.pm
  # and META.json -- the only recovery is `git checkout -- <files>`
  # before retry, and the cause is typically something trivial enough
  # that the round-trip is pure overhead (an em dash in a =head1 cost
  # exparse-interpreter-core 0.9908 a full pipeline cycle). Those
  # checks belong pre-release (`mist run -- prove -lr xt/` over a
  # hand-curated xt/), not as a release-time gate. The clean-room t/
  # run against the extracted tarball is unaffected. The env var is
  # undocumented Minilla internals -- WorkDir's call-site comment is
  # literally "DO NOT USE THIS ENVIRONMENT VARIABLE." -- so a Minilla
  # rename would make this stop working silently.
  local $ENV{MINILLA_DISABLE_WRITE_RELEASE_TEST} = 1;

  # Run the pipeline - dep install and dist-test both - resolving solely from
  # the contained lib. Stripping (not extending) PERL5LIB is deliberate: it
  # forces the dist's tests to resolve only from its declared closure, so a
  # dependency used but not declared in the cpanfile fails the release instead
  # of silently resolving from mist's shared perl5. This affects child procs
  # (cpanm, the test scripts) only; the running mist process keeps mist's perl5
  # in its in-memory @INC, so Minilla's own lazy loads are unaffected.
  local $ENV{PERL5LIB} = join $Config{path_sep}, @cleanroom_inc;

  # Minilla's release steps honour --dry-run (no version bump, no Changes
  # rewrite, no commit, no tag, no push - they log what they would do), and the
  # clean-room dist-test still runs as a real validation. Skip the trailing
  # `dist` for a dry-run (it does not parse --dry-run and should leave no
  # tarball). Suppress Minilla's own CheckChanges where we already gated it above
  # (dry-run / non-interactive); a real release on a terminal keeps the
  # interactive prompt.
  local $ENV{PERL_MINILLA_SKIP_CHECK_CHANGE_LOG};
  $ENV{PERL_MINILLA_SKIP_CHECK_CHANGE_LOG} = 1 if $dry_run or not -t STDIN;

  my $minil = Minilla::CLI->new();
  $minil->run( release => @minil_args );

  if ( $dry_run ) {
    # A dry-run whose tests pass but whose candidate is empty is promotable on
    # every other check and then starves the real release. Refuse to advertise
    # one: the closure has to be on disk for the promote to reuse it, and a
    # passing dry-run does not prove that on its own, because its own test run
    # can be satisfied from elsewhere on @INC.
    unless ( _candidate_holds_closure( _candidate_dir( $ctx, $candidate ) ) ) {
      _remove_release_candidate( $ctx, $candidate );
      die "mist release: the dry-run validated but installed no modules into its\n"
        . "release candidate, so there is nothing for --candidate to reuse.\n"
        . "Candidate discarded. Re-run `mist release --dry-run`.\n";
    }

    # The build validated. Stamp the candidate with the current fingerprint -
    # its presence also marks the dry-run as having completed, and rewriting it
    # on a reuse run resets the age window's clock to this proof - then print
    # the exact promote command. The "mist release --candidate=" prefix is
    # stable so it can be scraped from the output.
    _write_candidate_fingerprint( $ctx, $lib_dir );
    printf STDERR
        "\nmist release: dry-run validated; %s.\n"
      . "Release this validated build with: mist release --candidate=%s\n",
        ( $reuse ? 'reused candidate re-stamped'
                 : 'build kept as release candidate' ),
        $candidate;
    return;
  }

  $minil->run( dist => '--no-test', @minil_args );

  # The promoted candidate stays cached. Its fingerprint ignores the dist's own
  # version, so the closure it holds remains valid across the release bump and
  # the next release cycle's dry-run reuses it. Retiring a candidate is the
  # dry-run GC's job - environment change, age or --fresh, never promotion.
}

# The contained lib's @INC paths, arch-first to match local::lib / perl's own
# ordering so an XS dist whose .pm ships in the arch dir resolves before a
# pure-perl namesake. Used both as cpanm's --local-lib-contained target and as
# the dist-test's PERL5LIB.
sub _cleanroom_inc {
  my $dir = shift;
  return (
    File::Spec->catdir( $dir, qw/ lib perl5 /, $Config{archname} ),
    File::Spec->catdir( $dir, qw/ lib perl5 / ),
  );
}

# Install the dist's declared prereq closure from the pinned mpan-dist mirror
# into the contained lib $dir. --local-lib-contained keeps the install out of
# mist's own perl5 and treats only $dir + core as satisfied, so the full
# closure builds there. --notest: the pinned mpan-dist set is the vetting; a
# dependency's own (often fragile) suite must not be able to block a release.
sub _install_prereqs_contained {
  my ( $cpanm, $mirror, $dir ) = @_;
  # cpanm unpacks dist tarballs with GNU tar, which is noisy about the pax
  # SCHILY.*/LIBARCHIVE.* headers they carry - silence that.
  local $ENV{TAR_OPTIONS} = '--warning=no-unknown-keyword';
  # Installing the closure is not release-testing OUR dist. DistTest sets
  # RELEASE_TESTING=1; under it Test::Requires turns a dependency's missing
  # *optional* test-dep into a hard BAIL_OUT. Clear it for the install - our
  # own dist still gets tested with RELEASE_TESTING in run_tests.
  delete local $ENV{RELEASE_TESTING};
  printf STDERR
      "mist release: installing prereqs from mpan-dist\n"
    . "  perl   : %s (v%vd)\n"
    . "  cpanm  : %s\n"
    . "  mirror : %s\n"
    . "  target : %s\n",
    $^X, $^V, "$cpanm", $mirror, $dir;
  system( $^X, "$cpanm", '--quiet', '--notest', '--installdeps',
          '--local-lib-contained', $dir,
          '--mirror', $mirror, '--mirror-only', '.' ) == 0
    or die "mist release: cpanm --installdeps failed against ${mirror}\n";
}

# Pull --candidate=<id> off a copy of @$args (left untouched - it is forwarded to
# Minilla verbatim) and return ( $id_or_undef, @args_without_candidate ).
# pass_through leaves every other option, including --dry-run, in place and in
# order. Minilla does not know --candidate, so it must not reach it.
sub _extract_candidate {
  my $args = shift;
  my @rest = @$args;
  my $id;
  local $SIG{__WARN__} = sub {};
  Getopt::Long::Parser->new( config => [ 'pass_through' ] )
    ->getoptionsfromarray( \@rest, 'candidate=s' => \$id );
  return ( $id, @rest );
}

# Boolean sibling of _extract_candidate: pull --fresh off a copy of @$args
# (Minilla does not know it either) and return ( $bool, @args_without_fresh ).
sub _extract_fresh {
  my $args = shift;
  my @rest = @$args;
  my $fresh = 0;
  local $SIG{__WARN__} = sub {};
  Getopt::Long::Parser->new( config => [ 'pass_through' ] )
    ->getoptionsfromarray( \@rest, 'fresh' => \$fresh );
  return ( $fresh ? 1 : 0, @rest );
}

# Release candidates live under the per-project mist workspace (~/.mist/<proj>/),
# out of the source tree entirely - no gitignore needed, and the dir persists
# between the dry-run process and the later promote process.
sub _candidates_root { $_[0]->workspace->subdir( 'release-candidates' ) }
sub _candidate_dir   { _candidates_root( $_[0] )->subdir( $_[1] ) }

# Keyed eviction, not a wipe: a candidate whose stamp still matches the current
# environment (and sits inside the age window) is kept and returned for reuse;
# everything else - debris without a stamp, stale fingerprints, over-age builds
# - is deleted, each with its reason. $evict_all (--fresh) retires even a valid
# candidate. At most one survives: should interrupted runs ever leave several
# valid ones, the most recently stamped wins.
sub _gc_release_candidates {
  my ( $ctx, $evict_all ) = @_;
  my $root = _candidates_root( $ctx );
  return unless -d $root->stringify;
  my @fresh;
  for my $child ( sort { $a->basename cmp $b->basename } $root->children ) {
    next unless $child->is_dir;
    my $why = $evict_all ? 'a fresh build was requested'
                         : _candidate_staleness( $ctx, $child );
    if ( not $why ) {
      push @fresh, $child;
      next;
    }
    printf STDERR "mist release: evicted candidate %s - %s\n",
      $child->basename, $why;
    $child->rmtree;
  }
  @fresh =
    sort { _candidate_stamp_mtime( $b ) <=> _candidate_stamp_mtime( $a ) }
    @fresh;
  my $keep = shift @fresh;
  for my $surplus ( @fresh ) {
    printf STDERR
      "mist release: evicted candidate %s - superseded by a newer build\n",
      $surplus->basename;
    $surplus->rmtree;
  }
  return $keep;
}

sub _remove_release_candidate {
  my ( $ctx, $id ) = @_;
  return unless defined $id;
  my $dir = _candidate_dir( $ctx, $id );
  $dir->rmtree if -d $dir->stringify;
}

# Candidate ids are used unsanitised as a directory name under the workspace, so
# they must stay within the hex+dash shape _new_candidate_id emits - this is the
# guard against a crafted --candidate escaping the workspace (e.g. '../../etc').
sub _valid_candidate_id {
  my $id = shift;
  return defined $id && $id =~ /\A[0-9a-fA-F-]{1,64}\z/ ? 1 : 0;
}

# A fresh, unique, UUID-shaped handle per dry-run. The id is an ephemeral label,
# never re-derived, so uniqueness - not cryptographic strength - is all it needs;
# /dev/urandom when available, a hash of pid+time+rand otherwise.
sub _new_candidate_id {
  my $bytes;
  if ( open my $rand, '<:raw', '/dev/urandom' ) {
    read $rand, $bytes, 16;
    close $rand;
  }
  unless ( defined $bytes and length $bytes == 16 ) {
    $bytes = substr Digest::SHA::sha256( join( '-', $$, time, rand ) ), 0, 16;
  }
  my $hex = unpack 'H*', $bytes;
  return join '-',
    map { substr $hex, $_->[0], $_->[1] }
    [ 0, 8 ], [ 8, 4 ], [ 12, 4 ], [ 16, 4 ], [ 20, 12 ];
}

# Fingerprint of everything that decides the dependency closure: the perl + arch
# the lib was built for, plus the cpanfile, mistfile and mpan-dist index. Stored
# with a candidate and rechecked at promote time so a changed dependency set (or
# a perl switch, which would invalidate the lib's XS) refuses the promote rather
# than shipping against a stale closure. The dist's OWN version is deliberately
# absent - bumping it does not change the closure, so the candidate stays valid
# across the release bump.
sub _release_fingerprint {
  my $ctx = shift;
  return _fingerprint(
    "$^V", $Config{archname},
    $ctx->cpanfile->stringify,
    $ctx->project_root->file( 'mistfile' )->stringify,
    $ctx->mpan_dist->file(qw/ modules 02packages.details.txt.gz /)->stringify,
  );
}

# Pure: SHA-256 of perl + arch + each file's path and (if present) contents. A
# missing file contributes only its path, so the digest is stable either way.
sub _fingerprint {
  my ( $perl, $arch, @files ) = @_;
  my $sha = Digest::SHA->new( 256 );
  $sha->add( "perl\0${perl}\0arch\0${arch}\0" );
  for my $file ( @files ) {
    $sha->add( "file\0${file}\0" );
    if ( -f $file and open my $fh, '<', $file ) {
      binmode $fh;
      $sha->addfile( $fh );
      close $fh;
    }
    $sha->add( "\0" );
  }
  return $sha->hexdigest;
}

sub _fingerprint_file {
  my $dir = shift;
  return File::Spec->catfile( "$dir", '.mist-release-fingerprint' );
}

sub _write_candidate_fingerprint {
  my ( $ctx, $dir ) = @_;
  my $file = _fingerprint_file( $dir );
  open my $fh, '>', $file
    or die "mist release: cannot write candidate fingerprint ${file}: $!\n";
  print {$fh} _release_fingerprint( $ctx ), "\n";
  close $fh;
}

# Reuse trust window. The fingerprint covers the inputs that decide the closure
# but not the toolchain underneath it (compiler, glibc, system libraries), so a
# fingerprint match alone must not vouch for a candidate forever. Two weeks
# spans a release burst comfortably; anything older rebuilds. The clock resets
# on every green dry-run, which rewrites the stamp.
use constant CANDIDATE_MAX_AGE_DAYS => 14;

# The stamp file's mtime is the "last validated" clock: the stamp is
# (re)written on every green dry-run, so age measures the latest proof, not the
# first build.
sub _candidate_stamp_mtime {
  my $dir = shift;
  my @st = stat _fingerprint_file( $dir );
  return @st ? $st[9] : 0;
}

# Returns a reason string (true) if the candidate must NOT be reused, or '' when
# it is fresh. Fail closed: a missing/unreadable fingerprint counts as stale.
sub _candidate_staleness {
  my ( $ctx, $dir ) = @_;
  my $file = _fingerprint_file( $dir );
  return 'no fingerprint (the dry-run did not complete)' unless -f $file;
  open my $fh, '<', $file or return 'fingerprint unreadable';
  my $stored = readline $fh;
  close $fh;
  $stored //= '';
  chomp $stored;
  return 'cpanfile, mistfile, mpan-dist or perl changed since the dry-run'
    if $stored ne _release_fingerprint( $ctx );
  my $age_days = ( time - _candidate_stamp_mtime( $dir ) ) / ( 24 * 60 * 60 );
  return sprintf 'last validated %.0f days ago (reuse window is %d days)',
      $age_days, CANDIDATE_MAX_AGE_DAYS
    if $age_days > CANDIDATE_MAX_AGE_DAYS;
  # The fingerprint only attests to the inputs that decide the closure, never
  # that the closure was installed. A candidate holding just a fingerprint passes
  # every other check and then starves DistTest of its own prereqs - after
  # RegenerateFiles has bumped the version, so it fails mid-pipeline and leaves
  # the tree dirty. Refuse it up front instead.
  return 'the candidate holds no installed modules (the dry-run built nothing)'
    unless _candidate_holds_closure( $dir );
  return '';
}

# Cheap presence check, not an inventory: any .pm under the candidate's local-lib
# means cpanm populated it. An empty or lib-less candidate is the failure worth
# catching; a partial one still fails loudly at DistTest, which is where a
# genuinely broken closure belongs.
sub _candidate_holds_closure {
  my $dir = shift;
  # Stringified like _fingerprint_file: callers pass a Path::Class::Dir or a
  # plain path interchangeably.
  my $lib = File::Spec->catdir( "$dir", 'lib', 'perl5' );
  return 0 unless -d $lib;

  my $found = 0;
  File::Find::find(
    { no_chdir => 1,
      wanted   => sub { $found = 1 if not $found and /\.pm\z/ } },
    $lib,
  );
  return $found;
}

# True if @$args asks for a dry run, parsed the way Minilla will parse it.
# Minilla::CLI::Release runs the args through Getopt::Long with its default
# config (auto_abbrev on), so `--dry`, `--dry-r`, ... all reach it as
# `--dry-run`. A plain `grep { $_ eq '--dry-run' }` here would miss those
# abbreviations, leaving mist's view of dry-run out of step with Minilla's -
# mist would run the trailing `dist` and leave a tarball for what Minilla
# treated as a dry run. Probe a copy so @$args (forwarded to Minilla
# verbatim) is untouched; pass_through ignores every other release option.
sub _args_request_dry_run {
  my $args = shift;
  my @probe = @$args;
  my $dry_run = 0;
  local $SIG{__WARN__} = sub {};
  Getopt::Long::Parser->new( config => [ 'pass_through' ] )
    ->getoptionsfromarray( \@probe, 'dry-run!' => \$dry_run );
  return $dry_run;
}

# True if Changes has at least one entry under the {{$NEXT}} marker, matching
# Minilla::Release::CheckChanges' own regex so the gate stays consistent with it.
sub _changes_has_next_entry {
  return 0 unless -f 'Changes';
  open my $fh, '<', 'Changes' or return 0;
  my $changes = do { local $/; <$fh> };
  return $changes =~ /^\{\{\$NEXT\}\}\h*\R+\h+\S/m ? 1 : 0;
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::release - tag, test and package a full release

=head1 SYNOPSIS

  mist release
  mist release --dry-run [--fresh]
  mist release --candidate=<ID>

=head1 DESCRIPTION

Runs the full L<Minilla> release pipeline for the current project: it
builds a distribution tarball and runs the test suite B<against the
extracted tarball> -- a clean-room check that catches files missing from
the dist -- then tags and commits the release. It then runs C<dist
--no-test> to leave a built tarball in place (Minilla's C<release>
followed by C<dist --no-test>).

The dependency closure is installed into a throwaway contained lib, never into
the C<perl5> environment mist itself runs under, so a release cannot mutate - or,
on a failed install, corrupt - mist's own environment. The extracted-tarball
test suite then runs against only that contained lib, so a module used at run
time or in F<t/> but not declared in the project's F<cpanfile> fails the release
rather than silently resolving from mist's shared C<perl5>.

This hermetic check is the B<test> phase. The build/configure step
(F<Makefile.PL> / F<Build.PL>) is run by Minilla with mist's own C<@INC> passed
through on C<-I>, which overrides the stripped C<PERL5LIB>, so a dependency
needed only at configure time can still resolve from mist's C<perl5> and is not
caught here - declare configure-time prereqs explicitly.

C<mist release> B<refuses to run> unless F<minil.toml> sets
C<[release] do_not_upload_to_cpan> -- a guard against an accidental CPAN
push, since mist no longer targets CPAN publishing. For a genuine CPAN
upload, run C<minil release> directly.

With C<--dry-run> the full pipeline runs - including the clean-room dist-test -
but the mutating steps only report what they would do: no version bump, no
F<Changes> rewrite, no commit, no tag, and no push. Use it to confirm a release
would build and test cleanly before committing to it. Like a real release it
requires a F<Changes> entry under C<{{$NEXT}}> and fails fast if there is none,
so a dry-run predicts that block rather than passing over it.

=head2 Reusing a dry-run's build with C<--candidate>

A C<--dry-run> additionally keeps its validated contained lib on disk as a
B<release candidate> under the project's mist workspace, and prints the command
to promote it:

  Release this validated build with: mist release --candidate=<ID>

C<mist release --candidate=<ID>> then runs a normal release but B<reuses> that
candidate's already-installed dependency closure instead of installing it again.
This matters when the install is the slow part: a large closure can take a long
time to build, and dry-run-then-release otherwise pays for it twice. Only the
install is skipped - the release still bumps the version, rebuilds the tarball at
the new version, and re-runs the clean-room dist-test against the reused lib.

The candidate persists and is keyed by a fingerprint stored with it - the
F<cpanfile>, F<mistfile>, the mpan-dist index, and the perl version and
architecture. A later C<--dry-run> whose environment still matches that
fingerprint B<reuses> the candidate's installed closure instead of installing
it again: only the clean-room dist-test runs, against the then-current tree,
and a green run re-stamps the candidate. A dry-run whose environment changed
evicts the stale candidate and builds a fresh one; pass C<--fresh> to force
that rebuild even when the fingerprint still matches. Promoting a candidate
does not retire it - the dist's own version is not part of the fingerprint, so
the version bump a release performs does not invalidate it, and the next
release cycle's dry-run picks it up again.

The fingerprint is written only after a green clean-room dist-test, so a
candidate always carries a two-way promise: its closure was built for the
current environment, B<and> at least one version of the project has passed its
test suite against it. A candidate without that stamp - a dry-run that did not
finish, or one whose dist-test failed - is never reused and is deleted at the
next dry-run. A failed dry-run against a reused candidate keeps the earlier
stamp: the earlier proof stands, and the promote-side dist-test still validates
whatever tree is actually released.

Reuse is bounded in time as well: a candidate whose last green dry-run is more
than 14 days old is refused even on a matching fingerprint, because the
fingerprint does not cover the toolchain underneath the closure (compiler,
system libraries). Whatever the reason - changed environment, age, or a missing
stamp - a stale candidate is never reused, and C<--candidate> B<refuses> to
promote it, asking for a fresh C<--dry-run> instead.

A real release run without a terminal (CI, a background job) also fails fast on
a missing C<{{$NEXT}}> entry instead of hanging on the interactive
edit-the-changelog prompt; an interactive release still gets that prompt. That
fail-fast covers the changelog prompt only - it is not a general guarantee of
non-interactive operation. If the current version's tag is already on origin the
version-bump step prompts for the next version (defaulting silently when there is
no terminal, after writing the bumped version into the source files). Prefer
running a real release on a terminal.

Releasing at the end of a prerelease cycle does not prompt: the current version
is a trial release, so the next version is computed by dropping the trial
component rather than being asked for - C<0.52_02> releases as C<0.53>.

To hand an unreleased change to a sibling project for testing, use
L<mist prerelease|App::Mist::Command::prerelease>, which advances the trial
version and tags locally without building, testing or pushing a tarball. Extra
arguments are passed through to Minilla.

=head1 SEE ALSO

L<App::Mist::Command::prerelease>, L<App::Mist::Command::build_dist>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
