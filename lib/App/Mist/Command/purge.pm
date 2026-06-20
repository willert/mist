package App::Mist::Command::purge;
# ABSTRACT: Remove superseded perl5 build generations

use 5.010;

use App::Mist -command;

use File::Spec;
use File::Path ();
use File::Find ();

sub usage_desc { '%c purge %o' }

sub opt_spec {
  return (
    [ 'dry-run|n'        => 'list what would be removed without deleting anything' ],
    [ 'include-branches' => 'also remove non-active named-branch generations'      ],
    [ 'perlbrew=s'       => 'only purge generations for this perl version (e.g. 5.42.2); default is every perl' ],
  );
}

# Pure classifier, factored out so it can be unit-tested without a project or CLI
# context. Given the generation directory names, the protected set (basenames of
# the active generations, one per perl), and whether named branches are in scope,
# return the names to remove. An active generation is always kept (checked first,
# so even an auto-numbered active one survives); a -build dir is an interrupted
# build and always junk; an auto-numbered generation ends in -<digits> (archnames
# always end in letters, so this never matches a named branch) and is removed when
# not active; a named branch is kept unless the caller opts into sweeping them.
sub _generations_to_purge {
  my ( $names, $protected, $include_branches ) = @_;

  my @remove;
  for my $name ( @$names ) {
    next if $protected->{ $name };
    if ( $name =~ /-build\z/ ) {
      push @remove, $name;
    } elsif ( $name =~ /-\d+\z/ ) {
      push @remove, $name;
    } elsif ( $include_branches ) {
      push @remove, $name;
    }
  }
  return @remove;
}

# Best-effort reclaimed disk: sum the block sizes of files whose only link is in
# the removed set, since those are the inodes that actually free on removal.
# Files hard-linked into a kept generation (the CoW seed sharing) have nlink > 1
# and are excluded; files shared only between two removed generations are missed,
# so the figure is a lower bound - reported as approximate.
sub _freed_bytes {
  my ( @dirs ) = @_;
  my $bytes = 0;
  File::Find::find({
    no_chdir => 1,
    wanted   => sub {
      my @st = lstat $_ or return;
      return unless -f _;        # regular files only; skip dirs and symlinks
      return unless $st[3] == 1; # nlink == 1: removing this drops the last link
      $bytes += $st[12] * 512;   # st_blocks, in 512-byte units
    },
  }, @dirs );
  return $bytes;
}

sub _human {
  my $n = shift;
  my @unit = qw/ B KB MB GB TB /;
  my $i = 0;
  while ( $n >= 1024 and $i < $#unit ) { $n /= 1024; $i++ }
  return $i ? sprintf( '%.1f %s', $n, $unit[ $i ] ) : sprintf( '%d %s', $n, $unit[ $i ] );
}

sub execute {
  my ( $self, $opt, $args ) = @_;

  # Pure filesystem housekeeping. Unlike `mist run`, --perlbrew here does NOT
  # re-exec under the target perl (ensure_correct_perlbrew_context): purge only
  # reads generation directory names, so it scopes by matching the perl version
  # in the name and never needs that perl to be installed or activated.
  my $ctx = $self->app->ctx;
  _purge_generations(
    $ctx->perl5_base_lib->stringify,
    dry_run          => $opt->dry_run,
    include_branches => $opt->include_branches,
    perlbrew         => $opt->perlbrew,
  );
}

# Scan one perl5/ tree and remove its superseded generations. Takes the perl5 dir
# path (not a ctx) so it is exercisable in isolation. Returns the names removed
# (or, under dry_run, the names that would be).
sub _purge_generations {
  my ( $perl5, %opt ) = @_;

  my $gens = File::Spec->catdir( $perl5, 'generations' );

  unless ( -d $gens ) {
    print "No build generations to purge ($gens does not exist)\n";
    return;
  }

  # Protected set: every arch selector symlink directly under perl5/ resolves to
  # the active generation of one perl. Collect the target basename of each, so the
  # active generation of every installed perl is preserved (the all-perls sweep).
  my %protected;
  if ( opendir my $dh, $perl5 ) {
    for my $name ( readdir $dh ) {
      my $link = File::Spec->catfile( $perl5, $name );
      next unless -l $link;
      my $target = readlink $link;
      next unless defined $target;
      $protected{ $1 } = 1 if $target =~ m{(?:\A|/)([^/]+)/?\z};
    }
    closedir $dh;
  }

  # --perlbrew scopes the sweep to one perl version, defaulting to all perls.
  # Generations are named perl-<version>-<archname>-<id>, so match on the
  # perl-<version>- prefix (the version is bare even for a threaded build, whose
  # 't' lives in the archname); other perls' generations are then never candidates.
  my $version_prefix;
  if ( defined $opt{ perlbrew } and length $opt{ perlbrew } ) {
    ( my $bare = $opt{ perlbrew } ) =~ s/\Aperl-//;
    $version_prefix = "perl-$bare-";
  }

  my @names;
  opendir my $gh, $gens or die "Cannot read $gens: $!\n";
  for my $name ( readdir $gh ) {
    next if $name eq File::Spec->curdir or $name eq File::Spec->updir;
    next if defined $version_prefix and index( $name, $version_prefix ) != 0;
    push @names, $name if -d File::Spec->catdir( $gens, $name );
  }
  closedir $gh;

  my @remove = sort { $a cmp $b }
    _generations_to_purge( \@names, \%protected, $opt{ include_branches } );

  unless ( @remove ) {
    print "Nothing to purge - the active generations are the only ones present\n";
    return;
  }

  my @paths = map { File::Spec->catdir( $gens, $_ ) } @remove;
  my $freed = _freed_bytes( @paths );

  print $opt{ dry_run }
    ? "Would remove these build generations (dry run):\n"
    : "Removing build generations:\n";
  print "  $_\n" for @remove;

  File::Path::rmtree( \@paths ) unless $opt{ dry_run };

  printf "%s %d generation%s (~%s)\n",
    ( $opt{ dry_run } ? 'Would free' : 'Freed' ),
    scalar( @remove ),
    ( @remove == 1 ? '' : 's' ),
    _human( $freed );

  return @remove;
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::purge - remove superseded perl5 build generations

=head1 SYNOPSIS

  mist purge
  mist purge --dry-run
  mist purge --include-branches

=head1 DESCRIPTION

Each C<./mpan-install> run builds an immutable, copy-on-write generation under
F<perl5/generations/>, and the C<perl5/E<lt>archE<gt>> selector symlink picks
the active one. Old generations are kept on purpose - rollback is a single
symlink repoint - but they accumulate over many install cycles.

C<purge> reclaims that space. By default it sweeps every installed perl; it
keeps the active generation of each (whatever each C<perl5/E<lt>archE<gt>>
selector points at) and removes the rest: every other auto-numbered generation
plus any leftover F<...-build> directories from interrupted installs.
Named-branch generations are deliberate, named environments and are kept unless
C<--include-branches> is given.

It deletes immediately and prints what it removed together with an approximate
reclaimed size (approximate because copy-on-write hard links mean a file shared
with a kept generation frees no disk).

=head1 OPTIONS

=head2 --dry-run, -n

List the generations that would be removed, and the approximate space that would
be freed, without deleting anything.

=head2 --include-branches

Also remove non-active named-branch generations, not just auto-numbered ones.

=head2 --perlbrew=VERSION

Only purge generations for the given perl version (C<5.42.2> or C<perl-5.42.2>),
instead of sweeping every perl. Unlike C<mist run --perlbrew>, this does not
re-exec under that perl - it matches the version in the generation directory
names - so the target perl need not be installed.

=head1 SEE ALSO

L<App::Mist::Command::clean> (the equivalent garbage collector for F<mpan-dist>
tarballs), L<App::Mist::Command::init>.

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
