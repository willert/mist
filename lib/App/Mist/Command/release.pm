package App::Mist::Command::release;
# ABSTRACT: run full release of the distribution package

use 5.010;

use App::Mist -command;
use Minilla::CLI;
use Minilla::Project;

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $INC{'CPAN/Uploader.pm'} //= __FILE__; }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;

  Minilla::Project->new->config->{release}{do_not_upload_to_cpan}
    or die "mist release: refusing to run.\n"
         . "minil.toml does not set [release] do_not_upload_to_cpan, so this\n"
         . "release could push to CPAN -- which mist no longer supports.\n"
         . "For a genuine CPAN upload, run `minil release` directly.\n";

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
  {
    no warnings 'redefine';
    *Minilla::Project::verify_prereqs = sub {
      return unless $Minilla::AUTO_INSTALL;
      # cpanm unpacks dist tarballs with GNU tar, which is noisy about the
      # pax SCHILY.*/LIBARCHIVE.* headers they carry -- silence that.
      local $ENV{TAR_OPTIONS} = '--warning=no-unknown-keyword';
      # Installing the dependency closure is not release-testing OUR dist.
      # DistTest sets RELEASE_TESTING=1; under it Test::Requires turns a
      # dependency's missing *optional* test-dep into a hard BAIL_OUT, so an
      # otherwise-fine dep tarball fails to install. Clear it for the install
      # -- our own dist still gets tested with RELEASE_TESTING in run_tests.
      delete local $ENV{RELEASE_TESTING};
      printf STDERR
          "mist release: installing prereqs from mpan-dist\n"
        . "  perl   : %s (v%vd)\n"
        . "  cpanm  : %s\n"
        . "  mirror : %s\n",
        $^X, $^V, "$cpanm", $mpan_mirror;
      system( $^X, "$cpanm", '--quiet', '--notest', '--installdeps',
              '--mirror', $mpan_mirror, '--mirror-only', '.' ) == 0
        or die "mist release: cpanm --installdeps failed against "
             . "${mpan_mirror}\n";
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

  my $minil = Minilla::CLI->new();
  $minil->run( release => @$args );
  $minil->run( dist => '--no-test', @$args );
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::release - tag, test and package a full release

=head1 SYNOPSIS

  mist release

=head1 DESCRIPTION

Runs the full L<Minilla> release pipeline for the current project: it
builds a distribution tarball and runs the test suite B<against the
extracted tarball> -- a clean-room check that catches files missing from
the dist -- then tags and commits the release. It then runs C<dist
--no-test> to leave a built tarball in place (Minilla's C<release>
followed by C<dist --no-test>).

C<mist release> B<refuses to run> unless F<minil.toml> sets
C<[release] do_not_upload_to_cpan> -- a guard against an accidental CPAN
push, since mist no longer targets CPAN publishing. For a genuine CPAN
upload, run C<minil release> directly.

For a lightweight release that only bumps the version and tags the commit
-- without building or testing a tarball -- use
L<mist local_release|App::Mist::Command::local_release>. Extra arguments
are passed through to Minilla.

=head1 SEE ALSO

L<App::Mist::Command::local_release>, L<App::Mist::Command::build_dist>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
