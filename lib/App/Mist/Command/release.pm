package App::Mist::Command::release;
# ABSTRACT: run full release of the distribution package

use 5.010;

use App::Mist -command;
use Minilla::CLI;

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $inc{'CPAN/Uploader.pm'} //= __FILE__; }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;

  my $minil = Minilla::CLI->new();
  $minil->run( release => @$args );
  $minil->run( dist => '--no-test', @$args );
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::release - tag, upload and package a full release

=head1 SYNOPSIS

  mist release

=head1 DESCRIPTION

Runs a full L<Minilla> release of the current project: it tags the release
and uploads it to CPAN, then builds the distribution tarball (Minilla's
C<release> followed by C<dist --no-test>).

This B<publishes to CPAN>. For a release that stays in-house, use
L<mist local_release|App::Mist::Command::local_release>. Extra arguments are
passed through to Minilla.

=head1 SEE ALSO

L<App::Mist::Command::local_release>, L<App::Mist::Command::build_dist>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
