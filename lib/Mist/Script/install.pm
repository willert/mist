package Mist::Script::install;
use strict;
use warnings;

use Config;
use English qw( -no_match_vars );
use Getopt::Long 2.42;
use Pod::Usage;
use File::Temp ();

our @CMD_OPTS;

BEGIN {
  my $help = 0;
  my $p = Getopt::Long::Parser->new;
  $p->configure(qw/ default pass_through no_auto_abbrev /);
  $p->getoptions( 'help|?' => \$help );
  pod2usage( -verbose => 99, -sections => [qw/ NAME SYNOPSIS VERSION /])
    if $help;
}


my ( $branch, $parent, $prove, $resume, $rebuild, $continue_last_build, $purge, $bundle );
our $build_only;
my %dist_options;
BEGIN {
  @CMD_OPTS = @ARGV;
  my $p = Getopt::Long::Parser->new;
  $p->configure(qw/ default pass_through no_auto_abbrev /);
  $p->getoptionsfromarray(
    \@CMD_OPTS,
    \%dist_options,

    # these are not included in %dist_options
    'branch:s'   => \$branch,
    'parent=s'   => \$parent,
    'prove'      => \$prove,
    'build-only' => \$build_only,
    'resume!'    => \$resume,
    'rebuild'    => \$rebuild,
    'continue-last-build' => \$continue_last_build,
    'purge'      => \$purge,
    'bundle=s'   => \$bundle,

    # the following are accessible via %dist_options
    'force-tests',
  );
}

# Build populates this perl's lib/body/rc; Activate repoints the stable
# selectors at them. --build-only does Build but skips Activate.
my $activate = $build_only ? 0 : 1;

our $MPAN_DIST_DIR || die '$MPAN_DIST_DIR not set';
our $PERL5_BASE_LIB = 'perl5';

# let git determine branch name if no explicit name is given
( $branch ) =  `git status --porcelain --branch` =~ m{## ([\w-]+)}
  if defined $branch and not $branch;

my $arch_path = join( q{-}, 'perl', $Config{version}, $Config{archname} );

# A generation's final name is perl5/generations/<arch_path>-<id>: a named
# --branch, else a monotonic counter (highest existing completed counter + 1).
# It is built under a -build suffix and renamed to the final name only once the
# build succeeds (the promote step near the end), so an interrupted build is
# self-labelling - a leftover ...-build dir is junk, never a seed parent or a
# rollback target - and the counter only ever numbers completed generations.
my $gen_container = File::Spec->catdir( $PERL5_BASE_LIB, 'generations' );

my $gen_name;
if ( defined $branch ) {
  $gen_name = join( q{-}, $arch_path, $branch );
} else {
  my $max = 0;
  for ( glob File::Spec->catdir( $gen_container, "${arch_path}-*" ) ) {
    my ( $n ) = ( File::Spec->splitdir( $_ ) )[-1] =~ m/^\Q${arch_path}\E-(\d+)\z/
      or next;
    $max = $n if $n > $max;
  }
  $gen_name = join( q{-}, $arch_path, $max + 1 );
}

our $LOCAL_LIB_DIR = File::Spec->catdir( $gen_container, "${gen_name}-build" );

# Resume an interrupted build. A failed build leaves its ...-build dir behind, and
# the counter is deterministic (a failure never completes, so a re-run recomputes
# the same counter and lands on the same dir), so the re-run continues where cpanm
# stopped - the way re-running cpanm, or the pre-generation in-place build, always
# behaved. Only a *fresh* ...-build is seeded; an existing one is built into as-is.
# Two opt-outs of the default resume, both safe because the build is staged in a
# fresh generation and only swapped in on success:
#   --no-resume  discard a resumable leftover and reseed from the parent (a clean
#                delta rebuild). $resume is undef by default and 1 for an explicit
#                --resume; only --no-resume sets it to a defined-false.
#   --rebuild    also discard, and skip the CoW seed entirely, so cpanm builds the
#                whole closure into an empty generation - a true clean room that
#                sheds files orphaned across generations (an additive CoW seed
#                never removes a dependency dropped from the closure).
#   --continue-last-build
#                resume the existing ...-build as-is: never discard, never seed, so
#                an iterative debug loop on a broken closure build keeps every dist
#                that already built. Overrides the discard --no-resume / --rebuild
#                would do. (The strict "nothing to continue" check is below, after
#                the perlbrew re-exec, so it tests the target perl's arch and not
#                the arch of the throwaway pre-re-exec pass.)
my $discard_leftover = !$continue_last_build
  && ( ( defined $resume and not $resume ) || $rebuild );
File::Path::rmtree( $LOCAL_LIB_DIR ) if $discard_leftover and -e $LOCAL_LIB_DIR;
unless ( $rebuild or $continue_last_build or -d $LOCAL_LIB_DIR ) {

  # Seed the new generation copy-on-write from its parent: hard-link the parent's
  # tree so unchanged files share inodes and only what cpanm replaces costs disk.
  # The parent is an explicit --parent, else this named branch itself (re-installing
  # a named generation updates it), else the generation this perl currently runs
  # (the perl5/<arch_path> symlink, or a legacy real lib dir being migrated), else
  # nothing on a first install.
  my $generic_rel = File::Spec->catdir( $PERL5_BASE_LIB, $arch_path );
  my $seed_from;
  if ( defined $parent ) {
    $seed_from = File::Spec->catdir( $gen_container, join( q{-}, $arch_path, $parent ) );
    die "Parent generation $seed_from doesn't exist\n" unless -d $seed_from;
  } elsif ( defined $branch and -d File::Spec->catdir( $gen_container, $gen_name ) ) {
    $seed_from = File::Spec->catdir( $gen_container, $gen_name );
  } elsif ( -l $generic_rel ) {
    $seed_from = File::Spec->catdir( $PERL5_BASE_LIB, readlink $generic_rel );
  } elsif ( -d $generic_rel ) {
    $seed_from = $generic_rel;
  }

  if ( $seed_from and -d $seed_from ) {
    File::Path::mkpath( $gen_container );
    print "Seeding generation ${gen_name} from $seed_from\n";

    # Hard-link the parent's tree so unchanged files share inodes (cheap on ext4,
    # XFS, btrfs, ... - safe because cpanm installs files anew rather than editing
    # in place, so a shared file is never mutated through the parent). On a
    # filesystem without hard links (FAT, some network/FUSE mounts) the link
    # fails; fall back to a full copy so the generation is still correct, just
    # without the disk sharing. A seed that cannot even be copied dies here,
    # before any activation, so the live environment is left untouched.
    if ( system( cp => '--link', '--archive', $seed_from, $LOCAL_LIB_DIR ) != 0 ) {
      File::Path::rmtree( $LOCAL_LIB_DIR );
      if ( system( cp => '--archive', $seed_from, $LOCAL_LIB_DIR ) != 0 ) {
        File::Path::rmtree( $LOCAL_LIB_DIR );
        die "Failed to seed generation from $seed_from\n";
      }
    }

    # perllocal.pod is appended to in place, and a .mist-built-* marker belongs to
    # the generation that wrote it; left hard-linked from the seed they would tie
    # this generation to its parent. Break those links (perllocal is a regenerable
    # install log; the marker is rewritten fresh at promote).
    require File::Find;
    File::Find::find( sub {
      unlink $_ if $_ eq 'perllocal.pod' or /^\.mist-built-/;
    }, $LOCAL_LIB_DIR );
  }
}

our $PREPEND_DISTS ||= eval {[ DISTRIBUTION->distinfo->get_prepended_modules ]};
die '$PREPEND_DISTS not set' . $@ unless $PREPEND_DISTS;

our $DONT_TEST_DISTS ||= eval {[ DISTRIBUTION->distinfo->get_modules_not_to_test ]};
die '$DONT_TEST_DISTS not set' . $@ unless $DONT_TEST_DISTS;

our $PREREQUISITE_DISTS || die '$PREREQUISITE_DISTS not set';

use App::cpanminus::script;
use FindBin qw/$Bin/;
use File::Temp qw/ tempdir /;
use File::Path qw/ mkpath /;
use File::Spec;
use File::Copy;
use Cwd qw/ realpath getcwd /;

my $mist_home = $ENV{MIST_APP_ROOT} ? $ENV{MIST_APP_ROOT} : $Bin;

# The real user home, captured before the build's HOME isolation (a tempdir, set
# below) takes over. Ephemeral bundle resolution needs the real home, and pinning
# it here makes that lookup independent of where the bundle read lands relative to
# the override.
my $real_home = $ENV{HOME};

my $perl5_baselib = File::Spec->catdir( $mist_home, $PERL5_BASE_LIB );
mkpath( $perl5_baselib );

# Fail fast and clearly if perl5/ is not writable. Every install creates and
# activates generations, the per-perl wrapper/rc, and the selector symlinks *under*
# perl5/ - all of which need write on this directory, not just on a staging dir. On
# a deployment where perl5/ is owned by another user this would otherwise surface as
# a cryptic mkdir/rename failure deep in the build; catch it up front instead.
if ( -e $perl5_baselib and not -w $perl5_baselib ) {
  warn "$0: cannot write to $perl5_baselib: permission denied.\n"
     . "mpan-install builds and activates generations under perl5/; fix the\n"
     . "ownership or permissions on that directory and re-run.\n";
  exit 1;
}

my $mpan           = File::Spec->catdir( $Bin, $MPAN_DIST_DIR );
my $local_lib      = File::Spec->catdir( $mist_home, $LOCAL_LIB_DIR );
my $libexec_dir    = File::Spec->catdir( $perl5_baselib, 'libexec' );
my $generic_libdir = File::Spec->catdir( $mist_home, $PERL5_BASE_LIB, $arch_path );


mkpath( $libexec_dir );

my $cmd_wrapper = File::Spec->catfile( $libexec_dir, 'cmd-wrapper.bash' );
{
  my $cmd_wrapper_src = CMD_WRAPPER::Bash->get_content;
  open my $fh, '>', $cmd_wrapper
    or die "Creating $cmd_wrapper failed: $!";
  print $fh $cmd_wrapper_src;
}

my $perm = ( stat $cmd_wrapper )[2] & 07777;
chmod( $perm | 0755, $cmd_wrapper );

Mist::Script::perl->init
  if eval{ Mist::Script::perl->can( 'init' ) };

# --continue-last-build is strict: with no in-progress ...-build to resume it
# errors instead of starting fresh. Checked here, after init's perlbrew re-exec,
# so $LOCAL_LIB_DIR carries the target perl's arch - a pre-re-exec check would
# test the system perl's arch and wrongly fire (or pass).
die "No in-progress build to continue at $LOCAL_LIB_DIR\n"
  if $continue_last_build and not -d $LOCAL_LIB_DIR;

{
  # Fail fast if the target perl's Module::CoreList doesn't know about $].
  # Must run after Mist::Script::perl->init (so $] is the target perl) and
  # before cpanm loads, so we beat cpanm's own check mid-resolution.
  require Module::CoreList;
  unless ( exists $Module::CoreList::version{ $] + 0 } ) {
    die sprintf(
      "Module::CoreList %s (loaded from %s) has no entries for perl %s.\n"
      . "Install/upgrade Module::CoreList in this perl, or re-run\n"
      . "./mpan-install under a perl whose core Module::CoreList is current.\n",
      $Module::CoreList::VERSION,
      $INC{ "Module/CoreList.pm" },
      $],
    );
  }
}

# let cpanm parse the remaining options and figure out what
# modules are requested for installation (if any)
my $cpanm = App::cpanminus::script->new;
{
  # silence warnings, cpanm will issue them later on
  local $SIG{__WARN__} = sub{};

  $cpanm->parse_options( @CMD_OPTS );
}

my @CUSTOM_MODULES = @{ $cpanm->{argv} };
my @CPAN_ARGS;
for my $arg ( @CMD_OPTS ) {
  push @CPAN_ARGS, $arg unless grep{ $arg eq $_ } @CUSTOM_MODULES;
}

# --bundle: fold a dependency erratum's floor specs into the targeted install.
# Each line is a Module~VERSION floor; appending them to @CUSTOM_MODULES routes
# them through the same CoW-seeded, mirror-only generation build a custom-module
# install uses - so applying a bundle is incremental (only its dists rebuild) and
# atomic, and the >= floors make it max(local, bundle), never a downgrade.
push @CUSTOM_MODULES, _bundle_specs( $bundle ) if defined $bundle;

# Declared here, assigned below once $arch_path/$mist_home are settled: run_cpanm
# and _make_cc_shim are named subs, so they capture $workspace at their definition
# point and would not see a `my` declared after them. The assignment happens before
# the first run_cpanm call, so the shim build sees the real path.
my $workspace;

sub run_cpanm {
  # A call may lead with a { ccflags => ..., ccflags_wrapper => ... } marker (emitted
  # by build_cpanm_call_stack for a ccflags dist's own build; either key may be
  # present). The rest are cpanm args. local %ENV keeps any per-call env scoped to
  # this build.
  my %marker;
  %marker = %{ shift @_ } if @_ and ref $_[0] eq 'HASH';
  local %ENV = %ENV;

  my $app = App::cpanminus::script->new;
  my @options = (
    "--quiet",
    "--mirror=file://${mpan}",
    '--mirror-only',
    @CPAN_ARGS,
  );

  if ( defined $marker{ccflags} and length $marker{ccflags} ) {
    # Scope compiler flags to this one dist's build. cpanm's own local::lib
    # setup (triggered by --local-lib-contained) overwrites PERL_MM_OPT
    # mid-build, so the flags would be lost. Instead reconstruct local::lib's
    # install env via the public build_environment_vars_for, append the flags,
    # and run --self-contained: that path keys off PERL_LOCAL_LIB_ROOT and
    # leaves PERL_MM_OPT alone, so the flags reach Makefile.PL / Build.PL. A
    # CCFLAGS= override replaces perl's default $Config{ccflags}, so it is
    # prepended; Module::Build's --extra_compiler_flags appends natively.
    require local::lib;
    my %ll = local::lib->build_environment_vars_for( $local_lib );
    $ENV{$_} = $ll{$_} for grep { defined $ll{$_} } keys %ll;
    my $flags = $marker{ccflags};
    $ENV{PERL_MM_OPT} = join q{ },
      ( defined $ENV{PERL_MM_OPT} && length $ENV{PERL_MM_OPT} ? $ENV{PERL_MM_OPT} : () ),
      qq{CCFLAGS="$Config{ccflags} $flags"};
    $ENV{PERL_MB_OPT} = join q{ },
      ( defined $ENV{PERL_MB_OPT} && length $ENV{PERL_MB_OPT} ? $ENV{PERL_MB_OPT} : () ),
      qq{--extra_compiler_flags="$flags"};
    push @options, '--self-contained';
  } else {
    push @options, "--local-lib-contained=${local_lib}";
  }

  # The :wrapper channel is orthogonal to the lib mechanism above: it puts a
  # $Config{cc} shim first on PATH so the flags reach compiles that --extra_compiler_flags
  # can't - a dist's internal sub-makes invoking $Config{cc} directly. Scoped to
  # this one cpanm call (the sub's local %ENV), so it never touches the dist's deps,
  # which build in their own undecorated --installdeps call.
  if ( defined $marker{ccflags_wrapper} and length $marker{ccflags_wrapper} ) {
    my $shim_dir = _make_cc_shim( $marker{ccflags_wrapper} );
    $ENV{PATH} = join q{:}, $shim_dir,
      ( defined $ENV{PATH} && length $ENV{PATH} ? $ENV{PATH} : () );
  }

  $app->parse_options( @options, @_ );
  my $result = $app->_doit;
  exit 1 unless $result and $result == 1;
  return $result;
}

# Pure classification of $Config{cc} for the wrapper shim, factored out so it is
# inspectable/testable on its own: a PATH shim can only intercept a compiler invoked
# by bare name through PATH, so an absolute $Config{cc} is bypassed. Returns a
# warning string for that inert case, else undef.
sub _cc_shim_warning {
  my ( $cc ) = @_;
  my ( $cc_word ) = split q{ }, $cc;
  return "ccflags :wrapper: \$Config{cc} is the absolute path '$cc_word'; a PATH cc "
       . "shim cannot intercept it, so the flags may not reach the compiler.\n"
    if File::Spec->file_name_is_absolute( $cc_word );
  return undef;
}

# Build a $Config{cc} shim dir for :wrapper flags and return its path (to prepend on
# PATH). The shim execs the *resolved absolute* compiler so it never re-enters itself,
# and the flags go before "$@" so a dist's own later flag (its own -std) still wins.
# Lives under $workspace, so --rebuild clears it and a corralled TMPDIR contains it.
sub _make_cc_shim {
  my ( $flags ) = @_;
  my ( $cc_word, @cc_rest ) = split q{ }, $Config{cc};

  if ( my $warning = _cc_shim_warning( $Config{cc} ) ) { warn $warning }

  my $real_cc;
  if ( File::Spec->file_name_is_absolute( $cc_word ) ) {
    $real_cc = $cc_word;
  } else {
    # Resolve against the current (un-shimmed) PATH; $workspace is never on the
    # inherited PATH, so this can't pick up a shim from an earlier call.
    for my $dir ( File::Spec->path ) {
      my $cand = File::Spec->catfile( $dir, $cc_word );
      next unless -f $cand and -x _;
      $real_cc = $cand;
      last;
    }
    die "ccflags :wrapper: cannot resolve compiler '$cc_word' on PATH\n"
      unless defined $real_cc;
  }

  ( my $tag = $flags ) =~ s/\W+/_/g;
  $tag =~ s/\A_+//; $tag =~ s/_+\z//;
  $tag = 'flags' unless length $tag;
  my $shim_dir = File::Spec->catdir( $workspace, 'ccshim', $tag );
  mkpath( $shim_dir );

  my $shim_base = ( File::Spec->splitpath( $cc_word ) )[2];
  my $shim = File::Spec->catfile( $shim_dir, $shim_base );
  open my $fh, '>', $shim or die "Creating cc shim $shim failed: $!\n";
  printf $fh "#!/bin/sh\n%s\n",
    join( q{ }, 'exec', $real_cc, @cc_rest, $flags, '"$@"' );
  close $fh;
  my $perm = ( stat $shim )[2] & 07777;
  chmod( $perm | 0755, $shim );

  print "ccflags :wrapper: wrapping $cc_word -> $real_cc with $flags\n";
  return $shim_dir;
}

# The ephemeral half of bundle resolution: ~/.mist/<project>/bundles, where the
# producer drops UUID bundles. Derive the per-project workspace exactly as
# App::Mist::Context does (lc the realpath'd project root, \W -> _, trimmed) so a
# uuid written by `mist inject --full-dependency-tree` is found here. Uses
# $real_home (captured before the build's HOME isolation), not live $ENV{HOME}.
sub _workspace_bundles {
  my $home = $real_home
    or die "Cannot determine HOME to resolve an ephemeral bundle\n";
  ( my $base = lc realpath( $mist_home ) ) =~ s/\W/_/g;
  $base =~ s/\A_+//;
  $base =~ s/_+\z//;
  return File::Spec->catdir( $home, '.mist', $base, 'bundles' );
}

# Resolve a bundle id to its floor specs. A published name lives in the committed
# mirror (mpan-dist/bundles/<id>.bundle); an ephemeral uuid in the workspace, with
# the published name winning. The id is a filename stem, never a path - guarded
# against traversal like release's candidate ids.
sub _bundle_specs {
  my ( $id ) = @_;
  die "Invalid bundle id '" . ( defined $id ? $id : '' ) . "'\n"
    unless defined $id
    and    $id =~ /\A[A-Za-z0-9][\w.-]*\z/
    and    $id !~ /\.\./;

  my @candidates = (
    File::Spec->catfile( $mpan, 'bundles', "$id.bundle" ),
    File::Spec->catfile( _workspace_bundles(), "$id.bundle" ),
  );
  my ( $file ) = grep { -e $_ } @candidates;
  die "No bundle '$id' (looked in: @candidates)\n" unless defined $file;

  my @specs;
  open my $fh, '<', $file or die "Cannot read bundle $file: $!\n";
  while ( defined( my $line = <$fh> ) ) {
    $line =~ s/\A\s+//;
    $line =~ s/\s+\z//;
    next unless length $line;
    next if $line =~ /\A#/;
    push @specs, $line;
  }
  close $fh;
  die "Bundle '$id' lists no dists\n" unless @specs;

  printf "Applying bundle %s (%d floors) from %s\n", $id, scalar @specs, $file;
  return @specs;
}

# Atomic activation: stage the symlink under a temp name, then rename it over
# the live selector. rename(2) is atomic, so a reader never sees a missing or
# half-written link.
sub _activate_symlink {
  my ( $target, $link ) = @_;
  my $tmp = "${link}.tmp.$$";
  unlink $tmp;
  symlink( $target, $tmp ) or die "Failed to stage symlink $tmp -> $target: $!";
  rename( $tmp, $link )    or die "Failed to activate symlink $link -> $target: $!";
}

# Make the freshly built generation current for this perl by pointing the
# perl5/<arch_path> selector at it. The target is relative to perl5/, so it
# resolves natively for the wrapper and local::lib. A legacy real lib dir
# (pre-generation layout) is migrated in place: its tree is already hard-linked
# into the new generation, so dropping the directory entry loses no data.
sub _activate_generation {
  my ( $generic, $gen_relpath ) = @_;
  if ( -l $generic or not -e $generic ) {
    _activate_symlink( $gen_relpath, $generic );
  } elsif ( -d $generic ) {
    # Legacy real lib dir (pre-generation layout): migrate it to a symlink. Its tree
    # is already hard-linked into the new generation, so only the directory ENTRY
    # needs to go - rename it aside rather than rmtree it. rename needs write on the
    # parent perl5/ only (which we have - we just built a generation there), never
    # permission to delete the contents, which on a deployment may be owned by
    # another user. rmtree-ing here would delete what it could, stall on the rest,
    # and leave the env with neither a working dir nor a symlink.
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
    # Reclaim the old copy best-effort. Its tree is hard-linked into the generation,
    # so anything we cannot remove is a shared inode (never unique data), not loss;
    # error => captures the per-file failures instead of spewing them.
    File::Path::rmtree( $aside, { safe => 1, error => \my $rm_errors } );
    warn "Migrated the legacy $generic to a generation symlink. Could not fully\n"
       . "remove the old copy at $aside (some files are not yours to delete); it\n"
       . "shares storage with the new generation and is safe to remove by hand.\n"
      if -e $aside;
  } else {
    die "$generic exists but is neither a symlink nor a directory\n";
  }
}


die "mpan-install can not run as root\n" if $> == 0;

# cpanm's HOME for the build (its ~/.cpanm/work/<time>.<pid>/ build trees live
# here, isolated from the real home). Deterministic per project + perl + user so
# it is reused across runs rather than leaked fresh every time - which is what lets
# cpanm's own work-dir GC actually fire (a random HOME per run abandons each tree
# forever). A clean-room --rebuild resets it, bounding the one path that
# materialises the whole closure; an ordinary run reuses it, keeping the last
# build.log around for post-mortem.
( my $ws_key = lc realpath( $mist_home ) ) =~ s/\W/_/g;
$ws_key =~ s/\A_+//; $ws_key =~ s/_+\z//;
$workspace = File::Spec->catdir(
  File::Spec->tmpdir, "mist-build-$UID-$ws_key-$arch_path" );
File::Path::rmtree( $workspace ) if $rebuild and length $ws_key and -d $workspace;
mkpath( $workspace );

mkpath( $local_lib );

if ( not -r $mpan or not -w $local_lib ) {
  warn "$0: can't read from ${mpan}: permission denied\n"
    unless -r $mpan;

  warn "$0: can't write to ${local_lib}: permission denied\n"
    unless -w $local_lib;

  exit 1;
}

# perl5/ root - not $local_lib/.. , which now resolves to perl5/generations
my $p5_dir = realpath( $perl5_baselib );
my $rc_dir = File::Spec->catdir( $p5_dir, 'etc' );
mkpath( $rc_dir );
my $bin_dir = File::Spec->catdir( $p5_dir, 'bin' );
mkpath( $bin_dir );

# Build writes per-perl artifacts under stable, version-tagged names; Activate
# repoints the bare selectors (mist-run, mist.mistrc) at them. The per-perl
# body and rc are what let an alternate-perl build leave the live env alone.
my $body_name = "mist-run-$arch_path";
my $body_fn   = File::Spec->catfile( $bin_dir, $body_name );
my $rc_name   = "mist.mistrc-$arch_path";
my $rc_fn     = File::Spec->catfile( $rc_dir, $rc_name );

# Stage body and rc beside their live names; rename(2) them into place only after
# the build succeeds (below). A failed or interrupted build then never truncates
# the live mist-run wrapper / rc the active env is reading - the bin layer gets
# the same build-beside-then-swap atomicity the lib generation already has.
my $body_new = "$body_fn.new";
my $rc_new   = "$rc_fn.new";

my $mist_run_fn = File::Spec->catfile( $bin_dir, 'mist-run' );    # selector symlink
my $mist_rc     = File::Spec->catfile( $rc_dir, 'mist.mistrc' );  # convenience alias

# Each install builds an isolated generation and swaps the lib symlink atomically
# on success, so the active environment is never mutated in place - a mid-build
# failure just orphans the staging generation and the old one stays live. No loud
# stub is needed. The one case that must not move the live generation is
# --build-only of the perl that is *currently active*: it stages the build
# without making it current.
my $active_body     = readlink $mist_run_fn;
my $is_active_perl  = defined( $active_body ) && $active_body eq $body_name;
my $repoint_generic = !( $build_only && $is_active_perl );

open my $env, '>', $rc_new        # stage early to catch write errors; never the live rc
  or die "Creating $rc_new failed: $!";

open my $body, '>', $body_new
  or die "Creating $body_new failed: $!";
{
  my $perm = ( stat $body_new )[2] & 07777;
  chmod( $perm | 0755, $body_new );
}

local $ENV{HOME} = $workspace;
local $ENV{MIST_APP_ROOT} = $mist_home;
local $ENV{MIST_PERL5_LIBDIR} = File::Spec->catdir( $mist_home, $LOCAL_LIB_DIR );

# Silence GNU tar's "Ignoring unknown extended header keyword 'SCHILY.*'"
# spam when cpanm extracts tarballs created by Solaris star. bsdtar ignores
# TAR_OPTIONS and doesn't emit these warnings, so this is GNU-tar-only.
local $ENV{TAR_OPTIONS} = join q{ },
  '--warning=no-unknown-keyword',
  ( defined $ENV{TAR_OPTIONS} ? $ENV{TAR_OPTIONS} : () );

my $dist = DISTRIBUTION->distinfo;

system( @$_ ) for $dist->get_scripts( 'prepare' );

if ( eval { $dist->can( 'get_assertions' ) }) {
  my $cwd = getcwd();
  my $tmp_dir = tempdir( "mist-assert-XXXXXX", TMPDIR => 1, CLEANUP => 1 );
  my $assertion_failed;
  for my $check_assertion ( $dist->get_assertions ) {
    chdir( $tmp_dir );
    eval { $check_assertion->() };
    if ( my $err = $@ ) {
      warn "${err}\n";
      $assertion_failed ||= 1;
    }
  }
  chdir( $cwd );
  exit 1 if $assertion_failed;
}

my @callstack;
if ( @CUSTOM_MODULES ) {
  # A targeted install of named modules (a --bundle apply, or an injected dist):
  # skip the mistfile's standing module list and install just what was named.
  @callstack = $dist->build_cpanm_call_stack(
    { %dist_options,
      'skip-default-modlist' => 1,
      'skip-core-satisfied' => 1,
    },
    @CUSTOM_MODULES
  );
} else {
  @callstack = $dist->build_cpanm_call_stack(
    { %dist_options, 'skip-core-satisfied' => 1 },
    $PREREQUISITE_DISTS
  );
}

run_cpanm( @$_ ) for @callstack;

system( @$_ ) for $dist->get_scripts( 'finalize' );

# Promote: the build succeeded, so freeze it into a completed generation. Drop
# any marker inherited via the seed, stamp this generation's own completion time
# (the counter in the dir name orders generations; the marker records when, since
# cp --archive leaves the dir mtime unreliable), then atomically rename ...-build
# to its final name. A failed build never reaches here, so it stays a labelled
# ...-build dir.
unlink $_ for glob File::Spec->catfile( $local_lib, '.mist-built-*' );
{
  my @t = gmtime;
  my $marker = File::Spec->catfile( $local_lib,
    sprintf '.mist-built-%04d%02d%02dT%02d%02d%02dZ',
      $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] );
  if ( open my $m, '>', $marker ) { close $m }
  else { warn "Could not write build marker $marker: $!\n" }
}

my $final_lib = File::Spec->catdir( $perl5_baselib, 'generations', $gen_name );
# Named-branch re-install replaces an existing named generation. Move the old one
# aside (atomic, parent-write only) rather than rmtree it in place: a partial rmtree
# would corrupt the named generation AND leave the new build unpromoted. The old
# copy is reclaimed best-effort after the promote succeeds.
my $superseded;
if ( $branch and -e $final_lib ) {
  $superseded = sprintf '%s.superseded-%d', $final_lib, $$;
  rename( $final_lib, $superseded )
    or die "Failed to move the existing generation $final_lib aside: $!\n";
}
rename( $local_lib, $final_lib )
  or die "Failed to promote $local_lib to $final_lib: $!";
$local_lib = $final_lib;
File::Path::rmtree( $superseded, { safe => 1, error => \my $sup_errors } )
  if defined $superseded;

# Lib-level Activate: point this perl's generation selector at the completed
# generation (atomic rename). The rc and body below bake the stable generic path
# perl5/<arch_path>, which resolves through this symlink, so a later generation
# swap (an upgrade or a rollback) takes effect without rewriting them.
my $gen_relpath = File::Spec->catdir( 'generations', $gen_name );
_activate_generation( $generic_libdir, $gen_relpath ) if $repoint_generic;

printf $env <<'MIST_ENV', $ENV{MIST_APP_ROOT}, $generic_libdir;
# This file is automatically generated by ./mpan-install
# DO NOT EDIT

export MIST_APP_ROOT="%s"
export MIST_PERL5_LIBDIR="%s"
export PATH="$MIST_APP_ROOT/bin:$MIST_APP_ROOT/sbin:$MIST_APP_ROOT/script:$PATH"

MIST_ENV

if ( eval{ Mist::Script::perl->can( 'write_env' )} ) {
  Mist::Script::perl->write_env( $env );
}

require local::lib;
{
  local $SIG{__WARN__} = sub{};
  print $env local::lib->environment_vars_string_for( "${generic_libdir}" );
}

close $env;
rename( $rc_new, $rc_fn ) or die "Failed to install rc $rc_fn: $!";

# The per-perl body sources its own per-perl rc by baked path, so a single
# repoint of the perl5/bin/mist-run selector switches the whole executed env.
printf $body <<'WRAPPER', $mist_home, $rc_fn, $arch_path;
#!/bin/bash

MIST_ROOT="%s"
MIST_ENV="%s"

if [ ! -r $MIST_ENV ] ; then
  echo "FATAL: Could not load env from $MIST_ENV"
  exit 1
fi

# may be overwritten by mist env script
function mist_exec {
  exec "${@}"
}

function mist_run {
  eval "${@}"
}

source $MIST_ENV

VERSION_ARCH_PATH="%s"
LOCAL_LIB="$MIST_ROOT/perl5/$VERSION_ARCH_PATH"

eval `mist_run perl -Mlocal::lib=--no-create,$LOCAL_LIB`;
export PATH="$MIST_ROOT/bin:$MIST_ROOT/sbin:$MIST_ROOT/script:$PATH"
export PERL5LIB="$MIST_ROOT/lib:$PERL5LIB"
export LD_LIBRARY_PATH=$MIST_ROOT/perl5/lib:$LD_LIBRARY_PATH

mist_exec "${@}"
WRAPPER

close $body;
rename( $body_new, $body_fn ) or die "Failed to install wrapper $body_fn: $!";

if ( $activate ) {
  # Activate: repoint the stable selectors at this perl's freshly-built body
  # and rc. rename(2) over the existing link makes each flip atomic, so a
  # cross-perl switch is complete or not at all.
  _activate_symlink( $body_name, $mist_run_fn );
  _activate_symlink( $rc_name,   $mist_rc );

  my $global_mist_run = File::Spec->catfile( $mist_home, 'mist-run' );
  unlink $global_mist_run;
  symlink( $mist_run_fn, $global_mist_run )
    or warn "Permission denied while creating ./mist-run\n";
}

# Re-generating the bin/sbin/script shims is part of Activate (they funnel
# through the selector), so iterate the empty list to skip them when only
# building.
for my $script_dir ( $activate ? (qw/ bin sbin script /) : () ) {

  my $loc_script_dir = File::Spec->catdir( $perl5_baselib, $script_dir );

  my @binaries;
  my $dir;

  my $collect_files;
  $collect_files = sub {
    my $this_dir = shift;
    opendir( my $dh, $this_dir );

    $collect_files->( File::Spec->catdir( $this_dir, $_ )) for grep {
      $_ ne File::Spec->curdir and $_ ne File::Spec->updir and
        -d File::Spec->catfile( $this_dir, $_ )
      } readdir( $dh );

    closedir $dh; opendir( $dh, $this_dir );

    push @binaries, map{
      File::Spec->abs2rel(
        File::Spec->catfile( $this_dir, $_ ), $dir
      ) => File::Spec->catfile( $this_dir, $_ );
    } grep {
      -f File::Spec->catfile( $this_dir, $_ ) and
        -x File::Spec->catfile( $this_dir, $_ );
    } readdir( $dh );

  };

  if ( -d ( my $subdir = File::Spec->catdir( $local_lib, $script_dir ))) {
    $dir = $local_lib;
    $collect_files->( $subdir );
  }

  if ( -d ( my $subdir = File::Spec->catdir( $Bin, $script_dir ))) {
    $dir = $Bin;
    $collect_files->( $subdir );
  }

  my %binaries = @binaries;
  if ( %binaries ) {
    my %path_created;
    for my $bin ( sort keys %binaries ) {
      my ( undef, $dir ) = File::Spec->splitpath( $bin );
      $dir = File::Spec->catdir( $perl5_baselib, $dir );
      if ( not $path_created{ $dir }) {
        print "Creating local binaries in $dir\n";
        mkpath( $dir );
        $path_created{ $dir } = 1;
      }
      my $bin_path = File::Spec->catfile( $perl5_baselib, $bin );
      unlink $bin_path;
      # dist-shipped scripts live in the generation dir; point the shim at the
      # stable generic path so it follows generation swaps/rollbacks like the
      # wrapper does. Project scripts (collected from $Bin) are left untouched.
      ( my $exec_target = $binaries{$bin} ) =~ s{^\Q$local_lib\E/}{$generic_libdir/};
      open my $bin_wrapper, '>', $bin_path
        or die "Failed to create shell wrapper for $bin_path";
      print $bin_wrapper <<"BIN_WRAPPER";
#!/bin/bash
exec "$mist_run_fn" "$exec_target" "\${\@}"
BIN_WRAPPER

      my $perm = ( stat $bin_wrapper )[2] & 07777;
      chmod( $perm | 0755, $bin_wrapper );
      close $bin_wrapper;
    }
  }
}

system $body_fn => prove => ( '-l', 't' ) if $prove;

if ( $activate ) {
  print <<"SUCCESS";

Successfully created a mist environment for this distribution.
To enable it put the following line in your scripts:
source $mist_rc

To run binaries from this distribution (\$HOME/bin and \$HOME/sbin are in
automatically prepended to \$PATH) you can also use this wrapper script:
$mist_run_fn my_script.pl [OPTIONS ..]

SUCCESS
} else {
  print <<"SUCCESS";

Successfully built $arch_path without activating it; the active perl is
unchanged. Run binaries from this build directly via:
$body_fn my_script.pl [OPTIONS ..]

or enable it in a shell with:
source $rc_fn

SUCCESS
}

# --purge: the new generation is built (and, unless --build-only, current), so
# reclaim disk by dropping this perl's other auto-numbered generations and any
# leftover ...-build dirs. Protect both the generation just built ($gen_name) and
# whatever the selector currently points at - the two differ under --build-only,
# where the live generation is not the one just built. Named generations and other
# perls' generations are left untouched.
if ( $purge ) {
  my $abs_gen_container = File::Spec->catdir( $perl5_baselib, 'generations' );
  my %keep = ( $gen_name => 1 );
  if ( -l $generic_libdir ) {
    my $active = readlink $generic_libdir;
    $keep{ $1 } = 1 if defined $active and $active =~ m{(?:\A|/)([^/]+)/?\z};
  }
  for my $dir ( glob File::Spec->catdir( $abs_gen_container, "${arch_path}-*" ) ) {
    my $base = ( File::Spec->splitdir( $dir ) )[-1];
    next if $keep{ $base };
    next unless $base =~ /-\d+\z/ or $base =~ /-build\z/;
    print "Purging old generation $base\n";
    File::Path::rmtree( $dir );
  }
}
