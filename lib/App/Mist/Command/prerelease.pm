package App::Mist::Command::prerelease;
# ABSTRACT: cut a numbered pre-release for a sibling project to consume

use 5.010;

use App::Mist -command;
use Minilla::CLI;

# no thanks 'CPAN::Uploader'; <-- breaks on perl 5.40 and above
BEGIN { $INC{'CPAN/Uploader.pm'} //= __FILE__; }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  $ctx->ensure_correct_perlbrew_context;
  Minilla::CLI->new()->run( prerelease => @$args );
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::prerelease - cut a numbered pre-release for a sibling to consume

=head1 SYNOPSIS

  mist prerelease

=head1 DESCRIPTION

Advances the project to the next I<trial release> version, runs the test suite
in-tree, then commits and tags locally. Nothing is built, uploaded or pushed.

It exists for one cycle: a sibling project needs a change from this one, and
wants to test it before it is released. Run C<prerelease> here, then
C<mist merge> in the sibling - which builds a distribution from this
project's I<current checkout> - and the sibling can install and exercise it.
Iterate as often as needed; finish with L<mist release|App::Mist::Command::release>.

=head2 Version numbering

Each run advances the version: a stable C<0.52> becomes C<0.52_01>, and a
further run becomes C<0.52_02>. Every iteration is therefore a distinct
artifact, which is what lets a consumer's mirror hold several at once and
resolve the newest deterministically.

The counter hangs off the I<current> version rather than the one being worked
toward, which reads backwards and is not negotiable: C<X_01> sorts B<above>
C<X>, so numbering the prereleases of C<0.53> as C<0.53_01> would place them
above the release they precede, and a consumer requiring C<< >= 0.53 >> would
accept one. C<0.52_01> sits between C<0.52> and C<0.53>, so that requirement
correctly refuses it. A prerelease can never satisfy the floor of the release
it leads to.

L<mist release|App::Mist::Command::release> ends the line by dropping the trial
component: from C<0.52_02> it releases C<0.53>.

=head2 What it does not do

It builds no tarball and runs no clean-room test, so it does B<not> validate
the artifact a consumer receives - C<mist merge> builds that separately, from
this checkout. The first genuine validation of a distribution is
C<mist release>, which is why the cycle has to end there.

C<Changes> keeps its C<{{$NEXT}}> placeholder, so the command is re-runnable
and one entry covers an entire prerelease cycle.

=head2 A failed run leaves the version advanced

The version is written before the steps that regenerate metadata, commit and
tag, so a failure in any of those leaves the working tree with a bumped and
uncommitted C<$VERSION>. Re-running advances it again - the trial counter
therefore counts I<attempts>, not successful iterations, and a cycle that hit
two failures arrives at C<_03> having produced one usable prerelease. Nothing
is published and versions are free, so this is untidy rather than harmful;
C<git checkout> the main module to reset it.

The first run in a project that does not yet track its generated files is the
common instance. C<RegenerateFiles> writes F<META.json>, F<Makefile.PL> and
F<README.md>, and the commit step uses C<git commit -a>, which does not pick up
untracked files - so they are left behind and the I<next> run is refused by
C<CheckUntrackedFiles>. Commit them once and the cycle runs clean.

=head2 Pre-releases are not for production

A prerelease vendored into a consumer's C<mpan-dist/> is committable like any
other tarball, and nothing prevents it reaching a deployment. Keep the merge
uncommitted until the real release lands, or re-merge and commit that.

=head1 SEE ALSO

L<App::Mist::Command::release>, L<App::Mist::Command::merge>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
