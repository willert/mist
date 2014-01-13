package                         # hide from CPAN
  Mist::Script::perl;

# poor-mans pluggable objects: everything that handles perl versions
# has to live in Mist::Script::perl

use 5.010;
use strict;
use warnings;

our @INITIAL_ARGS;
BEGIN { @INITIAL_ARGS = @ARGV; }

our $PERLBREW_ROOT;
our $PERLBREW_DEFAULT_VERSION // die '$PERL5_DEFAULT_VERSION not set';

use FindBin ();
use File::Spec ();
use Getopt::Long qw/GetOptionsFromArray/;
use Config;

my $tmp_base_dir = File::Spec->catdir( $FindBin::Bin, 'tmp' );
$tmp_base_dir = File::Spec->catdir(
  File::Spec->tmpdir,
  ( File::Spec->splitdir( $FindBin::Bin ))[ -1 ],
) unless -d $tmp_base_dir and -w $tmp_base_dir;

my $pb_root    = $ENV{PERLBREW_ROOT} || $PERLBREW_ROOT;
my $pb_home    = File::Spec->catdir( $tmp_base_dir, 'perlbrew' );

my @CMD_ARGS = @INITIAL_ARGS;
GetOptionsFromArray( \@CMD_ARGS, "perl=s" => \ my $pb_version );
$pb_version ||= $PERLBREW_DEFAULT_VERSION;

# print "Using perl version $pb_version\n";
# print "Using perlbrew root $pb_root\n";
# print "Using temporary perlbrew home $pb_home\n";

my $pb_exec;

if ( $pb_version ) {

  $pb_exec = qx{ which perlbrew } || "${pb_root}/bin/perlbrew";
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
    export PERLBREW_HOME=${pb_home}

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

  if ( !$ENV{PERLBREW_PERL} or $ENV{PERLBREW_PERL} ne $pb_version ) {
    $ENV{PERLBREW_ROOT} = $pb_root;
    $ENV{PERLBREW_HOME} = $pb_home;
    my $pb_archname = get_archname();

    printf "Restarting $0 under %s [%s]\n", $pb_version, $pb_archname;
    exec $pb_exec, 'exec', '--quiet', '--with', $pb_version, $0, @INITIAL_ARGS;
  }
}

sub get_archname {
  my $pb_cmd = qq{ $pb_exec exec --quiet --with '$pb_version' };
  my $pb_archname =  qx{ $pb_cmd perl -MConfig -E "say \\\$Config{archname}" };
  chomp $pb_archname;
  return $pb_archname;
}

sub write_env {
  my $class = shift;
  my $env = shift;

  return unless $pb_version;

  printf $env <<'PERLBREW_RC', $pb_root, $pb_version;

PERLBREW_DEFAULT_ROOT=%s
PERLBREW_DEFAULT_VERSION=%s

if [ "x$PERLBREW_ROOT" == "x" ] ; then
  export PERLBREW_ROOT=$PERLBREW_DEFAULT_ROOT
fi

source "$PERLBREW_ROOT/etc/bashrc"

perlbrew use $PERLBREW_DEFAULT_VERSION

PERLBREW_RC

}

1;
