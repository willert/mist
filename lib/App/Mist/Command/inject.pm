package App::Mist::Command::inject;
# ABSTRACT: inject the given dists into mpan-dist

use 5.010;

use App::Mist -command;

use Path::Class qw/ dir /;
use Mist::PackageManager::MPAN;

sub usage_desc { '%c inject %o <module-spec>...' }

sub opt_spec {
  return (
    [ 'from=s@' => "resolve from this peer project's mpan-dist instead of CPAN (mirror-only; repeatable)" ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  die "$0: No module to install"
    unless $args and ref $args eq 'ARRAY' and @$args;

  # Each --from is a peer project root; we source from its mpan-dist. Validate
  # before the perlbrew re-exec so a wrong path fails fast and loud.
  my @peer_mirrors;
  for my $peer ( @{ $opt->from || [] } ) {
    my $mpan = dir( $peer )->absolute->subdir( 'mpan-dist' );
    die "$0: --from '$peer' has no mpan-dist (looked in $mpan)\n"
      unless -d "$mpan";
    push @peer_mirrors, sprintf 'file://%s/', $mpan->resolve;
  }

  $ctx->ensure_correct_perlbrew_context;

  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $ctx->project_root,
    local_lib    => $ctx->local_lib,
    workspace    => $ctx->workspace_lib,

    # --from sources strictly from the file:// mirrors, never live CPAN: you get
    # the peer's vetted version or a loud failure, not a silent CPAN tip.
    ( @peer_mirrors ? ( mirror_only => 1 ) : () ),
  });

  $package_manager->add_mirror( $_ ) for @peer_mirrors;

  $package_manager->begin_work;
  eval { $package_manager->install( @$args ) };
  my $install_error = $@;
  $package_manager->commit;
  die $install_error if $install_error;
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::inject - stage distributions into the project's mpan-dist

=head1 SYNOPSIS

  mist inject Module::Name
  mist inject Module::Name@1.23
  mist inject 'Module::Name~>= 1.20, < 2.0'
  mist inject ./Some-Dist-1.00.tar.gz
  mist inject --reinstall JSON::PP             # force a core module in
  mist inject Foo::Bar Baz::Qux                # several in one go
  mist inject --from ../core Foo::Bar@2.0      # pull a peer's vetted version

=head1 DESCRIPTION

Stages one or more distributions into the project's bundled CPAN mirror,
F<./mpan-dist/>, and re-indexes it. This is how a dependency becomes
available to the fatpacked F<mpan-install> installer, which is what makes
builds reproducible and independent of CPAN's availability.

Each argument is handed to the embedded C<cpanm>, so any module spec
C<cpanm> understands works:

=over

=item *

C<Module::Name> -- the current release.

=item *

C<Module::Name@1.23> -- that exact version.

=item *

C<Module::Name~1.23> -- that version or newer.

=item *

C<< 'Module::Name~>= 1.20, < 2.0' >> -- a cpanfile-style version range.
Quote it: it contains spaces. Reach for a range when a bare name would
resolve to the wrong release -- for instance a distribution that maintains
two parallel version lines, where the highest version number is not the
one you want.

=item *

A filesystem path or URL to a tarball -- injected verbatim.

=back

Options are forwarded the same way, so C<cpanm>'s own flags work here too.
The one to know is C<--reinstall>:

=over

=item *

C<--reinstall> forces C<cpanm> to fetch and build a distribution even when
it is already satisfied -- including modules that ship with the Perl core.
A plain C<inject> of an already-satisfied module is a no-op and saves
B<nothing> into F<mpan-dist/>; C<--reinstall> is what makes the tarball
actually land in the mirror. Use it whenever you need to vendor a core (or
already-installed) module:

  mist inject --reinstall JSON::PP

=item *

C<-n> / C<--notest> skips the test suite for this inject; C<--verbose>
counteracts the C<--quiet> that C<inject> otherwise runs C<cpanm> with --
handy when an inject misbehaves.

=back

=head2 Sourcing from a peer project with C<--from>

C<--from> I<PATH> resolves the requested dist and its dependencies against
another mist project's F<mpan-dist/> instead of CPAN. Reach for it to pull a
version a peer project has already vetted -- a CVE fix whose set of
working dependency versions that peer worked out -- rather than whatever CPAN
serves today.

It is strictly mirror-only: the sources are this project's F<mpan-dist> and the
peer's, with B<no> live-CPAN fallback. A dependency present in neither mirror is
a loud failure, not a silent fetch from CPAN, so what lands is the peer's vetted
set or nothing. C<--from> is repeatable to layer several peers; this project's
own mirror is always consulted first, so it never downgrades a version you
already vendor. Pin the version you want (C<Module@2.0> or
C<< 'Module~>= 2.0' >>) -- a bare name resolves to your own copy whenever you
already have a satisfying one.

C<--from> takes a peer I<project root> (its F<mpan-dist/> is what gets used).
Like a plain C<inject> it records nothing about the peer: it touches neither
F<cpanfile> nor F<mistfile>. To instead fold a peer's whole declared set and
record the relationship, that is L<mist merge|App::Mist::Command::merge>.

C<inject> changes three things:

=over

=item *

the selected tarball(s) land under F<mpan-dist/authors/id/...>;

=item *

F<mpan-dist/modules/02packages.details> and its F<.txt.gz> companion are
re-indexed to point at them;

=item *

the distribution is also installed into the live F<./perl5/>, so an
C<inject> doubles as an install of that module.

=back

What C<inject> does B<not> do is touch F<cpanfile>. Staging a dist makes it
I<available>; it does not I<declare> it as a dependency. After injecting,
add or bump the C<requires> line in F<cpanfile> yourself, then run
C<mist compile> followed by C<./mpan-install>.

Everything C<inject> writes under F<mpan-dist/> is version-controlled.
Commit those files together with the matching F<cpanfile> change -- the
tarball, the re-indexed F<02packages.*>, and the C<requires> line are one
logical commit.

=head1 SEE ALSO

L<App::Mist::Command::compile>, L<App::Mist::Command::upgrade>,
L<App::Mist::Command::index>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
