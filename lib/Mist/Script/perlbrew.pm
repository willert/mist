package                         # hide from CPAN
  Mist::Script::perl;

# poor-mans pluggable objects: everything that handles perl versions
# has to live in Mist::Script::perl

use strict;
use warnings;

our @INITIAL_ARGS;
BEGIN { @INITIAL_ARGS = @ARGV; }

our $PERLBREW_ROOT;
our $PERLBREW_DEFAULT_VERSION || die '$PERL5_DEFAULT_VERSION not set';

use FindBin ();
use File::Spec ();
use Getopt::Long 2.42;
use Config;

my $run_quiet = 0;

my $tmp_base_dir = File::Spec->catdir( $FindBin::Bin, 'tmp' );
$tmp_base_dir = File::Spec->catdir(
  File::Spec->tmpdir,
  ( File::Spec->splitdir( $FindBin::Bin ))[ -1 ],
) unless -d $tmp_base_dir and -w $tmp_base_dir;

my $pb_root    = $ENV{PERLBREW_ROOT} || $PERLBREW_ROOT;
my $pb_home    = File::Spec->catdir( $tmp_base_dir, 'perlbrew' );

my $pb_version;
my @CMD_ARGS = @INITIAL_ARGS;

{
  my $p = Getopt::Long::Parser->new;
  $p->configure(qw/ default require_order pass_through /);
  $p->getoptionsfromarray( \@CMD_ARGS, "perl=s" => \$pb_version );
}

$pb_version ||= $ENV{MIST_PERLBREW_VERSION};
$pb_version ||= $PERLBREW_DEFAULT_VERSION;

my $pb_exec;

if ( $pb_version ) {

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

  my @pb_installed_versions = qx# bash -c '
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

  my ( $pb_installed ) = grep{ / \b $pb_version \b /x } @pb_installed_versions;
  die "FATAL: $pb_version not found and can't write to $pb_root\n" .
    "Try\n  sudo -E perlbrew install $pb_version\nto install it as root\n"
    unless $pb_installed or -w $pb_root;

  my @pb_call = ( $pb_exec, 'install', $pb_version );
  system( @pb_call ) == 0 or die "`@pb_call` failed" unless $pb_installed;

  # ensure version is in perlbrew lingo
  $pb_version = "perl-${pb_version}"
    if $pb_version and $pb_version =~ m/^[\d.]+$/;

  my @pb_options = ( '--with', $pb_version );

  # try running quietly
  if ( system( $pb_exec, 'exec', '--quiet', @pb_options, 'true' ) == 0 ) {
    push @pb_options, '--quiet';
    $run_quiet = 1;
  }

  if ( not $ENV{MIST_PERLBREW_VERSION} ) {
    if ( !$ENV{PERLBREW_PERL} or $ENV{PERLBREW_PERL} ne $pb_version ) {
      $ENV{PERLBREW_ROOT} = $pb_root;
      my $pb_archname = get_archname();

      $ENV{MIST_PERLBREW_VERSION} = $pb_version;

      ( my $cmd_name = "$0 @CMD_ARGS") =~ s/[\n\r\s]+$//;
      $cmd_name =~ s/\s{2,}/ /;
      printf "Restarting $cmd_name under %s [%s]\n", $pb_version, $pb_archname;
      exec $pb_exec, 'exec', @pb_options, $0, @CMD_ARGS;
    }
  }

  # ensure cpanm is installed
  print "Ensuring cpanm is installed in this environment\n";
  my $cpanm_exit = system( "$pb_exec install-cpanm </dev/null >/dev/null" );
  die "Installing cpanm failed (try running `perlbrew install-cpanm` as root)\n"
    unless $cpanm_exit == 0;
}

# printf "Using perl version %s [%s]\n", $pb_version, get_archname();
# print "Using perlbrew root $pb_root\n";
# print "Using temporary perlbrew home $pb_home\n";

sub get_archname {
  my $pb_cmd = qq{ $pb_exec exec } . ( $run_quiet ? '--quiet ' : '' ) . qq{--with '$pb_version' };
  my $pb_archname =  qx{ $pb_cmd perl -MConfig -E "say \\\$Config{archname}" };
  chomp $pb_archname;
  return $pb_archname;
}

sub write_env {
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

  if ( $run_quiet ) {

    print $env <<'PERLBREW_RC';
function mist_exec {
   exec perlbrew exec --with "$MIST_PERLBREW_VERSION" --quiet "${@}"
}
function mist_run {
   perlbrew exec --with "$MIST_PERLBREW_VERSION" --quiet "${@}"
}
PERLBREW_RC

  } else {

    print $env <<'PERLBREW_RC';
function mist_exec {
   exec perlbrew exec --with "$MIST_PERLBREW_VERSION" "${@}"
}
function mist_run {
   perlbrew exec --with "$MIST_PERLBREW_VERSION" "${@}"
}
PERLBREW_RC

  }

}

1;
