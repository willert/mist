package App::Mist::Command::local_release;
# ABSTRACT: run limited local tag and release of package

use 5.010;

use App::Mist -command;
use Minilla::CLI;

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $inc{'CPAN/Uploader.pm'} //= __FILE__; }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;
  Minilla::CLI->new()->run( local_release => @$args );
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::local_release - release this project without uploading to CPAN

=head1 SYNOPSIS

  mist local_release

=head1 DESCRIPTION

Runs L<Minilla>'s C<local_release>: it tags and releases the current
project as a distribution but does B<not> upload it to CPAN. Use it for
in-house distributions that are shared through other channels -- a private
mirror, or another project's C<mist merge>.

Extra arguments are passed through to Minilla.

=head1 SEE ALSO

L<App::Mist::Command::release>, L<App::Mist::Command::build_dist>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
