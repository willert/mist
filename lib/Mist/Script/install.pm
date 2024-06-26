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
  $p->configure(qw/ default pass_through /);
  $p->getoptions( 'help|?' => \$help );
  pod2usage( -verbose => 99, -sections => [qw/ NAME SYNOPSIS VERSION /])
    if $help;
}


my $all_versions;
BEGIN {
  my $p = Getopt::Long::Parser->new;
  $p->configure(qw/ default pass_through /);
  $p->getoptions( 'all-available-versions' => \$all_versions );
}

my ( $branch, $parent, $prove );
my %dist_options;
BEGIN {
  @CMD_OPTS = @ARGV;
  my $p = Getopt::Long::Parser->new;
  $p->configure(qw/ default pass_through /);
  $p->getoptionsfromarray(
    \@CMD_OPTS,
    \%dist_options,

    # those two are not included in %dist_options
    'branch:s' => \$branch,
    'parent=s' => \$parent,
    'prove'    => \$prove,

    # the following are accessible via %dist_options
    'force-tests',
    'skip-prepended',
    'skip-notest',
  );
}

if ( $all_versions ) {
  my $vm = "Mist::Script::perl";
  die "No version manager installed" unless UNIVERSAL::can( $vm, 'init' );
  $vm->find_perl_version_manager_executable;
  my @versions = $vm->list_available_perl_versions;
  for my $version ( 'system', @versions ) {
    system $0 => @ARGV, "--perlbrew=${version}";
  } continue {
    print "\n\n";
  }

  # finally re-run default so all symlinks will be set up correctly
  system $0 => @ARGV;
  exit;
}

our $MPAN_DIST_DIR || die '$MPAN_DIST_DIR not set';
our $PERL5_BASE_LIB = 'perl5';

# let git determine branch name if no explicit name is given
( $branch ) =  `git status --porcelain --branch` =~ m{## ([\w-]+)}
  if defined $branch and not $branch;

my $arch_path = join( q{-}, 'perl', $Config{version}, $Config{archname} );

our $LOCAL_LIB_DIR   = File::Spec->catdir(
  $PERL5_BASE_LIB, join( q{-}, $arch_path, $branch ? $branch : () )
);

# hard-link parent's local::lib content to new branch to get CoW-like behavior
if ( $parent ) {
  die "--parent needs --branch to be specified\n"
    unless $branch;

  my $parent_lib_dir = File::Spec->catdir(
    $PERL5_BASE_LIB, join( q{-}, $arch_path, $parent )
  );
  die "Parent branch lib $parent_lib_dir doesn't exist"
    unless -d $parent_lib_dir;
  print "Hard-linking contents of $parent branch to $branch\n";
  system cp => ( '--link', '--no-clobber', '--archive', $parent_lib_dir => $LOCAL_LIB_DIR );
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


die "mpan-install can not run as root\n" if $> == 0;

my $workspace = tempdir();

die <<"MSG" if -l $local_lib;
Directory
$local_lib
is a symlink to a branch, please remove it manually and
restart ./mpan-install or specify a branch to install to.
MSG

mkpath( $local_lib );

if ( not -r $mpan or not -w $local_lib ) {
  warn "$0: can't read from ${mpan}: permission denied\n"
    unless -r $mpan;

  warn "$0: can't write to ${local_lib}: permission denied\n"
    unless -w $local_lib;

  exit 1;
}

my $p5_dir = realpath( File::Spec->catdir( $local_lib, File::Spec->updir ));
my $rc_dir = File::Spec->catdir( $p5_dir, 'etc' );
mkpath( $rc_dir );
my $mist_rc = File::Spec->catfile( $rc_dir, 'mist.mistrc' );
open my $env, '>', $mist_rc;    # to catch write errors early on

my $bin_dir = File::Spec->catdir( $p5_dir, 'bin' );
mkpath( $bin_dir );
my $mist_run_fn = File::Spec->catfile( $bin_dir, 'mist-run');

open my $mist_run, '>', $mist_run_fn; # to catch write errors early on
{
  my $perm = ( stat $mist_run_fn )[2] & 07777;
  chmod( $perm | 0755, $mist_run_fn );
}

print $mist_run <<'BASH';
#!/bin/bash

echo "FATAL: Mist environment not fully installed";
exit 1;
BASH

local $ENV{HOME} = $workspace;
local $ENV{MIST_APP_ROOT} = $mist_home;
local $ENV{MIST_PERL5_LIBDIR} = File::Spec->catdir( $mist_home, $LOCAL_LIB_DIR );

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
    { %dist_options, 'skip-prepended' => 1, 'skip-notest' => 1 },
    @CUSTOM_MODULES
  );
} else {
  @callstack = $dist->build_cpanm_call_stack(
    \%dist_options, $PREREQUISITE_DISTS
  );
}

run_cpanm( @$_ ) for @callstack;

system( @$_ ) for $dist->get_scripts( 'finalize' );

printf $env <<'MIST_ENV', $ENV{MIST_APP_ROOT}, $ENV{MIST_PERL5_LIBDIR};
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
  print $env local::lib->environment_vars_string_for( "${local_lib}" );
}

close $env;
close $mist_run;

open $mist_run, '>', $mist_run_fn; # reopen mist-run and flesh it out

# my $arch_path = File::Spec->abs2rel( $LOCAL_LIB_DIR, $PERL5_BASE_LIB );
printf $mist_run <<'WRAPPER', $mist_home, $mist_rc, $arch_path;
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

close $mist_run;

my $global_mist_run = File::Spec->catfile( $mist_home, 'mist-run' );
unlink $global_mist_run;
symlink( $mist_run_fn, $global_mist_run )
  or warn "Permission denied while creating ./mist-run\n";

for my $script_dir (qw/ bin sbin script /) {

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
      open my $bin_wrapper, '>', $bin_path
        or die "Failed to create shell wrapper for $bin_path";
      print $bin_wrapper <<"BIN_WRAPPER";
#!/bin/bash
exec "$mist_run_fn" "$binaries{$bin}" "\${\@}"
BIN_WRAPPER

      my $perm = ( stat $bin_wrapper )[2] & 07777;
      chmod( $perm | 0755, $bin_wrapper );
      close $bin_wrapper;
    }
  }
}

# try to relink branch-less local lib to branch
if ( $branch ) {
  if ( -l $generic_libdir or not -e $generic_libdir ) {
    print "Re-linking $generic_libdir to current branch\n";
    unlink $generic_libdir;
    symlink $LOCAL_LIB_DIR, $generic_libdir
      or die "Failed to create symlink for $generic_libdir";
  } else {
    warn "$generic_libdir exists but isn't a symlink, leaving it alone.\n";
  }
}

system $mist_run_fn => prove => ( '-l', 't' ) if $prove;

print <<"SUCCESS";

Successfully created a mist environment for this distribution.
To enable it put the following line in your scripts:
source $mist_rc

To run binaries from this distribution (\$HOME/bin and \$HOME/sbin are in
automatically prepended to \$PATH) you can also use this wrapper script:
$mist_run_fn my_script.pl [OPTIONS ..]

SUCCESS
