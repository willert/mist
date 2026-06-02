package App::Mist::Command::release;
# ABSTRACT: run full release of the distribution package

use 5.010;

use App::Mist -command;
use Minilla::CLI;
use Minilla::Project;

use Config;
use File::Spec;
use File::Temp ();

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $INC{'CPAN/Uploader.pm'} //= __FILE__; }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;

  my $dry_run = grep { $_ eq '--dry-run' } @$args;

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

  # Install the released dist's dependency closure into a throwaway contained
  # lib, and (further down) run the dist-test against only that lib. This keeps
  # a release from mutating - or, on a failed install, corrupting - mist's own
  # perl5, the env the mist CLI itself runs under. See _install_prereqs_contained
  # and _cleanroom_inc below.
  my $cleanroom     = File::Temp::tempdir( CLEANUP => 1 );
  my @cleanroom_inc = _cleanroom_inc( $cleanroom );

  {
    no warnings 'redefine';
    *Minilla::Project::verify_prereqs = sub {
      return unless $Minilla::AUTO_INSTALL;
      _install_prereqs_contained( $cpanm, $mpan_mirror, $cleanroom );
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
  $minil->run( release => @$args );
  $minil->run( dist => '--no-test', @$args ) unless $dry_run;
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
  mist release --dry-run

=head1 DESCRIPTION

Runs the full L<Minilla> release pipeline for the current project: it
builds a distribution tarball and runs the test suite B<against the
extracted tarball> -- a clean-room check that catches files missing from
the dist -- then tags and commits the release. It then runs C<dist
--no-test> to leave a built tarball in place (Minilla's C<release>
followed by C<dist --no-test>).

The dependency closure is installed into a throwaway contained lib and the
tarball test runs hermetically against it, so a release never modifies the
C<perl5> environment mist itself runs under. Because the test resolves only
the dist's B<declared> dependencies, a module used but not listed in the
project's F<cpanfile> fails the release rather than silently resolving from
mist's shared C<perl5>.

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

A real release run without a terminal (CI, a background job) also fails fast on
a missing C<{{$NEXT}}> entry instead of hanging on the interactive
edit-the-changelog prompt; an interactive release still gets that prompt.

For a lightweight release that only bumps the version and tags the commit
-- without building or testing a tarball -- use
L<mist local_release|App::Mist::Command::local_release>. Extra arguments
are passed through to Minilla.

=head1 SEE ALSO

L<App::Mist::Command::local_release>, L<App::Mist::Command::build_dist>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
