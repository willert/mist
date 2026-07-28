package App::Mist::Command::upgrade;
# ABSTRACT: catch ./perl5 up to vendored versions - optionally raising mpan-dist to a peer's first

use 5.010;

use App::Mist -command;

use Path::Class qw/ dir /;
use File::Copy qw/ copy /;

use Mist::CPAN::PackageIndex;
use Mist::Generation ();
use Mist::PackageManager::MPAN;
use Mist::Role::CPAN::PackageIndex ();

use CPAN::PackageDetails;

use Capture::Tiny qw/ capture /;

sub usage_desc { '%c upgrade %o' }

sub opt_spec {
  return (
    [ 'from=s'      => "[EXPERIMENTAL] raise mpan-dist to the versions vendored in this peer project's mpan-dist, then realise into ./perl5" ],
    [ 'vendor-only' => "with --from: update mpan-dist only, do not install into ./perl5 (realise later with ./mpan-install --rebuild)" ],
    [ 'dry-run'     => "with --from: print the raise plan (summary) and exit without changing anything" ],
    [ 'verbose|v'   => "with --from: list every raised package, not just the summary line" ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;

  die "$0: --vendor-only requires --from\n" if $opt->vendor_only and not $opt->from;
  die "$0: --dry-run requires --from\n"     if $opt->dry_run     and not $opt->from;

  my $ctx = $self->app->ctx;

  # Validate the peer before the perlbrew re-exec so a wrong path fails fast and loud.
  my $peer_mpan;
  if ( $opt->from ) {
    $peer_mpan = dir( $opt->from )->absolute->subdir( 'mpan-dist' );
    die "$0: --from '" . $opt->from . "' has no mpan-dist (looked in $peer_mpan)\n"
      unless -d "$peer_mpan";
    $peer_mpan = $peer_mpan->resolve;
  }

  $ctx->ensure_correct_perlbrew_context;

  return $self->_upgrade_from_peer( $ctx, $peer_mpan, $opt ) if $opt->from;

  $self->_catch_up_local_lib( $ctx );
}

# --from: raise this project's mpan-dist to the versions a peer has vendored.
# The raise set is computed by diffing the two 02packages indexes - NEVER the
# mutable ./perl5, which a `mist local` or ad-hoc cpanm test install can leave
# ahead of both mirrors, silently masking a needed raise. We copy the peer's
# higher-versioned tarballs in and rebuild the index from disk (the hand-dropped
# tarball path, as `mist index`). Then, unless --vendor-only, realise the raised
# mpan-dist into ./perl5 with the ordinary catch-up.
sub _upgrade_from_peer {
  my ( $self, $ctx, $peer_mpan, $opt ) = @_;

  print STDERR "[EXPERIMENTAL] 'upgrade --from' may change or be replaced by a "
    . "bundle producer; see docs/proposal-upgrade-from-peer.md\n";

  my $mine = _read_index( $ctx->mpan_dist );
  my $peer = _read_index( $peer_mpan );

  my ( $raise, $ambiguous, $tarball ) = _raise_plan( $mine, $peer );

  for my $a ( @$ambiguous ) {
    printf STDERR
      "[WARNING] %s: mine %s, peer %s - treated as equal, not raising; "
      . "pass an explicit version if that is wrong\n", @$a;
  }

  if ( not @$raise ) {
    printf "Already at or ahead of %s for every shared package\n", $peer_mpan;
    return;
  }

  printf "Raising mpan-dist to %s:\n", $peer_mpan;
  # Summary by default - a full sibling fast-forward is thousands of lines. The
  # per-package listing (name old -> new tarball) is behind --verbose.
  if ( $opt->verbose ) {
    printf "  %-40s %s -> %-10s %s\n", @$_ for @$raise;
  }
  printf "  (%d package%s across %d tarball%s)%s\n",
    scalar @$raise,        ( @$raise == 1        ? '' : 's' ),
    scalar keys %$tarball, ( keys %$tarball == 1 ? '' : 's' ),
    ( $opt->verbose ? '' : ' - pass --verbose to list them' );

  return if $opt->dry_run;

  _vendor_raise( $ctx->mpan_dist, $peer_mpan, $tarball );

  return if $opt->vendor_only;

  $self->_catch_up_local_lib( $ctx );
}

# Copy the chosen peer tarballs into the destination mpan-dist, then rebuild the
# index from disk. reindex_distributions walks every tarball lowest-version first
# with highest-version-wins, so the copied releases become the indexed ones and
# superseded tarballs are reported. This is the hand-dropped-tarball path
# (cf. mist index); it never runs cpanm and never touches ./perl5, so a vendoring
# can never be lost to a satisfied-install skip.
sub _vendor_raise {
  my ( $dest_mpan, $peer_mpan, $tarball ) = @_;

  my $src_root = $peer_mpan->subdir(qw/ authors id /);
  my $dst_root = $dest_mpan->subdir(qw/ authors id /);
  for my $rel ( sort keys %$tarball ) {
    my $src = $src_root->file( split m{/}, $rel );
    my $dst = $dst_root->file( split m{/}, $rel );
    die "$0: peer tarball missing: $src\n" unless -f "$src";
    $dst->parent->mkpath;
    copy( "$src", "$dst" ) or die "$0: copy $src -> $dst failed: $!\n";
  }

  Mist::CPAN::PackageIndex->new({ cpan_dist_root => $dest_mpan })
    ->reindex_distributions;
}

# Pure raise-set decision over two { module => { version, path } } index maps.
# Returns ( \@raise, \@ambiguous, \%tarball ):
#   @raise     - [ pkg, mine_ver, peer_ver, peer_path ], peer strictly higher
#   @ambiguous - [ pkg, mine_ver, peer_ver ], strings differ but compare equal
#   %tarball   - deduped peer paths to copy in
# Raise-only (never downgrade) and intersection-only: it moves packages I already
# vendor forward, and does not adopt packages the peer has that I never vendored
# (that is inject/merge, not upgrade).
sub _raise_plan {
  my ( $mine, $peer ) = @_;

  my ( @raise, @ambiguous, %tarball );
  for my $pkg ( sort keys %$mine ) {
    my $peer_entry = $peer->{ $pkg } or next;
    my $mine_ver   = $mine->{ $pkg }{ version };
    my $peer_ver   = $peer_entry->{ version };

    my $cmp = Mist::Role::CPAN::PackageIndex::_version_cmp( $peer_ver, $mine_ver );
    if ( $cmp > 0 ) {
      push @raise, [ $pkg, $mine_ver, $peer_ver, $peer_entry->{ path } ];
      $tarball{ $peer_entry->{ path } } = 1;
    }
    # Strings differ but _version_cmp calls them equal: the one documented
    # comparator edge (e.g. 0.05 vs 0.5) that would otherwise SILENTLY skip a
    # real raise. Surface it instead of trusting the verdict blind.
    elsif ( $cmp == 0 and $peer_ver ne $mine_ver ) {
      push @ambiguous, [ $pkg, $mine_ver, $peer_ver ];
    }
  }

  return ( \@raise, \@ambiguous, \%tarball );
}

# Read an mpan-dist's 02packages into { module => { version, path } }, keeping the
# highest version per module (an index may list a package at more than one
# version). Same read path as inject.pm's peer lookup.
sub _read_index {
  my ( $mpan_dir ) = @_;
  my $index = $mpan_dir->file(qw/ modules 02packages.details.txt.gz /);
  return {} unless -e "$index";

  my $details = do {
    local $SIG{__WARN__} = sub {
      print STDERR "@_\n" unless $_[0] =~ m{ \b uninitialized \b }x;
    };
    CPAN::PackageDetails->read( "$index" );
  };

  my %map;
  my $by_pkg = $details->entries->get_hash;   # { pkg => { version => $entry } }
  for my $pkg ( keys %$by_pkg ) {
    for my $version ( keys %{ $by_pkg->{ $pkg } } ) {
      my $entry = $by_pkg->{ $pkg }{ $version };
      next unless defined $version and length $version;
      if ( not exists $map{ $pkg }
        or Mist::Role::CPAN::PackageIndex::_version_cmp(
             $version, $map{ $pkg }{ version } ) > 0 ) {
        $map{ $pkg } = { version => $version, path => $entry->path };
      }
    }
  }
  return \%map;
}

# The ordinary upgrade, also reused as the --from realise step: catch ./perl5 up
# to the versions vendored in this project's own (possibly just-raised) mpan-dist.
# cpan-outdated compares each installed module against the mirror's index and the
# laggards are reinstalled from the mirror. A ./perl5 that is *ahead* (a test
# install) is simply not reported, so nothing is downgraded.
#
# Deciding what is stale is upgrade's own job - that comparison is exactly what
# mpan-install cannot make, since cpanm only upgrades a dist it is *named*, never
# one reached as an already-satisfied prereq of something else. Mutating the live
# environment is not upgrade's job: the laggards are built into a fresh
# copy-on-write generation, which is promoted and activated only once the build
# succeeds, so a failed upgrade leaves the environment it was upgrading intact and
# the generation it would have replaced is still there to roll back to.
#
# That goes through Mist::Generation - the same ladder ./mpan-install uses - rather
# than by shelling out to ./mpan-install itself. The installer is a committed build
# artifact frozen at whenever someone last ran `mist compile`, so delegating to it
# would make this atomicity depend on the artifact's age: against a project still
# vendoring a pre-generation installer the guarantee would silently not hold.
#
# cpan-outdated still reads the live lib: what is installed *now* is the question
# being asked, so that one genuinely wants the active generation.
sub _catch_up_local_lib {
  my ( $self, $ctx ) = @_;

  my $mpan_dist_url = sprintf( 'file://%s/', $ctx->mpan_dist );

  my $cpan_outdated = File::Share::dist_file( 'App-Mist', 'cpan-outdated' );
  my @cpo_args = (
    '--mirror'              => $mpan_dist_url,
    '--local-lib-contained' => $ctx->local_lib,
  );

  # Dying inside the capture block would throw away the very output that explains
  # the failure, leaving a bare "Died". Capture first, then report.
  my ( $stdout, $stderr, $status ) = capture {
    system( $cpan_outdated, @cpo_args );
  };

  die sprintf "%s: cpan-outdated failed (exit %d) comparing %s against %s\n%s",
    $0, $status >> 8, $ctx->local_lib, $mpan_dist_url, $stderr
    if $status != 0;

  my @outdated = split qq{\n}, $stdout;

  if ( not @outdated ) {
    print "All modules up to date\n";
    return;
  }

  # @outdated carries cpan-outdated's default form, distribution paths
  # (AUTHOR/Dist-1.00.tar.gz) rather than module names. Naming the exact tarball is
  # what makes the upgrade happen at all: cpanm derives its skip decision from the
  # resolved dist, so a path pins the release the index offered, with no chance of
  # the request being read as already satisfied.
  my $perl5_base = $ctx->perl5_base_lib->stringify;
  my $arch_path  = Mist::Generation::arch_path();
  my $container  = Mist::Generation::container( $perl5_base );
  my $gen_name   = Mist::Generation::next_name(
    container => $container,
    arch_path => $arch_path,
  );

  printf "Upgrading %d outdated distribution%s into generation %s\n",
    scalar @outdated, ( @outdated == 1 ? '' : 's' ), $gen_name;

  my $build = Mist::Generation::stage(
    build_dir  => Mist::Generation::build_dir( $container, $gen_name ),
    perl5_base => $perl5_base,
    container  => $container,
    arch_path  => $arch_path,
    gen_name   => $gen_name,
  );

  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $ctx->project_root,
    local_lib    => dir( $build ),
    workspace    => $ctx->workspace_lib,
    mirror_list  => [ $mpan_dist_url ],
  });

  $package_manager->begin_work;
  eval { $package_manager->install( @outdated ) };
  my $install_error = $@;
  $package_manager->commit;

  # Bail out before promoting: an unpromoted ...-build dir is self-labelling junk,
  # and the environment this was upgrading is still the active one.
  die "$0: the upgrade failed, ./perl5 is unchanged:\n${install_error}"
    if $install_error;

  Mist::Generation::promote(
    build_dir => $build,
    final     => Mist::Generation::final_dir( $container, $gen_name ),
  );
  Mist::Generation::activate(
    dir( $perl5_base, $arch_path )->stringify,
    dir( 'generations', $gen_name )->stringify,
  );

  printf "Activated generation %s\n", $gen_name;

  return;
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::upgrade - catch ./perl5 up to vendored versions, optionally raising mpan-dist to a peer's

=head1 STATUS

Plain C<mist upgrade> is stable. The C<--from> family (C<--from>,
C<--vendor-only>, C<--dry-run>, C<--verbose>) is B<EXPERIMENTAL> and prints a
notice saying so. Its shape is unsettled: the leading proposal is to retire the
C<upgrade --from> framing entirely and re-home the peer-raise as a B<bundle
producer> (a sibling of C<inject --full-dependency-tree>), realised through
C<./mpan-install --bundle> rather than a live in-place install. Do not build
durable workflows on the C<--from> surface yet; the design and its open
questions live in F<docs/proposal-upgrade-from-peer.md>.

=head1 SYNOPSIS

  mist upgrade                       # catch ./perl5 up to this project's mpan-dist
  mist upgrade --from ../core        # raise mpan-dist to ../core's versions, then catch ./perl5 up
  mist upgrade --from ../core --vendor-only   # raise mpan-dist only; realise later with --rebuild
  mist upgrade --from ../core --dry-run       # print the raise plan (summary) and stop
  mist upgrade --from ../core --dry-run -v    # ... with the full per-package listing

=head1 DESCRIPTION

Two modes, on a single axis: C<inject> stages one (usually new) distribution;
C<upgrade> moves the whole installed base forward.

=head2 Plain C<mist upgrade>

Catches the project's installed F<./perl5/> up to the module versions vendored
in this project's own F<mpan-dist/>. Using the bundled C<cpan-outdated> helper,
it compares each module installed under F<perl5/> against the version recorded
in F<mpan-dist/>'s package index, and reinstalls - from F<mpan-dist/> - every
module whose installed copy lags behind. It prints C<All modules up to date>
when nothing lags.

This closes a gap that C<./mpan-install> cannot. C<mpan-install> resolves the
F<cpanfile> prerequisites through C<cpanm>, which reinstalls a distribution only
when its requirement is I<unsatisfied>: an older version that still satisfies the
F<cpanfile> pin is left untouched, even once F<mpan-dist/> vendors something
newer. C<upgrade> keys off the raw installed-versus-vendored comparison instead,
so it pulls the newer vendored release in regardless - without the full
F<perl5/> wipe and cold rebuild that would otherwise be the only way to get
there.

Deciding I<what> lags is all C<upgrade> decides. The laggards are then built into
a fresh copy-on-write generation, seeded from the active one, and that generation
is promoted and activated by the atomic symlink swap only once the build
succeeds - so a failed upgrade leaves the environment it was upgrading fully
intact, and the generation it replaces stays on disk to roll back to.

It runs the same ladder C<./mpan-install> does (L<Mist::Generation>) rather than
invoking the installer, so the guarantee does not depend on how recently that
committed artifact was regenerated. What it deliberately does not do is the rest
of an install: no F<mistfile> assertions, no C<prepare>/C<finalize> scripts, and
no regeneration of the F<perl5/bin> shims. The wrapper and rc need none - they
bake the generic C<perl5/E<lt>archE<gt>> path, which resolves through the
selector this repoints - but a dist whose I<newly> upgraded version ships a
script it did not ship before will not get a shim until the next
C<./mpan-install>.

=head2 C<mist upgrade --from> I<PATH> - be like a peer

C<--from> I<PATH> takes a peer mist project and raises this project's
F<mpan-dist/> to the versions the peer has vendored - the "project A works, make
me more like A" rebaseline of an existing, already-vendored dependency set. It
is the whole-base counterpart to C<inject --from>'s single named module.

The raise set is computed by diffing the two F<02packages> indexes - mine and
the peer's - and is B<raise-only> and B<intersection-only>: every package
present in both indexes where the peer's version is strictly higher than mine is
raised; packages the peer lacks, or is behind on, are left alone, and packages
the peer has that I never vendored are B<not> adopted (that is C<inject> or
C<merge>, not C<upgrade>).

Crucially the comparison is index-to-index and never inspects F<./perl5/>. A
C<mist local> or ad-hoc C<cpanm> test install can leave a module in F<./perl5/>
that is newer than both mirrors; deciding what to vendor from the live env would
let such an install silently mask a needed raise, leaving the committed
F<mpan-dist/> stale. The vendoring decision is therefore made entirely from the
persistent mirrors.

The peer's higher-versioned tarballs are copied into F<mpan-dist/authors/id/>
and the index is rebuilt from disk (the same path as a hand-dropped tarball - see
L<mist index|App::Mist::Command::index>). The result is a B<committable
F<mpan-dist/> diff> (the new tarballs plus the re-indexed F<02packages.*>);
commit it on its own. No F<cpanfile> change and no C<mist compile> are needed -
the C<requires> pins are unchanged and F<mpan-install> reads F<mpan-dist/> at
install time rather than embedding it.

Then, unless C<--vendor-only>, the raised F<mpan-dist/> is realised into
F<./perl5/> by the ordinary catch-up above (now sourced from the just-raised own
mirror). A F<./perl5/> that is already I<ahead> of a raised version - a test
install you want to keep - is left untouched: the realise never downgrades. To
get a F<./perl5/> that exactly matches the raised F<mpan-dist/>, rebuild a fresh
generation with C<./mpan-install --rebuild>.

=over

=item C<--vendor-only>

Stop after raising F<mpan-dist/>; do not touch F<./perl5/>. Realise the change
later, atomically, with C<./mpan-install --rebuild>. Requires C<--from>.

=item C<--dry-run>

Compute and print the raise plan, then exit without copying anything or touching
F<./perl5/>. Requires C<--from>.

=item C<--verbose> / C<-v>

List every raised package (C<name old -E<gt> new tarball>). By default only the
summary line is printed, because a full sibling fast-forward is thousands of
packages - the per-package firehose is opt-in. Requires C<--from>.

=back

=head2 Comparator note

Version comparison uses C<Mist::Role::CPAN::PackageIndex::_version_cmp>, which
reads versions as point releases (C<1.2 E<lt> 1.9 E<lt> 1.10>) and is robust for
the dotted and v-string versions real F<mpan-dist/> tarballs carry. It has a few
documented edge cases where decimal fractional widths differ (C<0.05> versus
C<0.5>). To keep the one case that could otherwise pass silently visible, the
ambiguity is always surfaced regardless of C<--verbose>: when two version
strings differ but compare equal, the package is reported as a warning rather
than quietly skipped.

=head2 Related commands

C<upgrade --from> is the whole-base, live "be like A" rebaseline.
L<inject --from|App::Mist::Command::inject> raises a single named module;
C<inject --from --full-dependency-tree> takes a named module and raises its
B<entire dependency tree> to the peer's versions as a deferred
L<bundle|Mist::Bundle> (typically a CVE fix whose working set the peer already
solved). L<merge|App::Mist::Command::merge> folds a peer's whole declared set in
and records the relationship in the F<mistfile>.

=head1 SEE ALSO

L<App::Mist::Command::inject>, L<App::Mist::Command::index>,
L<App::Mist::Command::merge>, L<App::Mist::Command::init>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
