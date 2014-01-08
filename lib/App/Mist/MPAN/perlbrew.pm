package                         # hide from CPAN
  App::Mist::MPAN::perl;

# poor-mans pluggable objects: everything that handles perl versions
# has to live in App::Mist::MPAN::perl

our @INITIAL_ARGS;
BEGIN { @INITIAL_ARGS = @ARGV; }

our $PERLBREW_ROOT;
our $PERLBREW_DEFAULT_VERSION // die '$PERL5_DEFAULT_VERSION not set';

use FindBin ();
use File::Spec ();
use Getopt::Long;

my $tmp_base_dir = File::Spec->catdir( $FindBin::Bin, 'tmp' );
$tmp_base_dir = File::Spec->catdir(
  File::Spec->tmpdir, ( File::Spec->splitdir( $FindBin::Bin ))[ -1 ]
  ) unless -d $tmp_base_dir and -w $tmp_base_dir;

my $pb_root    = $ENV{PERLBREW_ROOT} || $PERLBREW_ROOT;
my $pb_home    = File::Spec->catdir( $tmp_base_dir, 'perlbrew' );

GetOptions( "perl=s" => \ my $pb_version );
$pb_version ||= $PERLBREW_DEFAULT_VERSION;

print "Using perlbrew root $pb_root\n";
print "Using temporary perlbrew home $pb_home\n";

my $pb_exec = qx{ which perlbrew } || "${pb_root}/bin/perlbrew";
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

if ( !$ENV{PERLBREW_PERL} or $ENV{PERLBREW_PERL} ne $pb_version ) {
  print "Restarting $0 under $pb_version\n\n";
  $ENV{PERLBREW_ROOT} = $pb_root;
  $ENV{PERLBREW_HOME} = $pb_home;
  exec $pb_exec, 'exec', '--with', $pb_version, $0, @INITIAL_ARGS;
}

sub write_env {
  my $env = shift;

# FIXME:      printf $env <<'PERLBREW_HOME', $pb_home;
# FIXME:  # Initializing perlbrew environment
# FIXME:
# FIXME:  if [[
# FIXME:    -w "$MIST_APP_ROOT/tmp/perlbrew" ||
# FIXME:    ( -w "$MIST_APP_ROOT/tmp" && ! -e "$MIST_APP_ROOT/tmp/perlbrew" )
# FIXME:  ]] ; then
# FIXME:    export PERLBREW_HOME="$MIST_APP_ROOT/tmp/perlbrew"
# FIXME:  else
# FIXME:    export PERLBREW_HOME="%%s"
# FIXME:  fi
# FIXME:  PERLBREW_HOME

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
