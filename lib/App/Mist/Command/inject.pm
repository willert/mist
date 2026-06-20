package App::Mist::Command::inject;
# ABSTRACT: inject the given dists into mpan-dist

use 5.010;

use App::Mist -command;

use Path::Class qw/ dir /;
use File::Temp qw/ tempdir /;
use JSON::PP ();
use CPAN::PackageDetails;
use Mist::PackageManager::MPAN;
use Mist::Bundle;

sub usage_desc { '%c inject %o <module-spec>...' }

sub opt_spec {
  return (
    [ 'from=s@' => "resolve from this peer project's mpan-dist instead of CPAN (mirror-only; repeatable)" ],
    [ 'full-dependency-tree' => "raise the target's whole dependency tree to the peer's versions and write a bundle, without touching the live env (requires --from)" ],
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
  my @peer_dists;
  for my $peer ( @{ $opt->from || [] } ) {
    my $mpan = dir( $peer )->absolute->subdir( 'mpan-dist' );
    die "$0: --from '$peer' has no mpan-dist (looked in $mpan)\n"
      unless -d "$mpan";
    push @peer_mirrors, sprintf 'file://%s/', $mpan->resolve;
    push @peer_dists, $mpan;
  }

  die "$0: --full-dependency-tree needs at least one --from peer\n"
    if $opt->full_dependency_tree and not @peer_mirrors;

  $ctx->ensure_correct_perlbrew_context;

  return $self->_produce_bundle( $ctx, $args, \@peer_mirrors )
    if $opt->full_dependency_tree;

  # A bare module target under --from would resolve to this project's own
  # (possibly stale) copy: the project mirror is consulted first and any version
  # satisfies a bare name, so the peer's release is never reached - a silent
  # no-op. Pin each bare target to the peer's version as a >= floor, so it pulls
  # the peer's release when we are behind and stays put (no downgrade) when we
  # are already ahead. An explicit version/range/tarball target is left alone.
  @$args = map { _peer_floor( $_, \@peer_dists ) } @$args if @peer_dists;

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

# --full-dependency-tree: resolve the target's whole tree at the peer's floors and
# emit a bundle, without touching the live ./perl5. The resolve runs in a clean
# room - an empty lib forces cpanm to walk every non-core dependency, not just the
# unsatisfied ones, and a peer-first mirror list makes --cascade-search take the
# peer's higher version wherever it has one. --save-dists still vendors the
# resolved tarballs into this project's real mpan-dist, so producing the bundle and
# the mirror state that makes it reproducible is one pass.
sub _produce_bundle {
  my ( $self, $ctx, $args, $peer_mirrors ) = @_;

  my $clean_room = dir( tempdir( 'mist-fdt-XXXXXX', TMPDIR => 1, CLEANUP => 1 ) );

  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $ctx->project_root,
    local_lib    => $clean_room,
    workspace    => $ctx->workspace_lib,
    mirror_only  => 1,
  });

  # Peer-first: prepend in reverse so multiple --from peers keep their given
  # order ahead of this project's own mirror.
  $package_manager->prepend_mirror( $_ ) for reverse @$peer_mirrors;

  $package_manager->begin_work;
  eval { $package_manager->install( @$args ) };
  my $install_error = $@;
  $package_manager->commit;
  die $install_error if $install_error;

  my %floor = _resolved_floors( $clean_room );
  die "$0: --full-dependency-tree resolved nothing to vendor\n" unless %floor;

  my @specs = map { Mist::Bundle->spec_for( $_, $floor{ $_ } ) } sort keys %floor;

  my $id  = Mist::Bundle->new_id;
  my $dir = $ctx->workspace->subdir( 'bundles' );
  Mist::Bundle->new({ specs => \@specs })->save( $dir, $id );

  printf STDERR "Wrote bundle %s (%d floors) under %s\n", $id, scalar @specs, $dir;
  print "Apply with: ./mpan-install --bundle $id\n";
  return;
}

# Read back what a clean-room resolve installed into $lib: one floor per dist,
# keyed by the dist's main module, from cpanm's install.json receipts.
sub _resolved_floors {
  my ( $lib ) = @_;
  my %floor;
  for my $receipt ( glob "$lib/lib/perl5/*/.meta/*/install.json" ) {
    open my $fh, '<', $receipt or next;
    my $json = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP::decode_json( $json ) } or next;
    my $module  = $data->{name} // $data->{target} // next;
    my $version = $data->{version};
    next unless defined $version and length $version;
    $floor{ $module } = $version;
  }
  return %floor;
}

# Rewrite a bare module-name target into a >= floor at the peer's version, so a
# --from pull defaults to the peer's release without an explicit pin. Anything
# already carrying a version/range, or a tarball/path/URL, passes through.
sub _peer_floor {
  my ( $target, $peer_dists ) = @_;
  return $target unless $target =~ /\A[\w:]+\z/;   # bare Module::Name only

  my $version = _peer_module_version( $target, $peer_dists );
  die "$0: --from: '$target' is not in any peer mpan-dist - nothing to pull "
    . "(check the peer, or give an explicit version)\n"
    unless defined $version;

  return "$target~$version";
}

# Highest version of $module across the peers' 02packages indexes, or undef.
sub _peer_module_version {
  my ( $module, $peer_dists ) = @_;
  my $best;
  for my $mpan ( @$peer_dists ) {
    my $index = $mpan->file( 'modules', '02packages.details.txt.gz' );
    next unless -e "$index";

    my $details = do {
      local $SIG{__WARN__} = sub {
        print STDERR "@_\n" unless $_[0] =~ m{ \b uninitialized \b }x;
      };
      CPAN::PackageDetails->read( "$index" );
    };

    my $by_version = $details->entries->get_hash->{ $module } or next;
    for my $version ( keys %$by_version ) {
      $best = $version
        if not defined $best
        or Mist::Role::CPAN::PackageIndex::_version_cmp( $version, $best ) > 0;
    }
  }
  return $best;
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
set or nothing. C<--from> is repeatable to layer several peers.

A bare module target pulls the peer's version by default: C<--from> looks the
target up in the peer's index and pins it to that version as a C<< >= >> floor.
So C<mist inject --from ../core Foo::Bar> raises C<Foo::Bar> to the peer's
release when you are behind it, and leaves it alone when you are already ahead
(the floor is satisfied) -- never a downgrade, and no need to know the version.
If the target is not in any peer's mirror, that is a loud failure rather than a
silent fall-back to your own copy. Pass an explicit C<Module@2.0> or
C<< 'Module~>= 2.0' >> to force a specific version instead.

C<--from> takes a peer I<project root> (its F<mpan-dist/> is what gets used).
Like a plain C<inject> it records nothing about the peer: it touches neither
F<cpanfile> nor F<mistfile>. To instead fold a peer's whole declared set and
record the relationship, that is L<mist merge|App::Mist::Command::merge>.

=head2 Raising the whole dependency tree with C<--full-dependency-tree>

Plain C<--from> respects declared requirements: it raises a dependency only when
the target's metadata forces it, so a dep you already satisfy at an older version
stays put. C<--full-dependency-tree> instead trusts the peer's empirically-resolved
set over the loose C<< >= >> declarations and raises I<every> module in the
target's dependency tree to at least the peer's version. Reach for it when the
peer's mirror is the record of a solved problem - a CVE fix whose working version
set lives nowhere in the dependency metadata - and you want that whole set, not
just what the declarations admit. It requires at least one C<--from> and the long
name is deliberate: it is a rare rebaseline, not a reflex.

It does B<not> touch the live F<./perl5> and does B<not> install anything. It
resolves the tree in a clean room (so cpanm walks the whole tree, not just the
unsatisfied parts) with the peer's mirror consulted first, vendors the resolved
tarballs into this project's F<mpan-dist/>, and writes the resolved versions as a
B<bundle> - a floor-spec set you apply later, incrementally and atomically, with
C<< ./mpan-install --bundle <id> >>. The versions are inherited as floors, never a
clone: B's own graph still wins wherever it needs something newer, so the result
is C<max(your needs, the peer's floors)>, raise-only. The bundle id is printed on
completion. See L<Mist::Bundle> and L<mist bundle|App::Mist::Command::bundle>.

C<inject> (without C<--full-dependency-tree>) changes three things:

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
