package Mist::Generation;

# The copy-on-write generation ladder: naming, seeding, promotion, activation and
# the purge classifier. Every install builds into a fresh generation beside the
# live one and swaps a selector symlink on success, so the active environment is
# never mutated in place and a failed build leaves it untouched.
#
# This lives in its own module because both halves of mist need it. It is
# fatpacked into ./mpan-install (the host installer, which has no mist), and it is
# called directly by build-master commands that have to move the live environment
# forward - so `mist upgrade` gets the same atomicity as an install without
# shelling out to a build artifact whose behaviour is frozen at compile time.
#
# It is therefore held to the host's constraints: core modules only, no
# Path::Class, no Moo, plain strings in and out. Callers pass paths that are
# consistently relative (the installer runs with cwd at the project root) or
# consistently absolute (mist commands); nothing here mixes the two.

use strict;
use warnings;

use Config;
use File::Find ();
use File::Path ();
use File::Spec ();

# perl-<version>-<archname>: the per-perl identity every generation name is built
# from, and the name of the selector symlink under perl5/. Defaults to the running
# perl; takes explicit values so a caller can name another perl's generations
# without running under it (`mist purge --perlbrew`).
sub arch_path {
  my ( $version, $archname ) = @_;
  $version  = $Config{version}  unless defined $version;
  $archname = $Config{archname} unless defined $archname;
  return join q{-}, 'perl', $version, $archname;
}

sub container {
  my ( $perl5_base ) = @_;
  return File::Spec->catdir( $perl5_base, 'generations' );
}

# The generation being built carries a -build suffix and is renamed to its final
# name only on success (see promote), so an interrupted build is self-labelling:
# a leftover ...-build dir is junk, never a seed parent and never a rollback
# target.
sub build_dir {
  my ( $gen_container, $gen_name ) = @_;
  return File::Spec->catdir( $gen_container, "${gen_name}-build" );
}

# Where build_dir is renamed to on success.
sub final_dir {
  my ( $gen_container, $gen_name ) = @_;
  return File::Spec->catdir( $gen_container, $gen_name );
}

# A named --branch, else a monotonic counter one past the highest *completed*
# generation. Because a failed build never completes, a re-run recomputes the same
# counter and lands on the same -build dir, which is what makes the default resume
# work.
sub next_name {
  my %arg = @_;
  my ( $gen_container, $arch_path, $branch )
    = @arg{qw/ container arch_path branch /};

  return join q{-}, $arch_path, $branch if defined $branch;

  my $max = 0;
  for ( glob File::Spec->catdir( $gen_container, "${arch_path}-*" ) ) {
    my ( $n ) = ( File::Spec->splitdir( $_ ) )[-1] =~ m/^\Q${arch_path}\E-(\d+)\z/
      or next;
    $max = $n if $n > $max;
  }
  return join q{-}, $arch_path, $max + 1;
}

# Which generation a new build inherits from: an explicit --parent, else this
# named branch itself (re-installing a named generation updates it), else the
# generation this perl currently runs (the perl5/<arch_path> selector, or a legacy
# real lib dir being migrated), else nothing on a first install.
sub seed_source {
  my %arg = @_;
  my ( $perl5_base, $gen_container, $arch_path, $gen_name, $branch, $parent )
    = @arg{qw/ perl5_base container arch_path gen_name branch parent /};

  if ( defined $parent ) {
    my $from = File::Spec->catdir(
      $gen_container, join( q{-}, $arch_path, $parent ) );
    die "Parent generation $from doesn't exist\n" unless -d $from;
    return $from;
  }

  my $named = File::Spec->catdir( $gen_container, $gen_name );
  return $named if defined $branch and -d $named;

  my $generic = File::Spec->catdir( $perl5_base, $arch_path );
  return File::Spec->catdir( $perl5_base, readlink $generic ) if -l $generic;
  return $generic if -d $generic;
  return undef;
}

# Hard-link the parent's tree so unchanged files share inodes (cheap on ext4, XFS,
# btrfs, ...) and only what cpanm replaces costs disk. Safe because cpanm installs
# files anew rather than editing in place - ExtUtils::Install unlinks or renames a
# target before writing it - so a shared file is never mutated through the parent.
#
# On a filesystem without hard links (FAT, some network/FUSE mounts) the link
# fails; fall back to a full copy so the generation is still correct, just without
# the disk sharing. A seed that cannot even be copied dies here, before any
# activation, so the live environment is left untouched.
sub seed {
  my %arg = @_;
  my ( $from, $to, $name ) = @arg{qw/ from to name /};

  File::Path::mkpath( ( File::Spec->splitpath( $to ) )[1] );
  print "Seeding generation ${name} from $from\n" if defined $name;

  if ( system( cp => '--link', '--archive', $from, $to ) != 0 ) {
    File::Path::rmtree( $to );
    if ( system( cp => '--archive', $from, $to ) != 0 ) {
      File::Path::rmtree( $to );
      die "Failed to seed generation from $from\n";
    }
  }

  shed_inherited_bookkeeping( $to );
  return $to;
}

# perllocal.pod is appended to in place, and a .mist-built-* marker belongs to the
# generation that wrote it; left hard-linked from the seed they would tie this
# generation to its parent - the marker misreporting when this one was built, and
# the append reaching through into the live environment. Break those links
# (perllocal is a regenerable install log; the marker is rewritten at promote).
sub shed_inherited_bookkeeping {
  my ( $dir ) = @_;
  File::Find::find( sub {
    unlink $_ if $_ eq 'perllocal.pod' or /^\.mist-built-/;
  }, $dir );
  return;
}

# Prepare the directory a build installs into, applying the caller's retry policy.
# Shared by the installer (whose policy comes from --resume/--rebuild/
# --continue-last-build) and by build-master commands that stage a generation of
# their own, so there is one implementation of "discard, or resume, or seed".
#
#   discard - drop a resumable leftover and start from the seed again
#   no_seed - skip the seed entirely, so the build gets an empty clean room
#             (--rebuild), or continue an existing partial untouched
#             (--continue-last-build)
sub stage {
  my %arg = @_;
  my $build = $arg{build_dir};

  File::Path::rmtree( $build ) if $arg{discard} and -e $build;

  return $build if $arg{no_seed};
  return $build if -d $build;       # a leftover being resumed is built into as-is

  my $from = seed_source( %arg );
  seed( from => $from, to => $build, name => $arg{gen_name} )
    if defined $from and -d $from;

  return $build;
}

# Stamp this generation's completion time. The counter in the directory name
# orders generations; the marker records *when*, because cp --archive leaves the
# directory mtime inherited from the parent and therefore useless. Any marker
# inherited through the seed is dropped first.
sub stamp_marker {
  my ( $dir ) = @_;
  unlink $_ for glob File::Spec->catfile( $dir, '.mist-built-*' );
  my @t = gmtime;
  my $marker = File::Spec->catfile( $dir,
    sprintf '.mist-built-%04d%02d%02dT%02d%02d%02dZ',
      $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] );
  if ( open my $fh, '>', $marker ) { close $fh }
  else { warn "Could not write build marker $marker: $!\n" }
  return $marker;
}

# Freeze a successful build into a completed generation: stamp it, then rename
# ...-build to its final name. A failed build never reaches here, so it stays a
# labelled ...-build dir. Returns the final path.
#
# A named-branch re-install replaces an existing named generation. The old one is
# moved aside (atomic, parent-write only) rather than rmtree'd in place: a partial
# rmtree would corrupt the named generation AND leave the new build unpromoted.
# The old copy is reclaimed best-effort afterwards - its tree is hard-linked into
# the new generation, so whatever cannot be removed is a shared inode, never
# unique data.
sub promote {
  my %arg = @_;
  my ( $build, $final, $branch ) = @arg{qw/ build_dir final branch /};

  stamp_marker( $build );

  my $superseded;
  if ( $branch and -e $final ) {
    $superseded = sprintf '%s.superseded-%d', $final, $$;
    rename( $final, $superseded )
      or die "Failed to move the existing generation $final aside: $!\n";
  }

  rename( $build, $final )
    or die "Failed to promote $build to $final: $!";

  if ( defined $superseded ) {
    my $why = reclaim( $superseded );
    warn "${why}\nIt shares storage with the new generation, so it costs no disk;\n"
       . "remove it by hand when convenient.\n"
      if defined $why;
  }

  return $final;
}

# Best-effort removal of a tree we have finished with - a superseded generation, a
# migrated legacy lib dir. Returns undef on success, else a diagnostic naming what
# stopped it.
#
# Deliberately NOT File::Path's safe mode. safe skips every file the process
# cannot *write* (File/Path.pm's `!(-l $root || -w $root)`), and EUMM installs
# modules 0444, so safe mode reclaims nothing at all - which is how a migrated
# legacy tree used to survive entire while reporting that its files were "not
# yours to delete". They were ours; they were merely read-only.
#
# -w is the wrong test anyway: deletability is governed by the containing
# directory, never by a file's own mode or owner. Forcing through therefore
# removes what is ours (chmod'ing as needed), and a tree genuinely owned by
# someone else still fails - chmod needs ownership, and mist refuses to run as
# root (Mist::Script::install: `die ... if $> == 0`), so it can never force its
# way into another user's files. What changes is that the failure is now
# explained instead of guessed at.
sub reclaim {
  my ( $dir ) = @_;

  File::Path::rmtree( $dir, { error => \my $errors } );
  return undef unless -e $dir;

  my @why;
  for my $problem ( @{ $errors || [] } ) {
    my ( $file, $message ) = %$problem;
    push @why, length $file ? "  ${file}: ${message}" : "  ${message}";
  }
  push @why, '  (rmtree reported no diagnostics)' unless @why;

  my $shown = @why > 5 ? 5 : scalar @why;
  return join qq{\n},
    "Could not fully remove ${dir}:",
    @why[ 0 .. $shown - 1 ],
    ( @why > $shown ? sprintf( '  ... and %d more', scalar( @why ) - $shown ) : () );
}

# Atomic activation: stage the symlink under a temp name, then rename it over the
# live selector. rename(2) is atomic, so a reader never sees a missing or
# half-written link.
sub activate_symlink {
  my ( $target, $link ) = @_;
  my $tmp = "${link}.tmp.$$";
  unlink $tmp;
  symlink( $target, $tmp ) or die "Failed to stage symlink $tmp -> $target: $!";
  rename( $tmp, $link )    or die "Failed to activate symlink $link -> $target: $!";
  return;
}

# Make a completed generation current for its perl by pointing the
# perl5/<arch_path> selector at it. $gen_relpath is relative to perl5/, so it
# resolves natively for the wrapper and for local::lib, and a later swap (an
# upgrade or a rollback) needs nothing rewritten.
#
# A legacy real lib dir (pre-generation layout) is migrated in place: its tree is
# already hard-linked into the new generation, so only the directory ENTRY needs
# to go. It is renamed aside rather than rmtree'd, because rename needs write on
# the parent perl5/ only - never permission to delete the contents, which on a
# deployment may be owned by another user. An rmtree here would delete what it
# could, stall on the rest, and leave the environment with neither a working
# directory nor a symlink.
sub activate {
  my ( $generic, $gen_relpath ) = @_;

  if ( -l $generic or not -e $generic ) {
    activate_symlink( $gen_relpath, $generic );
  }
  elsif ( -d $generic ) {
    my $aside = sprintf '%s.legacy-%d', $generic, $$;
    rename( $generic, $aside )
      or die "Failed to move the legacy lib dir aside ($generic): $!\n"
           . "mpan-install needs write permission on the parent perl5 directory.\n";
    unless ( symlink( $gen_relpath, $generic ) ) {
      my $err = $!;
      rename( $aside, $generic )
        or warn "Could not restore $generic after a failed symlink: $!\n";
      die "Failed to link $generic to generation $gen_relpath: $err\n";
    }
    if ( my $why = reclaim( $aside ) ) {
      warn "Migrated the legacy $generic to a generation symlink.\n${why}\n"
         . "The old copy is hard-linked into the new generation, so it costs no\n"
         . "disk; remove it by hand when convenient.\n";
    }
  }
  else {
    die "$generic exists but is neither a symlink nor a directory\n";
  }

  stamp_active_generation( $generic, $gen_relpath );
  return;
}

# The activation stamp perl5/etc/mist.active-generation: one plain file whose
# mtime moves whenever the environment behind a selector changes, so a restarter
# can watch it instead of recursing into the whole tree - thousands of files
# behind a symlink, which many watchers resolve and descend into by default and
# cannot be told not to. Its content names the active generation, relative to
# perl5/ like the selector target. A caller that changes the active generation's
# contents in place rather than swapping it (mist local) passes only the
# selector; the name is then read from the selector and stays the same - the
# mtime bump is the point. Written beside the final name and renamed over it, so
# a watcher never reads a half-written stamp. A failure only warns: the change
# the stamp reports has already happened, and a missed signal must not be
# escalated into a failed activation.
sub stamp_active_generation {
  my ( $generic, $gen_relpath ) = @_;

  $gen_relpath = readlink $generic unless defined $gen_relpath;
  $gen_relpath = '' unless defined $gen_relpath;   # a legacy real dir has no name

  my $etc = File::Spec->catdir(
    ( File::Spec->splitpath( $generic ) )[1], 'etc' );
  File::Path::mkpath( $etc, { error => \my $mkpath_errors } ) unless -d $etc;

  my $stamp = File::Spec->catfile( $etc, 'mist.active-generation' );
  my $tmp   = "${stamp}.tmp.$$";
  if ( open my $fh, '>', $tmp ) {
    print $fh "${gen_relpath}\n";
    return $stamp if close $fh and rename $tmp, $stamp;
  }
  warn "Could not write the activation stamp ${stamp}: $!\n";
  unlink $tmp;
  return undef;
}

# Pure classifier for what a purge may remove. Given generation directory names,
# the protected set (basenames of the active generations, one per perl), and
# whether named branches are in scope: an active generation is always kept
# (checked first, so even an auto-numbered active one survives); a -build dir is
# an interrupted build and always junk; an auto-numbered generation ends in
# -<digits> (archnames always end in letters, so this never matches a named
# branch) and goes when not active; a named branch is a deliberate environment
# and is kept unless the caller opts in.
sub names_to_purge {
  my ( $names, $protected, $include_branches ) = @_;

  my @remove;
  for my $name ( @$names ) {
    next if $protected->{ $name };
    if    ( $name =~ /-build\z/ ) { push @remove, $name }
    elsif ( $name =~ /-\d+\z/   ) { push @remove, $name }
    elsif ( $include_branches   ) { push @remove, $name }
  }
  return @remove;
}

1;
