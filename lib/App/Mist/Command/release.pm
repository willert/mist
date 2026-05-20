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
