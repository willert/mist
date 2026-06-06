package Mist::Script::install;
use strict;
use warnings;

use Config;
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


my ( $branch, $parent, $prove, $resume, $rebuild, $continue_last_build );
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

    # the following are accessible via %dist_options
    'force-tests',
    'skip-prepended',
    'skip-notest',
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

my $perl5_baselib = File::Spec->catdir( $mist_home, $PERL5_BASE_LIB );
mkpath( $perl5_baselib );

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

sub run_cpanm {
  my $app = App::cpanminus::script->new;
  my @options = (
    "--quiet",
    "--local-lib-contained=${local_lib}",
    "--mirror=file://${mpan}",
    '--mirror-only',
    @CPAN_ARGS,
  );

  $app->parse_options( @options, @_ );
  my $result = $app->_doit;
  exit 1 unless $result and $result == 1;
  return $result;
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
    File::Path::rmtree( $generic );
    symlink( $gen_relpath, $generic )
      or die "Failed to link $generic to generation $gen_relpath: $!";
  } else {
    die "$generic exists but is neither a symlink nor a directory\n";
  }
}


die "mpan-install can not run as root\n" if $> == 0;

my $workspace = tempdir();

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
  @callstack = $dist->build_cpanm_call_stack(
    { %dist_options,
      'skip-prepended' => 1,
      'skip-notest' => 1,
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
File::Path::rmtree( $final_lib ) if $branch and -e $final_lib;   # named-branch re-install
rename( $local_lib, $final_lib )
  or die "Failed to promote $local_lib to $final_lib: $!";
$local_lib = $final_lib;

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
