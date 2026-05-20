package App::Mist::Command::local_release;
# ABSTRACT: run limited local tag and release of package

use 5.010;

use App::Mist -command;
use Minilla::CLI;

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $INC{'CPAN/Uploader.pm'} //= __FILE__; }

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

App::Mist::Command::local_release - cut a tagged release commit without building a tarball

=head1 SYNOPSIS

  mist local_release

=head1 DESCRIPTION

Cuts a release B<point> in the current project's own git history: it bumps
the version, updates F<Changes>, runs the test suite in-tree, then commits
and tags. It does B<not> build a distribution tarball and does B<not>
upload anything.

The tarball that other projects consume is built on demand by
L<mist merge|App::Mist::Command::merge>, which builds a fresh dist from a
sibling project's I<current checkout> -- so C<local_release>'s job is only
to leave that checkout at a clean, versioned, tagged commit.

Use L<mist release|App::Mist::Command::release> instead when you want the
full pipeline: a built tarball, clean-room tests against it, and a release
commit. Extra arguments are passed through to Minilla.

=head1 SEE ALSO

L<App::Mist::Command::release>, L<App::Mist::Command::build_dist>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
