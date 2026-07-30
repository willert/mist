package                         # hide from CPAN
  Mist::Script::perl;

# poor-mans pluggable objects: everything that handles perl versions
# has to live in Mist::Script::perl

use strict;
use warnings;

our @INITIAL_ARGS;
BEGIN { @INITIAL_ARGS = @ARGV; }

our $PERLBREW_ROOT;
our $PERLBREW_DEFAULT_VERSION;

use File::Spec ();
use Getopt::Long 2.42;
use Config;
use FindBin ();

my $run_quiet = 0;
my $pb_root   = $ENV{PERLBREW_ROOT} || $PERLBREW_ROOT;

my $pb_version;

my $system_perl;
{
  my $p = Getopt::Long::Parser->new;
  my %arg_spec = (
    "perlbrew=s"  => \$pb_version,
    "system-perl" => \$system_perl,
  );
  $p->configure(qw/ default pass_through no_auto_abbrev /);

  # also remove opts from global argument list
  $p->getoptionsfromarray( \@Mist::Script::install::CMD_OPTS, %arg_spec );

  # but let INITIAL_ARGS take precedence (just to be sure, should be the same)
  $p->getoptionsfromarray( \@INITIAL_ARGS, %arg_spec );
}

# --system-perl is the readable spelling of --perlbrew=system: manage only the
# library tree and build against whatever perl is already on the box. Both land
# on the same sentinel, resolved to undef below.
$pb_version = 'system' if $system_perl and not defined $pb_version;

# Capture explicitness before the env/default fallbacks below: only a literal
# --perlbrew counts as the user confirming a switch.
my $pb_explicit = defined $pb_version;

# Persist an explicit choice before resolving, so the *next* bare run repeats it.
# Without this, --system-perl would be a one-shot: a later plain ./mpan-install
# on the same host reads the baked-in pin again and switches the environment back
# to a perlbrew perl - on a deploy, silently rebuilding everything under an
# interpreter the box was deliberately moved off. Choosing a real --perlbrew
# version is the same decision in the other direction, and clears it.
_persist_system_perl( $pb_version ) if $pb_explicit;

$pb_version = _resolve_perl_version(
  explicit  => $pb_version,
  env       => $ENV{MIST_PERLBREW_VERSION},
  persisted => ( _system_perl_persisted() ? 'system' : undef ),
  default   => $PERLBREW_DEFAULT_VERSION,
);

# "No perl is managed" has two causes that must not be confused: this project
# pins none (long-standing, and whatever perl you are in is the answer), or
# system-perl mode was chosen here or recorded earlier. Only the latter promises
# a *specific* perl, so only the latter polices the ambient environment.
my $system_perl_mode = ( not defined $pb_version )
  && ( $pb_explicit || _system_perl_persisted() );

sub _unpinned_warning {
  return <<'WARNING';

./mpan-install: this project pins no perl version.

This build uses whatever perl is on PATH, and the guard that refuses an implicit
interpreter switch does not apply, so it will re-activate the environment onto
that perl without asking.

Add `perl '<version>'` to the mistfile and recompile, or - if this machine is
meant to track its own perl - re-run with --system-perl, which is guarded and
remembered.

Unpinned projects are deprecated and will be refused in a future release.

WARNING
}

# Pure precedence decision, factored out so it is unit-testable without a
# project, an installer or a perlbrew (cf. _switch_verdict). Returns the perlbrew
# version to run under, or undef for "manage no perl at all" - which is what
# every perlbrew step below short-circuits on.
#
# The host's persisted choice outranks the mistfile's baked-in default: the pin
# is the build-master's statement about how the project is developed, while the
# marker is this box's statement about itself, and the box wins on the box. An
# explicit flag outranks both, and MIST_PERLBREW_VERSION sits between them
# because it means "a parent process already selected the perl for us".
sub _resolve_perl_version {
  my %a = @_;
  my $version = $a{explicit} || $a{env} || $a{persisted} || $a{default};
  return undef if not $version or $version eq 'system';
  return $version;
}

sub init {
  # Warned here as well as in the build-master, because this is where the harm
  # lands: a vendored installer outlives the mistfile edit that would fix it, and
  # the selector repoint is what quietly follows PATH. Raised from init rather
  # than at load time so requiring this module standalone (the tests do) stays
  # silent - only an actual install has anything to warn about.
  warn _unpinned_warning()
    if not defined $pb_version and not $system_perl_mode;

  refuse_inherited_perl_env() if $system_perl_mode;
  guard_against_implicit_switch();
  find_perl_version_manager_executable();
  assert_availability_of_requested_perl_version();
  ensure_runtime_is_correct_perl_version();
  check_runtime_environment();
}

# --- Implicit-switch guard ------------------------------------------------

# Pure decision: given the active perl, the requested target and the mode,
# return 'proceed', 'confirm' (ask on a tty) or 'refuse' (die, no tty). Kept
# free of I/O so the precedence is unit-testable (t/switch-verdict.t).
sub _switch_verdict {
  my %a = @_;   # active, target, explicit, build_only, interactive
  return 'proceed' if $a{build_only};       # --build-only never activates
  return 'proceed' if $a{explicit};         # --perlbrew is its own confirmation
  return 'proceed' if !defined $a{active};  # fresh workdir / pre-symlink layout
  return 'proceed' if $a{active} eq $a{target};
  return $a{interactive} ? 'confirm' : 'refuse';
}

# The active perl is whatever perl5/bin/mist-run points at. readlink yields
# undef when it is not a symlink (a fresh install or an old single-file
# layout), which _switch_verdict reads as "nothing to switch away from".
sub _active_perl_version {
  my $app_root = $ENV{MIST_APP_ROOT} || $FindBin::Bin;
  my $body = readlink File::Spec->catfile(
    $app_root, qw/ perl5 bin mist-run / );
  return undef unless defined $body;
  my ( $version ) = $body =~ m/perl-([\d.]+)/;
  return $version;
}

# A bare ./mpan-install that would change the active perl is an implicit switch:
# confirm it on a tty, refuse it without one (so a deploy/CI run that forgot to
# pin --perlbrew dies loudly rather than silently reverting the perl). Runs
# before the perlbrew re-exec so a declined switch wastes no closure build.
sub guard_against_implicit_switch {
  return if $ENV{MIST_PERLBREW_VERSION};   # re-exec'd pass / external selection
  return unless $pb_version;               # no perl management at all

  ( my $target = $pb_version ) =~ s/^perl-//;
  my $active = _active_perl_version();

  my $verdict = _switch_verdict(
    active      => $active,
    target      => $target,
    explicit    => $pb_explicit,
    build_only  => $Mist::Script::install::build_only,
    interactive => ( -t STDIN ? 1 : 0 ),
  );

  return if $verdict eq 'proceed';

  if ( $verdict eq 'refuse' ) {
    die "FATAL: refusing to implicitly switch perl from $active to $target.\n"
      . "Re-run with --perlbrew=$target to confirm the switch.\n";
  }

  print "This workdir runs on $active, switch to $target? [y/N] ";
  my $answer = <STDIN>;
  exit 1 unless defined $answer and $answer =~ /\A\s*y/i;
}

# --- System-perl environment hygiene --------------------------------------

# Which managed-perl environments the calling shell has active. Pure (reads only
# %ENV, which a test can localise) so the detection is exercisable without a
# perlbrew. PERLBREW_PERL and PERL_LOCAL_LIB_ROOT are the reliable markers:
# PERL5LIB alone is set for too many innocent reasons to refuse on.
sub _inherited_perl_env {
  return grep { defined $ENV{$_} and length $ENV{$_} }
    qw/ PERLBREW_PERL PERL_LOCAL_LIB_ROOT /;
}

# --system-perl claims a specific interpreter: the one this machine ships. An
# activated perlbrew or local::lib makes that claim false and does it silently -
# $^X is that perl, $Config{version}/{archname} name the generation after it, and
# the recorded choice says "system" regardless. Nothing downstream would notice,
# because there is no re-exec on this path to correct it. Refuse instead of
# building something mislabelled.
sub refuse_inherited_perl_env {
  my @active = _inherited_perl_env() or return;
  die "FATAL: --system-perl expects a shell with no managed perl active, but "
    . join( ' and ', @active ) . " " . ( @active > 1 ? 'are' : 'is' ) . " set.\n"
    . "Leave that environment first - `perlbrew off`, or a clean shell - and\n"
    . "re-run. Building now would use whichever perl is active and record it\n"
    . "as this machine's system perl.\n";
}

# --- System-perl persistence ----------------------------------------------

# Host-local, never committed: it lives under perl5/, which is install output.
# The mistfile pin is the project's answer for everyone; this is one machine
# saying it manages its own interpreter - a container or an AWS host running a
# distro perl that gets backported security fixes. Those are different
# statements, so they get different homes.
sub _system_perl_marker {
  my $app_root = $ENV{MIST_APP_ROOT} || $FindBin::Bin;
  return File::Spec->catfile( $app_root, 'perl5', '.mist-system-perl' );
}

sub _system_perl_persisted { return -e _system_perl_marker() }

# Best-effort: an unwritable perl5/ is reported properly by the installer a
# moment later, and failing to record the preference must not fail the run that
# expressed it.
sub _persist_system_perl {
  my ( $chosen ) = @_;
  my $marker = _system_perl_marker();
  my $wanted = ( defined $chosen and $chosen eq 'system' );

  if ( not $wanted ) {
    unlink $marker if -e $marker;
    return;
  }

  return if -e $marker;

  my $perl5 = ( File::Spec->splitpath( $marker ) )[1];
  mkdir $perl5 unless -d $perl5;

  if ( open my $fh, '>', $marker ) {
    print $fh <<'MARKER';
# Written by ./mpan-install --system-perl.
#
# This machine builds against its own perl and mist manages only the library
# tree, ignoring the perl version pinned in the mistfile. Remove this file, or
# run ./mpan-install --perlbrew=<version>, to hand the interpreter back to
# perlbrew.
MARKER
    close $fh;
  } else {
    warn "Could not record the --system-perl choice in $marker: $!\n";
  }
}

# --- Internals ------------------------------------------------------------
my $pb_exec;
sub find_perl_version_manager_executable {
  return unless $pb_version;

  $pb_exec = qx{ which perlbrew 2> /dev/null };
  if ( not $pb_exec ) {
    ( $pb_root ) = grep { -e File::Spec->catfile( $_, qw/ bin perlbrew /) }
      $pb_root, '/opt/perlbrew', '/opt/perl5';
    $pb_exec = File::Spec->catfile( $pb_root, qw/ bin perlbrew /);
  }
  chomp $pb_exec;

  system( "$pb_exec version >/dev/null" ) == 0 or die <<"MSG";
No local installation of perlbrew was found ($?). You can install it
as root via:
  export PERLBREW_ROOT=${pb_root}
  curl -kL http://install.perlbrew.pl | sudo -E bash
or just for this account simply via:
  curl -kL http://install.perlbrew.pl | bash
MSG

  # force run quiet for now, can't figure out a way to reliably test
  # installed perlbrew version
  $run_quiet = 1;

}

sub list_available_perl_versions {
  my @versions = qx# bash -c '
    export PERLBREW_ROOT=${pb_root}

    if ( ! . \${PERLBREW_ROOT}/etc/bashrc ) ; then
      perlbrew init 2>/dev/null
      if ( ! . \${PERLBREW_ROOT}/etc/bashrc ) ; then
        echo "Cannot create perlbrew environment in \${PERLBREW_ROOT}"
        exit 127
      fi
    fi

    $pb_exec list
  '#;
  for ( @versions ) { chomp; s/^\s+//; s/\s+$// }
  return @versions;
}

sub assert_availability_of_requested_perl_version {
  return unless $pb_version;

  my @pb_installed_versions = list_available_perl_versions();

  my ( $pb_installed ) = grep{ / \b $pb_version \b /x } @pb_installed_versions;
  die "FATAL: $pb_version not found and can't write to $pb_root\n" .
    "Try\n  sudo -E perlbrew install $pb_version\nto install it as root\n"
    unless $pb_installed or -w $pb_root;

  my @pb_call = ( $pb_exec, 'install', $pb_version );
  system( @pb_call ) == 0 or die "`@pb_call` failed" unless $pb_installed;

  # ensure version is in perlbrew lingo
  $pb_version = "perl-${pb_version}"
    if $pb_version and $pb_version =~ m/^[\d.]+$/;
}

sub ensure_runtime_is_correct_perl_version {
  return unless $pb_version;

  my @pb_options = ( '--with', $pb_version );
  push @pb_options, '--quiet' if $run_quiet;

  if ( not $ENV{MIST_PERLBREW_VERSION} ) {
    if ( !$ENV{PERLBREW_PERL} or $ENV{PERLBREW_PERL} ne $pb_version ) {
      $ENV{PERLBREW_ROOT} = $pb_root;
      my $pb_archname = get_archname();

      $ENV{MIST_PERLBREW_VERSION} = $pb_version;

      ( my $cmd_name = "$0 @INITIAL_ARGS") =~ s/[\n\r\s]+$//;
      $cmd_name =~ s/\s{2,}/ /;
      printf "Restarting $cmd_name under %s [%s]\n", $pb_version, $pb_archname;

      # A non-tty STDIN (background job, CI, agent harness) may be a pipe that
      # never reaches EOF. Nothing in the install path wants input, but the
      # re-exec'd installer inherits fd 0, so a downstream read (a dist's
      # Makefile.PL reading STDIN directly, say) would block forever. Sever it
      # so such reads get immediate EOF; a real tty is left alone so genuine
      # prompts still work.
      open STDIN, '<', File::Spec->devnull unless -t STDIN;

      exec $pb_exec, 'exec', @pb_options, $0, @INITIAL_ARGS;
    }
  }
};

sub check_runtime_environment {
  return unless $pb_version;

  # not sure why we would need an external cpanm anymore

  # # ensure cpanm is installed
  # print "Ensuring cpanm is installed in this environment\n";
  # my $cpanm_exit = system( "$pb_exec install-cpanm </dev/null >/dev/null" );
  # die "Installing cpanm failed (try running `perlbrew install-cpanm` as root)\n"
  #   unless $cpanm_exit == 0;
}


sub get_archname {
  return unless $pb_version;

  my $pb_cmd = qq{ $pb_exec exec } . ( $run_quiet ? '--quiet ' : '' ) . qq{--with '$pb_version' };
  my $pb_archname =  qx{ $pb_cmd perl -MConfig -E "say \\\$Config{archname}" };
  chomp $pb_archname;
  return $pb_archname;
}

sub write_env {
  return unless $pb_version;

  my $class = shift;
  my $env = shift;

  return unless $ENV{MIST_PERLBREW_VERSION} || $pb_version;

  printf $env <<'PERLBREW_RC', $pb_root, $ENV{MIST_PERLBREW_VERSION} || $pb_version;

PERLBREW_DEFAULT_ROOT=%s
PERLBREW_DEFAULT_VERSION=%s

if [ "x$PERLBREW_ROOT" == "x" ] ; then
  export PERLBREW_ROOT=$PERLBREW_DEFAULT_ROOT
fi

source "$PERLBREW_ROOT/etc/bashrc"

if [ "x$MIST_PERLBREW_VERSION" == "x" ] ; then
  MIST_PERLBREW_VERSION=$PERLBREW_DEFAULT_VERSION
fi

perlbrew use "$MIST_PERLBREW_VERSION"
PERLBREW_RC

  # By the time these run, this rc has already sourced perlbrew's bashrc and
  # run `perlbrew use "$MIST_PERLBREW_VERSION"`, so PATH/MANPATH/PERLBREW_PERL/
  # ... already point at the requested perl -- a `perlbrew exec` layer here is
  # redundant. Worse, `perlbrew exec` runs the command as a forked child and
  # then exits 1 on any failure (real exit code and signal-death status lost),
  # leaving a stray perl as the parent of every daemon. Run the command
  # directly so exit codes, signals and the process identity pass straight
  # through to the caller / service supervisor.
  print $env <<'PERLBREW_RC';
function mist_exec {
   exec "${@}"
}
function mist_run {
   "${@}"
}
PERLBREW_RC

}

1;
