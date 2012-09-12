package App::Mist::Command::compile;

use strict;
use warnings;

use App::Mist -command;

use Try::Tiny;
use Path::Class qw/dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $app       = $self->app;
  my $home      = $app->project_root;
  my $mpan      = $app->mpan_dist;
  my $mpan_conf = $app->mpan_conf;
  my $local_lib = $app->local_lib;

  my $dist_perlbrew = $mpan_conf->file(qw/ 00.perlbrew.txt /);
  my $dist_prereqs  = $mpan_conf->file(qw/ 00.prereqs.pl   /);
  my $dist_prepend  = $mpan_conf->file(qw/ 01.prepend.txt  /);
  my $dist_notest   = $mpan_conf->file(qw/ 02.notest.txt   /);

  chdir $home->stringify;
  $mpan_conf->mkpath;
  $_->touch for grep{ not -r $_->stringify }
    $dist_prepend, $dist_notest, $dist_perlbrew;

  if ( not -f -w "$dist_prereqs" ) {
    my $fh = $dist_prereqs->openw;
    print $fh <<'PREAMBLE'
# This file contains perl code that is run before anything
# else and can be used to ensure that the configuration of
# the host system confirms to expectations.
#
# I.E you an use the following lines to ensure that
# mysql_config (which is needed by DBD::mysql) is in the
# current PATH:
#
#   die <<ERROR if system("mysql_config --version") < 0;
#   Could not run mysql_config [$!]
#   Do you have libmysqlclient-dev installed?
#   ERROR
#
# Keep in mind that you can't use any modules that are not
# available on the host system in this file.

PREAMBLE
  }

  try {

    my $assert  = $self->app->slurp_file( $dist_prereqs );
    my @prepend = $self->app->slurp_file( $dist_prepend );
    my @notest  = $self->app->slurp_file( $dist_notest );
    my @prereqs = $self->app->fetch_prereqs;

    my $perlbrew_version = $self->app->perlbrew_version;
    my $perlbrew_init = '';

    if ( $perlbrew_version ) {
      my @args = (
        $self->app->perlbrew_root,
        $perlbrew_version,
      );
      $perlbrew_init = sprintf( <<'PERL', @args );
  use FindBin ();
  use File::Spec ();

  $tmp_base_dir = File::Spec->catdir( $FindBin::Bin, 'tmp' );
  $tmp_base_dir = File::Spec->catdir(
    File::Spec->tmpdir, ( File::Spec->splitdir( $Bin ))[ -1 ]
  ) unless -d $tmp_base_dir and -w $tmp_base_dir;

  $pb_root    = $ENV{PERLBREW_ROOT} || '%s';
  $pb_home    = File::Spec->catdir( $tmp_base_dir, 'perlbrew' );
  $pb_version = '%s';

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

  if ( not $ENV{PERLBREW_PERL} eq $pb_version ) {
    print "Restarting $0 under $pb_version\n\n";
    $ENV{PERLBREW_ROOT} = $pb_root;
    $ENV{PERLBREW_HOME} = $pb_home;
    exec $pb_exec, 'exec', '--with', $pb_version, $0;
  }

PERL
    }

    my @args = (
      $mpan->relative( $home ),
      $local_lib->relative( $home ),
      $perlbrew_init || '',
      $assert,
      @prepend ? sprintf( qq{'%s'}, join qq{',\n    '}, @prepend ) : '',
      @notest  ? sprintf( qq{'%s'}, join qq{',\n    '}, @notest  ) : '',
      @prereqs ? sprintf( qq{'%s'}, join qq{',\n    '}, @prereqs ) : '',
    );


    print STDERR "Generating mpan-install\n";

    open my $out, ">", "mpan-install.tmp" or die $!;

    while (<DATA>) {
      next if $_ eq "\n";
      print $out $_;
      last if /# END OF FATPACK CODE\s*$/;
    }

    printf $out <<'INSTALLER', @args;

use App::cpanminus::script;
use FindBin qw/$Bin/;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use File::Spec;
use Cwd qw/realpath/;

my $mpan      = File::Spec->catdir( $Bin, '%s' );
my $local_lib = File::Spec->catdir( $Bin, '%s' );

my $pb_root;
my $pb_home;
my $pb_version;

%s

sub run_cpanm {
  my $app       = App::cpanminus::script->new;
  my @options   = (
    "--quiet",
    "--local-lib-contained=${local_lib}",
    "--mirror=file://${mpan}",
    '--mirror-only',
  );

  $app->parse_options( @options, @_ );
  $app->doit or exit(1);
}

unless (caller) {

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

  my $p5_dir = realpath( File::Spec->catdir( $local_lib, File::Spec->updir ));
  my $rc_dir = File::Spec->catdir( $p5_dir, 'etc' );
  mkpath( $rc_dir );
  my $mist_rc = File::Spec->catfile( $rc_dir, 'mist.mistrc' );
  open my $env, '>', $mist_rc; # to catch write errors early on

  my $bin_dir = File::Spec->catdir( $p5_dir, 'bin' );
  mkpath( $bin_dir );
  my $mist_run = File::Spec->catfile( $bin_dir, 'mist-run');
  open my $wrapper, '>', $mist_run; # to catch write errors early on
  {
     my $perm = ( stat $mist_run )[2] & 07777;
     chmod( $perm | 0755, $mist_run );
  }

  local $ENV{HOME} = $workspace;

  eval <<'CHECK_PREREQS';
%s
CHECK_PREREQS

  if ( my $err = $@ ) {
    die "\n[FATAL] Error checking prerequisites:\n${err}\n";
  }

  my @prepend = (
    %s
  );
  my @notest  = (
    %s
  );
  my @prereqs = (
    %s
  );


  run_cpanm( @ARGV, @prepend ) if @prepend;
  run_cpanm( @ARGV, '--installdeps', @notest ) if @notest;
  run_cpanm( @ARGV, '--notest', @notest ) if @notest;
  run_cpanm( @ARGV, @prereqs ) if @prereqs;

  printf $env <<'MIST_ENV', $FindBin::Bin;
# This file is automatically generated by ./mpan-install
# DO NOT EDIT

export MIST_APP_ROOT="%%s"

MIST_ENV

  if ( $pb_version ) {
    printf $env <<'PERLBREW_HOME', $pb_home;
# Initializing perlbrew environment

if [[
  -w "$MIST_APP_ROOT/tmp/perlbrew" ||
  ( -w "$MIST_APP_ROOT/tmp" && ! -e "$MIST_APP_ROOT/tmp/perlbrew" )
]] ; then
  export PERLBREW_HOME="$MIST_APP_ROOT/tmp/perlbrew"
else
  export PERLBREW_HOME="%%s"
fi
PERLBREW_HOME

    print $env <<"PERLBREW_RC";

export PERLBREW_ROOT="$pb_root"
source "$pb_root/etc/bashrc"

perlbrew switch $pb_version

PERLBREW_RC
  }
  require local::lib;
  print $env local::lib->environment_vars_string_for( "${local_lib}" );
  close $env;

  printf $wrapper <<'WRAPPER', $Bin, $mist_rc;
#!/bin/bash

MIST_ROOT="%%s"
MIST_ENV="%%s"

if [ ! -r $MIST_ENV ] ; then
    echo "FATAL: Could not load env from $MIST_ENV"
    exit 1
fi

source $MIST_ENV
export PATH="$MIST_ROOT/bin:$MIST_ROOT/sbin:$PATH"

exec "$@"
WRAPPER

  print <<"SUCCESS";

Successfully created a mist environment for this distribution.
To enable it put the following line in your scripts:
  source $mist_rc

To run binaries from this distribution (\$HOME/bin and \$HOME/sbin are in
automatically prepended to \$PATH) you can also use this wrapper script:
  $mist_run my_script.pl [OPTIONS ..]

SUCCESS
}

INSTALLER

    close $out;

    unlink "mpan-install";
    rename "mpan-install.tmp", "mpan-install";
    chmod 0755, "mpan-install";

    print STDERR "Generating cmd wrapper\n";


    my $wrapper = $app->mpan_dist->file('cmd-wrapper.bash')->stringify;
    open $out, ">", $wrapper or die $!;

    print $out <<'CMD_WRAPPER';
#!/bin/bash

# get the absolute path of the executable
SELF_PATH=$(cd -P -- "$(dirname -- "$0")" && pwd -P) && SELF_PATH=$SELF_PATH/$(basename -- "$0")

# resolve symlinks
while [ -h $SELF_PATH ]; do
    # 1) cd to directory of the symlink
    # 2) cd to the directory of where the symlink points
    # 3) get the pwd
    # 4) append the basename
    DIR=$(dirname -- "$SELF_PATH")
    SYM=$(readlink $SELF_PATH)
    SELF_PATH=$(cd $DIR && cd $(dirname -- "$SYM") && pwd)/$(basename -- "$SYM")
done

WRAPPER=$(dirname $SELF_PATH)

CALL_PATH="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/$(basename $0)"

if [ $SELF_PATH == $CALL_PATH ] ; then
  echo "$(basename $0): Must be called as a symlink named like the command to be run" >&2
  exit 1
fi

# try to upward-find local::lib directory
for UPDIR in . .. ../.. ../../.. ../../../.. ; do
  TEST="$WRAPPER/$UPDIR/perl5";
  if [ -d $TEST ] ; then
      LOCAL_LIB=$( cd -P "$( dirname "$TEST" )" && pwd )
      BASE_DIR="$WRAPPER/$UPDIR"
      break
  fi
done

#exit if we can't find any
if [ ! $LOCAL_LIB ] ; then
  echo "$0: No local::lib directory found. Abort!" >&2
  exit 1
fi

$BASE_DIR/perl5/bin/mist-run `basename $0` $@

CMD_WRAPPER

    close $out;
    chmod 0755, $wrapper;

  } catch {
    warn "$_\n";
  } finally {

    unlink "mpan-install.tmp"

  };

}

1;

__DATA__

#!/usr/bin/env perl
#
# You want to install cpanminus? Run the following command and it will
# install itself for you. You might want to run it as a root with sudo
# if you want to install to places like /usr/local/bin.
#
#   % curl -L http://cpanmin.us | perl - --self-upgrade
#
# If you don't have curl but wget, replace `curl -L` with `wget -O -`.
#
# For more details about this program, visit http://search.cpan.org/dist/App-cpanminus
#
# DO NOT EDIT -- this is an auto generated file
# This chunk of stuff was generated by App::FatPacker. To find the original
# file's code, look for the end of this BEGIN block or the string 'FATPACK'
BEGIN {
my %fatpacked;

$fatpacked{"App/cpanminus.pm"} = <<'APP_CPANMINUS';
  package App::cpanminus;
  our $VERSION = "1.5017";

  =head1 NAME

  App::cpanminus - get, unpack, build and install modules from CPAN

  =head1 SYNOPSIS

      cpanm Module

  Run C<cpanm -h> for more options.

  =head1 DESCRIPTION

  cpanminus is a script to get, unpack, build and install modules from
  CPAN and does nothing else.

  It's dependency free (can bootstrap itself), requires zero
  configuration, and stands alone. When running, it requires only 10MB
  of RAM.

  =head1 INSTALLATION

  There are several ways to install cpanminus to your system.

  =head2 Package management system

  There are Debian packages, RPMs, FreeBSD ports, and packages for other
  operation systems available. If you want to use the package management system,
  search for cpanminus and use the appropriate command to install. This makes it
  easy to install C<cpanm> to your system without thinking about where to
  install, and later upgrade.

  =head2 Installing to system perl

  You can also use the latest cpanminus to install cpanminus itself:

      curl -L http://cpanmin.us | perl - --sudo App::cpanminus

  This will install C<cpanm> to your bin directory like
  C</usr/local/bin> (unless you configured C<INSTALL_BASE> with
  L<local::lib>), so you probably need the C<--sudo> option.

  =head2 Installing to local perl (perlbrew)

  If you have perl in your home directory, which is the case if you use
  tools like L<perlbrew>, you don't need the C<--sudo> option, since
  you're most likely to have a write permission to the perl's library
  path. You can just do:

      curl -L http://cpanmin.us | perl - App::cpanminus

  to install the C<cpanm> executable to the perl's bin path, like
  C<~/perl5/perlbrew/bin/cpanm>.

  =head2 Downloading the standalone executable

  You can also copy the standalone executable to whatever location you'd like.

      cd ~/bin
      curl -LO http://xrl.us/cpanm
      chmod +x cpanm
      # edit shebang if you don't have /usr/bin/env

  This just works, but be sure to grab the new version manually when you
  upgrade because C<--self-upgrade> might not work for this.

  =head1 DEPENDENCIES

  perl 5.8 or later.

  =over 4

  =item *

  'tar' executable (bsdtar or GNU tar version 1.22 are rcommended) or Archive::Tar to unpack files.

  =item *

  C compiler, if you want to build XS modules.

  =item *

  make

  =item *

  Module::Build (core in 5.10)

  =back

  =head1 QUESTIONS

  =head2 Another CPAN installer?

  OK, the first motivation was this: the CPAN shell runs out of memory (or swaps
  heavily and gets really slow) on Slicehost/linode's most affordable plan with
  only 256MB RAM. Should I pay more to install perl modules from CPAN? I don't
  think so.

  =head2 But why a new client?

  First of all, let me be clear that CPAN and CPANPLUS are great tools
  I've used for I<literally> years (you know how many modules I have on
  CPAN, right?). I really respect their efforts of maintaining the most
  important tools in the CPAN toolchain ecosystem.

  However, for less experienced users (mostly from outside the Perl community),
  or even really experienced Perl developers who know how to shoot themselves in
  their feet, setting up the CPAN toolchain often feels like yak shaving,
  especially when all they want to do is just install some modules and start
  writing code.

  =head2 Zero-conf? How does this module get/parse/update the CPAN index?

  It queries the CPAN Meta DB site running on Google AppEngine at
  L<http://cpanmetadb.plackperl.org/>. The site is updated every hour to reflect
  the latest changes from fast syncing mirrors. The script then also falls back
  to scrape the site L<http://search.cpan.org/>.

  Fetched files are unpacked in C<~/.cpanm> and automatically cleaned up
  periodically.  You can configure the location of this with the
  C<PERL_CPANM_HOME> environment variable.

  =head2 Where does this install modules to? Do I need root access?

  It installs to wherever ExtUtils::MakeMaker and Module::Build are
  configured to (via C<PERL_MM_OPT> and C<PERL_MB_OPT>). So if you're
  using local::lib, then it installs to your local perl5
  directory. Otherwise it installs to the site_perl directory that
  belongs to your perl.

  cpanminus at a boot time checks whether you have configured
  local::lib, or have the permission to install modules to the site_perl
  directory.  If neither, it automatically sets up local::lib compatible
  installation path in a C<perl5> directory under your home
  directory. To avoid this, run the script as the root user, with
  C<--sudo> option or with C<--local-lib> option.

  =head2 cpanminus can't install the module XYZ. Is it a bug?

  It is more likely a problem with the distribution itself. cpanminus
  doesn't support or is known to have issues with distributions like as
  follows:

  =over 4

  =item *

  Tests that require input from STDIN.

  =item *

  Tests that might fail when C<AUTOMATED_TESTING> is enabled.

  =item *

  Modules that have invalid numeric values as VERSION (such as C<1.1a>)

  =back

  These failures can be reported back to the author of the module so
  that they can fix it accordingly, rather than me.

  =head2 Does cpanm support the feature XYZ of L<CPAN> and L<CPANPLUS>?

  Most likely not. Here are the things that cpanm doesn't do by
  itself. And it's a feature - you got that from the name I<minus>,
  right?

  If you need these features, use L<CPAN>, L<CPANPLUS> or the standalone
  tools that are mentioned.

  =over 4

  =item *

  Bundle:: module dependencies

  =item *

  CPAN testers reporting

  =item *

  Building RPM packages from CPAN modules

  =item *

  Listing the outdated modules that needs upgrading. See L<App::cpanoutdated>

  =item *

  Uninstalling modules. See L<pm-uninstall>.

  =item *

  Showing the changes of the modules you're about to upgrade. See L<cpan-listchanges>

  =item *

  Patching CPAN modules with distroprefs.

  =back

  See L<cpanm> or C<cpanm -h> to see what cpanminus I<can> do :)

  =head1 COPYRIGHT

  Copyright 2010- Tatsuhiko Miyagawa

  The standalone executable contains the following modules embedded.

  =over 4

  =item L<CPAN::DistnameInfo> Copyright 2003 Graham Barr

  =item L<Parse::CPAN::Meta> Copyright 2006-2009 Adam Kennedy

  =item L<local::lib> Copyright 2007-2009 Matt S Trout

  =item L<HTTP::Tiny> Copyright 2011 Christian Hansen

  =item L<Module::Metadata> Copyright 2001-2006 Ken Williams. 2010 Matt S Trout

  =item L<version> Copyright 2004-2010 John Peacock

  =item L<JSON::PP> Copyright 2007—2011 by Makamaka Hannyaharamitu

  =item L<CPAN::Meta> Copyright (c) 2010 by David Golden and Ricardo Signes

  =item L<Try::Tiny> Copyright (c) 2009 Yuval Kogman

  =item L<parent> Copyright (c) 2007-10 Max Maischein

  =item L<Version::Requirements> copyright (c) 2010 by Ricardo Signes

  =item L<CPAN::Meta::YAML> copyright (c) 2010 by Adam Kennedy

  =back

  =head1 LICENSE

  Same as Perl.

  =head1 CREDITS

  =head2 CONTRIBUTORS

  Patches and code improvements were contributed by:

  Goro Fuji, Kazuhiro Osawa, Tokuhiro Matsuno, Kenichi Ishigaki, Ian
  Wells, Pedro Melo, Masayoshi Sekimura, Matt S Trout (mst), squeeky,
  horus and Ingy dot Net.

  =head2 ACKNOWLEDGEMENTS

  Bug reports, suggestions and feedbacks were sent by, or general
  acknowledgement goes to:

  Jesse Vincent, David Golden, Andreas Koenig, Jos Boumans, Chris
  Williams, Adam Kennedy, Audrey Tang, J. Shirley, Chris Prather, Jesse
  Luehrs, Marcus Ramberg, Shawn M Moore, chocolateboy, Chirs Nehren,
  Jonathan Rockway, Leon Brocard, Simon Elliott, Ricardo Signes, AEvar
  Arnfjord Bjarmason, Eric Wilhelm, Florian Ragwitz and xaicron.

  =head1 COMMUNITY

  =over 4

  =item L<http://github.com/miyagawa/cpanminus> - source code repository, issue tracker

  =item L<irc://irc.perl.org/#toolchain> - discussions about Perl toolchain. I'm there.

  =back

  =head1 NO WARRANTY

  This software is provided "as-is," without any express or implied
  warranty. In no event shall the author be held liable for any damages
  arising from the use of the software.

  =head1 SEE ALSO

  L<CPAN> L<CPANPLUS> L<pip>

  =cut

  1;
APP_CPANMINUS

$fatpacked{"App/cpanminus/script.pm"} = <<'APP_CPANMINUS_SCRIPT';
  package App::cpanminus::script;
  use strict;
  use Config;
  use Cwd ();
  use File::Basename ();
  use File::Find ();
  use File::Path ();
  use File::Spec ();
  use File::Copy ();
  use Getopt::Long ();
  use Parse::CPAN::Meta;
  use Symbol ();

  use constant WIN32 => $^O eq 'MSWin32';
  use constant SUNOS => $^O eq 'solaris';

  our $VERSION = "1.5017";

  my $quote = WIN32 ? q/"/ : q/'/;

  sub new {
      my $class = shift;

      bless {
          home => "$ENV{HOME}/.cpanm",
          cmd  => 'install',
          seen => {},
          notest => undef,
          test_only => undef,
          installdeps => undef,
          force => undef,
          sudo => undef,
          make  => undef,
          verbose => undef,
          quiet => undef,
          interactive => undef,
          log => undef,
          mirrors => [],
          mirror_only => undef,
          mirror_index => undef,
          perl => $^X,
          argv => [],
          local_lib => undef,
          self_contained => undef,
          prompt_timeout => 0,
          prompt => undef,
          configure_timeout => 60,
          try_lwp => 1,
          try_wget => 1,
          try_curl => 1,
          uninstall_shadows => ($] < 5.012),
          skip_installed => 1,
          skip_satisfied => 0,
          auto_cleanup => 7, # days
          pod2man => 1,
          installed_dists => 0,
          showdeps => 0,
          scandeps => 0,
          scandeps_tree => [],
          format   => 'tree',
          save_dists => undef,
          skip_configure => 0,
          @_,
      }, $class;
  }

  sub env {
      my($self, $key) = @_;
      $ENV{"PERL_CPANM_" . $key};
  }

  sub parse_options {
      my $self = shift;

      local @ARGV = @{$self->{argv}};
      push @ARGV, split /\s+/, $self->env('OPT');
      push @ARGV, @_;

      Getopt::Long::Configure("bundling");
      Getopt::Long::GetOptions(
          'f|force'   => sub { $self->{skip_installed} = 0; $self->{force} = 1 },
          'n|notest!' => \$self->{notest},
          'test-only' => sub { $self->{notest} = 0; $self->{skip_installed} = 0; $self->{test_only} = 1 },
          'S|sudo!'   => \$self->{sudo},
          'v|verbose' => sub { $self->{verbose} = $self->{interactive} = 1 },
          'q|quiet!'  => \$self->{quiet},
          'h|help'    => sub { $self->{action} = 'show_help' },
          'V|version' => sub { $self->{action} = 'show_version' },
          'perl=s'    => \$self->{perl},
          'l|local-lib=s' => sub { $self->{local_lib} = $self->maybe_abs($_[1]) },
          'L|local-lib-contained=s' => sub {
              $self->{local_lib} = $self->maybe_abs($_[1]);
              $self->{self_contained} = 1;
              $self->{pod2man} = undef;
          },
          'mirror=s@' => $self->{mirrors},
          'mirror-only!' => \$self->{mirror_only},
          'mirror-index=s'  => sub { $self->{mirror_index} = $_[1]; $self->{mirror_only} = 1 },
          'cascade-search!' => \$self->{cascade_search},
          'prompt!'   => \$self->{prompt},
          'installdeps' => \$self->{installdeps},
          'skip-installed!' => \$self->{skip_installed},
          'skip-satisfied!' => \$self->{skip_satisfied},
          'reinstall'    => sub { $self->{skip_installed} = 0 },
          'interactive!' => \$self->{interactive},
          'i|install' => sub { $self->{cmd} = 'install' },
          'info'      => sub { $self->{cmd} = 'info' },
          'look'      => sub { $self->{cmd} = 'look'; $self->{skip_installed} = 0 },
          'self-upgrade' => sub { $self->{cmd} = 'install'; $self->{skip_installed} = 1; push @ARGV, 'App::cpanminus' },
          'uninst-shadows!'  => \$self->{uninstall_shadows},
          'lwp!'    => \$self->{try_lwp},
          'wget!'   => \$self->{try_wget},
          'curl!'   => \$self->{try_curl},
          'auto-cleanup=s' => \$self->{auto_cleanup},
          'man-pages!' => \$self->{pod2man},
          'scandeps'   => \$self->{scandeps},
          'showdeps'   => sub { $self->{showdeps} = 1; $self->{skip_installed} = 0 },
          'format=s'   => \$self->{format},
          'save-dists=s' => sub {
              $self->{save_dists} = $self->maybe_abs($_[1]);
          },
          'skip-configure!' => \$self->{skip_configure},
          'metacpan'   => \$self->{metacpan},
      );

      if (!@ARGV && $0 ne '-' && !-t STDIN){ # e.g. # cpanm < author/requires.cpanm
          push @ARGV, $self->load_argv_from_fh(\*STDIN);
          $self->{load_from_stdin} = 1;
      }

      $self->{argv} = \@ARGV;
  }

  sub check_libs {
      my $self = shift;
      return if $self->{_checked}++;

      $self->bootstrap_local_lib;
      if (@{$self->{bootstrap_deps} || []}) {
          local $self->{notest} = 1; # test failure in bootstrap should be tolerated
          local $self->{scandeps} = 0;
          $self->install_deps(Cwd::cwd, 0, @{$self->{bootstrap_deps}});
      }
  }

  sub doit {
      my $self = shift;

      $self->setup_home;
      $self->init_tools;

      if (my $action = $self->{action}) {
          $self->$action() and return 1;
      }

      $self->show_help(1)
          unless @{$self->{argv}} or $self->{load_from_stdin};

      $self->configure_mirrors;

      my $cwd = Cwd::cwd;

      my @fail;
      for my $module (@{$self->{argv}}) {
          if ($module =~ s/\.pm$//i) {
              my ($volume, $dirs, $file) = File::Spec->splitpath($module);
              $module = join '::', grep { $_ } File::Spec->splitdir($dirs), $file;
          }

          ($module, my $version) = split /\~/, $module, 2 if $module =~ /\~[v\d\._]+$/;
          if ($self->{skip_satisfied} or defined $version) {
              $self->check_libs;
              my($ok, $local) = $self->check_module($module, $version || 0);
              if ($ok) {
                  $self->diag("You have $module (" . ($local || 'undef') . ")\n", 1);
                  next;
              }
          }

          $self->chdir($cwd);
          $self->install_module($module, 0, $version)
              or push @fail, $module;
      }

      if ($self->{base} && $self->{auto_cleanup}) {
          $self->cleanup_workdirs;
      }

      if ($self->{installed_dists}) {
          my $dists = $self->{installed_dists} > 1 ? "distributions" : "distribution";
          $self->diag("$self->{installed_dists} $dists installed\n", 1);
      }

      if ($self->{scandeps}) {
          $self->dump_scandeps();
      }

      return !@fail;
  }

  sub setup_home {
      my $self = shift;

      $self->{home} = $self->env('HOME') if $self->env('HOME');

      unless (_writable($self->{home})) {
          die "Can't write to cpanm home '$self->{home}': You should fix it with chown/chmod first.\n";
      }

      $self->{base} = "$self->{home}/work/" . time . ".$$";
      File::Path::mkpath([ $self->{base} ], 0, 0777);

      my $link = "$self->{home}/latest-build";
      eval { unlink $link; symlink $self->{base}, $link };

      $self->{log} = File::Spec->catfile($self->{home}, "build.log"); # because we use shell redirect

      {
          my $log = $self->{log}; my $base = $self->{base};
          $self->{at_exit} = sub {
              my $self = shift;
              File::Copy::copy($self->{log}, "$self->{base}/build.log");
          };
      }

      { open my $out, ">$self->{log}" or die "$self->{log}: $!" }

      $self->chat("cpanm (App::cpanminus) $VERSION on perl $] built for $Config{archname}\n" .
                  "Work directory is $self->{base}\n");
  }

  sub fetch_meta_sco {
      my($self, $dist) = @_;
      return if $self->{mirror_only};

      my $meta_yml = $self->get("http://search.cpan.org/meta/$dist->{distvname}/META.yml");
      return $self->parse_meta_string($meta_yml);
  }

  sub package_index_for {
      my ($self, $mirror) = @_;
      return $self->source_for($mirror) . "/02packages.details.txt";
  }

  sub generate_mirror_index {
      my ($self, $mirror) = @_;
      my $file = $self->package_index_for($mirror);
      my $gz_file = $file . '.gz';
      my $index_mtime = (stat $gz_file)[9];

      unless (-e $file && (stat $file)[9] >= $index_mtime) {
          $self->chat("Uncompressing index file...\n");
          if (eval {require Compress::Zlib}) {
              my $gz = Compress::Zlib::gzopen($gz_file, "rb")
                  or do { $self->diag_fail("$Compress::Zlib::gzerrno opening compressed index"); return};
              open my $fh, '>', $file
                  or do { $self->diag_fail("$! opening uncompressed index for write"); return };
              my $buffer;
              while (my $status = $gz->gzread($buffer)) {
                  if ($status < 0) {
                      $self->diag_fail($gz->gzerror . " reading compressed index");
                      return;
                  }
                  print $fh $buffer;
              }
          } else {
              if (system("gunzip -c $gz_file > $file")) {
                  $self->diag_fail("Cannot uncompress -- please install gunzip or Compress::Zlib");
                  return;
              }
          }
          utime $index_mtime, $index_mtime, $file;
      }
      return 1;
  }

  sub search_mirror_index {
      my ($self, $mirror, $module, $version) = @_;
      $self->search_mirror_index_file($self->package_index_for($mirror), $module, $version);
  }

  sub search_mirror_index_file {
      my($self, $file, $module, $version) = @_;

      open my $fh, '<', $file or return;
      my $found;
      while (<$fh>) {
          if (m!^\Q$module\E\s+([\w\.]+)\s+(.*)!m) {
              $found = $self->cpan_module($module, $2, $1);
              last;
          }
      }

      return $found unless $self->{cascade_search};

      if ($found) {
          if (!$version or
              version->new($found->{version} || 0) >= version->new($version)) {
              return $found;
          } else {
              $self->chat("Found $module version $found->{version} < $version.\n");
          }
      }

      return;
  }

  sub search_module {
      my($self, $module, $version) = @_;

      if ($self->{mirror_index}) {
          $self->chat("Searching $module on mirror index $self->{mirror_index} ...\n");
          my $pkg = $self->search_mirror_index_file($self->{mirror_index}, $module, $version);
          return $pkg if $pkg;

          unless ($self->{cascade_search}) {
             $self->diag_fail("Finding $module ($version) on mirror index $self->{mirror_index} failed.");
             return;
          }
      }

      unless ($self->{mirror_only}) {
          if ($self->{metacpan}) {
              require JSON::PP;
              $self->chat("Searching $module on metacpan ...\n");
              my $module_uri  = "http://api.metacpan.org/module/$module";
              my $module_json = $self->get($module_uri);
              my $module_meta = eval { JSON::PP::decode_json($module_json) };
              if ($module_meta && $module_meta->{distribution}) {
                  my $dist_uri = "http://api.metacpan.org/release/$module_meta->{distribution}";
                  my $dist_json = $self->get($dist_uri);
                  my $dist_meta = eval { JSON::PP::decode_json($dist_json) };
                  if ($dist_meta && $dist_meta->{download_url}) {
                      (my $distfile = $dist_meta->{download_url}) =~ s!.+/authors/id/!!;
                      local $self->{mirrors} = $self->{mirrors};
                      if ($dist_meta->{stat}->{mtime} > time()-24*60*60) {
                          $self->{mirrors} = ['http://cpan.metacpan.org'];
                      }
                      return $self->cpan_module($module, $distfile, $dist_meta->{version});
                  }
              }
              $self->diag_fail("Finding $module on metacpan failed.");
          }

          $self->chat("Searching $module on cpanmetadb ...\n");
          my $uri  = "http://cpanmetadb.plackperl.org/v1.0/package/$module";
          my $yaml = $self->get($uri);
          my $meta = $self->parse_meta_string($yaml);
          if ($meta && $meta->{distfile}) {
              return $self->cpan_module($module, $meta->{distfile}, $meta->{version});
          }

          $self->diag_fail("Finding $module on cpanmetadb failed.");

          $self->chat("Searching $module on search.cpan.org ...\n");
          my $uri  = "http://search.cpan.org/perldoc?$module";
          my $html = $self->get($uri);
          $html =~ m!<a href="/CPAN/authors/id/(.*?\.(?:tar\.gz|tgz|tar\.bz2|zip))">!
              and return $self->cpan_module($module, $1);

          $self->diag_fail("Finding $module on search.cpan.org failed.");
      }

      MIRROR: for my $mirror (@{ $self->{mirrors} }) {
          $self->chat("Searching $module on mirror $mirror ...\n");
          my $name = '02packages.details.txt.gz';
          my $uri  = "$mirror/modules/$name";
          my $gz_file = $self->package_index_for($mirror) . '.gz';

          unless ($self->{pkgs}{$uri}) {
              $self->chat("Downloading index file $uri ...\n");
              $self->mirror($uri, $gz_file);
              $self->generate_mirror_index($mirror) or next MIRROR;
              $self->{pkgs}{$uri} = "!!retrieved!!";
          }

          my $pkg = $self->search_mirror_index($mirror, $module, $version);
          return $pkg if $pkg;

          $self->diag_fail("Finding $module ($version) on mirror $mirror failed.");
      }

      return;
  }

  sub source_for {
      my($self, $mirror) = @_;
      $mirror =~ s/[^\w\.\-]+/%/g;

      my $dir = "$self->{home}/sources/$mirror";
      File::Path::mkpath([ $dir ], 0, 0777);

      return $dir;
  }

  sub load_argv_from_fh {
      my($self, $fh) = @_;

      my @argv;
      while(defined(my $line = <$fh>)){
          chomp $line;
          $line =~ s/#.+$//; # comment
          $line =~ s/^\s+//; # trim spaces
          $line =~ s/\s+$//; # trim spaces

          push @argv, split ' ', $line if $line;
      }
      return @argv;
  }

  sub show_version {
      print "cpanm (App::cpanminus) version $VERSION\n";
      return 1;
  }

  sub show_help {
      my $self = shift;

      if ($_[0]) {
          die <<USAGE;
  Usage: cpanm [options] Module [...]

  Try `cpanm --help` or `man cpanm` for more options.
  USAGE
      }

      print <<HELP;
  Usage: cpanm [options] Module [...]

  Options:
    -v,--verbose              Turns on chatty output
    -q,--quiet                Turns off the most output
    --interactive             Turns on interactive configure (required for Task:: modules)
    -f,--force                force install
    -n,--notest               Do not run unit tests
    --test-only               Run tests only, do not install
    -S,--sudo                 sudo to run install commands
    --installdeps             Only install dependencies
    --showdeps                Only display direct dependencies
    --reinstall               Reinstall the distribution even if you already have the latest version installed
    --mirror                  Specify the base URL for the mirror (e.g. http://cpan.cpantesters.org/)
    --mirror-only             Use the mirror's index file instead of the CPAN Meta DB
    --prompt                  Prompt when configure/build/test fails
    -l,--local-lib            Specify the install base to install modules
    -L,--local-lib-contained  Specify the install base to install all non-core modules
    --auto-cleanup            Number of days that cpanm's work directories expire in. Defaults to 7

  Commands:
    --self-upgrade            upgrades itself
    --info                    Displays distribution info on CPAN
    --look                    Opens the distribution with your SHELL
    -V,--version              Displays software version

  Examples:

    cpanm Test::More                                          # install Test::More
    cpanm MIYAGAWA/Plack-0.99_05.tar.gz                       # full distribution path
    cpanm http://example.org/LDS/CGI.pm-3.20.tar.gz           # install from URL
    cpanm ~/dists/MyCompany-Enterprise-1.00.tar.gz            # install from a local file
    cpanm --interactive Task::Kensho                          # Configure interactively
    cpanm .                                                   # install from local directory
    cpanm --installdeps .                                     # install all the deps for the current directory
    cpanm -L extlib Plack                                     # install Plack and all non-core deps into extlib
    cpanm --mirror http://cpan.cpantesters.org/ DBI           # use the fast-syncing mirror

  You can also specify the default options in PERL_CPANM_OPT environment variable in the shell rc:

    export PERL_CPANM_OPT="--prompt --reinstall -l ~/perl --mirror http://cpan.cpantesters.org"

  Type `man cpanm` or `perldoc cpanm` for the more detailed explanation of the options.

  HELP

      return 1;
  }

  sub _writable {
      my $dir = shift;
      my @dir = File::Spec->splitdir($dir);
      while (@dir) {
          $dir = File::Spec->catdir(@dir);
          if (-e $dir) {
              return -w _;
          }
          pop @dir;
      }

      return;
  }

  sub maybe_abs {
      my($self, $lib) = @_;
      return $lib if $lib eq '_'; # special case: gh-113
      $lib =~ /^[~\/]/ ? $lib : File::Spec->canonpath(Cwd::cwd . "/$lib");
  }

  sub bootstrap_local_lib {
      my $self = shift;

      # If -l is specified, use that.
      if ($self->{local_lib}) {
          return $self->setup_local_lib($self->{local_lib});
      }

      # root, locally-installed perl or --sudo: don't care about install_base
      return if $self->{sudo} or (_writable($Config{installsitelib}) and _writable($Config{installsitebin}));

      # local::lib is configured in the shell -- yay
      if ($ENV{PERL_MM_OPT} and ($ENV{MODULEBUILDRC} or $ENV{PERL_MB_OPT})) {
          $self->bootstrap_local_lib_deps;
          return;
      }

      $self->setup_local_lib;

      $self->diag(<<DIAG);
  !
  ! Can't write to $Config{installsitelib} and $Config{installsitebin}: Installing modules to $ENV{HOME}/perl5
  ! To turn off this warning, you have to do one of the following:
  !   - run me as a root or with --sudo option (to install to $Config{installsitelib} and $Config{installsitebin})
  !   - Configure local::lib your existing local::lib in this shell to set PERL_MM_OPT etc.
  !   - Install local::lib by running the following commands
  !
  !         cpanm --local-lib=~/perl5 local::lib && eval \$(perl -I ~/perl5/lib/perl5/ -Mlocal::lib)
  !
  DIAG
      sleep 2;
  }

  sub _core_only_inc {
      my($self, $base) = @_;
      require local::lib;
      (
          local::lib->resolve_path(local::lib->install_base_perl_path($base)),
          local::lib->resolve_path(local::lib->install_base_arch_path($base)),
          @Config{qw(privlibexp archlibexp)},
      );
  }

  sub _diff {
      my($self, $old, $new) = @_;

      my @diff;
      my %old = map { $_ => 1 } @$old;
      for my $n (@$new) {
          push @diff, $n unless exists $old{$n};
      }

      @diff;
  }

  sub _setup_local_lib_env {
      my($self, $base) = @_;
      local $SIG{__WARN__} = sub { }; # catch 'Attempting to write ...'
      local::lib->setup_env_hash_for($base);
  }

  sub setup_local_lib {
      my($self, $base) = @_;
      $base = undef if $base eq '_';

      require local::lib;
      {
          local $0 = 'cpanm'; # so curl/wget | perl works
          $base ||= "~/perl5";
          if ($self->{self_contained}) {
              my @inc = $self->_core_only_inc($base);
              $self->{search_inc} = [ @inc ];
          } else {
              $self->{search_inc} = [
                  local::lib->resolve_path(local::lib->install_base_arch_path($base)),
                  local::lib->resolve_path(local::lib->install_base_perl_path($base)),
                  @INC,
              ];
          }
          $self->_setup_local_lib_env($base);
      }

      $self->bootstrap_local_lib_deps;
  }

  sub bootstrap_local_lib_deps {
      my $self = shift;
      push @{$self->{bootstrap_deps}},
          'ExtUtils::MakeMaker' => 6.31,
          'ExtUtils::Install'   => 1.46;
  }

  sub prompt_bool {
      my($self, $mess, $def) = @_;

      my $val = $self->prompt($mess, $def);
      return lc $val eq 'y';
  }

  sub prompt {
      my($self, $mess, $def) = @_;

      my $isa_tty = -t STDIN && (-t STDOUT || !(-f STDOUT || -c STDOUT)) ;
      my $dispdef = defined $def ? "[$def] " : " ";
      $def = defined $def ? $def : "";

      if (!$self->{prompt} || (!$isa_tty && eof STDIN)) {
          return $def;
      }

      local $|=1;
      local $\;
      my $ans;
      eval {
          local $SIG{ALRM} = sub { undef $ans; die "alarm\n" };
          print STDOUT "$mess $dispdef";
          alarm $self->{prompt_timeout} if $self->{prompt_timeout};
          $ans = <STDIN>;
          alarm 0;
      };
      if ( defined $ans ) {
          chomp $ans;
      } else { # user hit ctrl-D or alarm timeout
          print STDOUT "\n";
      }

      return (!defined $ans || $ans eq '') ? $def : $ans;
  }

  sub diag_ok {
      my($self, $msg) = @_;
      chomp $msg;
      $msg ||= "OK";
      if ($self->{in_progress}) {
          $self->_diag("$msg\n");
          $self->{in_progress} = 0;
      }
      $self->log("-> $msg\n");
  }

  sub diag_fail {
      my($self, $msg, $always) = @_;
      chomp $msg;
      if ($self->{in_progress}) {
          $self->_diag("FAIL\n");
          $self->{in_progress} = 0;
      }

      if ($msg) {
          $self->_diag("! $msg\n", $always);
          $self->log("-> FAIL $msg\n");
      }
  }

  sub diag_progress {
      my($self, $msg) = @_;
      chomp $msg;
      $self->{in_progress} = 1;
      $self->_diag("$msg ... ");
      $self->log("$msg\n");
  }

  sub _diag {
      my($self, $msg, $always) = @_;
      print STDERR $msg if $always or $self->{verbose} or !$self->{quiet};
  }

  sub diag {
      my($self, $msg, $always) = @_;
      $self->_diag($msg, $always);
      $self->log($msg);
  }

  sub chat {
      my $self = shift;
      print STDERR @_ if $self->{verbose};
      $self->log(@_);
  }

  sub log {
      my $self = shift;
      open my $out, ">>$self->{log}";
      print $out @_;
  }

  sub run {
      my($self, $cmd) = @_;

      if (WIN32 && ref $cmd eq 'ARRAY') {
          $cmd = join q{ }, map { $self->shell_quote($_) } @$cmd;
      }

      if (ref $cmd eq 'ARRAY') {
          my $pid = fork;
          if ($pid) {
              waitpid $pid, 0;
              return !$?;
          } else {
              $self->run_exec($cmd);
          }
      } else {
          unless ($self->{verbose}) {
              $cmd .= " >> " . $self->shell_quote($self->{log}) . " 2>&1";
          }
          !system $cmd;
      }
  }

  sub run_exec {
      my($self, $cmd) = @_;

      if (ref $cmd eq 'ARRAY') {
          unless ($self->{verbose}) {
              open my $logfh, ">>", $self->{log};
              open STDERR, '>&', $logfh;
              open STDOUT, '>&', $logfh;
              close $logfh;
          }
          exec @$cmd;
      } else {
          unless ($self->{verbose}) {
              $cmd .= " >> " . $self->shell_quote($self->{log}) . " 2>&1";
          }
          exec $cmd;
      }
  }

  sub run_timeout {
      my($self, $cmd, $timeout) = @_;
      return $self->run($cmd) if WIN32 || $self->{verbose} || !$timeout;

      my $pid = fork;
      if ($pid) {
          eval {
              local $SIG{ALRM} = sub { die "alarm\n" };
              alarm $timeout;
              waitpid $pid, 0;
              alarm 0;
          };
          if ($@ && $@ eq "alarm\n") {
              $self->diag_fail("Timed out (> ${timeout}s). Use --verbose to retry.");
              local $SIG{TERM} = 'IGNORE';
              kill TERM => 0;
              waitpid $pid, 0;
              return;
          }
          return !$?;
      } elsif ($pid == 0) {
          $self->run_exec($cmd);
      } else {
          $self->chat("! fork failed: falling back to system()\n");
          $self->run($cmd);
      }
  }

  sub configure {
      my($self, $cmd) = @_;

      # trick AutoInstall
      local $ENV{PERL5_CPAN_IS_RUNNING} = local $ENV{PERL5_CPANPLUS_IS_RUNNING} = $$;

      # e.g. skip CPAN configuration on local::lib
      local $ENV{PERL5_CPANM_IS_RUNNING} = $$;

      my $use_default = !$self->{interactive};
      local $ENV{PERL_MM_USE_DEFAULT} = $use_default;

      # skip man page generation
      local $ENV{PERL_MM_OPT} = $ENV{PERL_MM_OPT};
      unless ($self->{pod2man}) {
          $ENV{PERL_MM_OPT} .= " INSTALLMAN1DIR=none INSTALLMAN3DIR=none";
      }

      local $self->{verbose} = $self->{verbose} || $self->{interactive};
      $self->run_timeout($cmd, $self->{configure_timeout});
  }

  sub build {
      my($self, $cmd, $distname) = @_;

      return 1 if $self->run_timeout($cmd, $self->{build_timeout});
      while (1) {
          my $ans = lc $self->prompt("Building $distname failed.\nYou can s)kip, r)etry, e)xamine build log, or l)ook ?", "s");
          return                               if $ans eq 's';
          return $self->build($cmd, $distname) if $ans eq 'r';
          $self->show_build_log                if $ans eq 'e';
          $self->look                          if $ans eq 'l';
      }
  }

  sub test {
      my($self, $cmd, $distname) = @_;
      return 1 if $self->{notest};

      # https://rt.cpan.org/Ticket/Display.html?id=48965#txn-1013385
      local $ENV{PERL_MM_USE_DEFAULT} = 1;

      return 1 if $self->run_timeout($cmd, $self->{test_timeout});
      if ($self->{force}) {
          $self->diag_fail("Testing $distname failed but installing it anyway.");
          return 1;
      } else {
          $self->diag_fail;
          while (1) {
              my $ans = lc $self->prompt("Testing $distname failed.\nYou can s)kip, r)etry, f)orce install, e)xamine build log, or l)ook ?", "s");
              return                              if $ans eq 's';
              return $self->test($cmd, $distname) if $ans eq 'r';
              return 1                            if $ans eq 'f';
              $self->show_build_log               if $ans eq 'e';
              $self->look                         if $ans eq 'l';
          }
      }
  }

  sub install {
      my($self, $cmd, $uninst_opts, $depth) = @_;

      if ($depth == 0 && $self->{test_only}) {
          return 1;
      }

      if ($self->{sudo}) {
          unshift @$cmd, "sudo";
      }

      if ($self->{uninstall_shadows} && !$ENV{PERL_MM_OPT}) {
          push @$cmd, @$uninst_opts;
      }

      $self->run($cmd);
  }

  sub look {
      my $self = shift;

      my $shell = $ENV{SHELL};
      $shell  ||= $ENV{COMSPEC} if WIN32;
      if ($shell) {
          my $cwd = Cwd::cwd;
          $self->diag("Entering $cwd with $shell\n");
          system $shell;
      } else {
          $self->diag_fail("You don't seem to have a SHELL :/");
      }
  }

  sub show_build_log {
      my $self = shift;

      my @pagers = (
          $ENV{PAGER},
          (WIN32 ? () : ('less')),
          'more'
      );
      my $pager;
      while (@pagers) {
          $pager = shift @pagers;
          next unless $pager;
          $pager = $self->which($pager);
          next unless $pager;
          last;
      }

      if ($pager) {
          # win32 'more' doesn't allow "more build.log", the < is required
          system("$pager < $self->{log}");
      }
      else {
          $self->diag_fail("You don't seem to have a PAGER :/");
      }
  }

  sub chdir {
      my $self = shift;
      Cwd::chdir(File::Spec->canonpath($_[0])) or die "$_[0]: $!";
  }

  sub configure_mirrors {
      my $self = shift;
      unless (@{$self->{mirrors}}) {
          $self->{mirrors} = [ 'http://www.cpan.org' ];
      }
      for (@{$self->{mirrors}}) {
          s!^/!file:///!;
          s!/$!!;
      }
  }

  sub self_upgrade {
      my $self = shift;
      $self->{argv} = [ 'App::cpanminus' ];
      return; # continue
  }

  sub install_module {
      my($self, $module, $depth, $version) = @_;

      if ($self->{seen}{$module}++) {
          $self->chat("Already tried $module. Skipping.\n");
          return 1;
      }

      my $dist = $self->resolve_name($module, $version);
      unless ($dist) {
          $self->diag_fail("Couldn't find module or a distribution $module ($version)", 1);
          return;
      }

      if ($dist->{distvname} && $self->{seen}{$dist->{distvname}}++) {
          $self->chat("Already tried $dist->{distvname}. Skipping.\n");
          return 1;
      }

      if ($self->{cmd} eq 'info') {
          print $self->format_dist($dist), "\n";
          return 1;
      }

      $self->check_libs;
      $self->setup_module_build_patch unless $self->{pod2man};

      if ($dist->{module}) {
          my($ok, $local) = $self->check_module($dist->{module}, $dist->{module_version} || 0);
          if ($self->{skip_installed} && $ok) {
              $self->diag("$dist->{module} is up to date. ($local)\n", 1);
              return 1;
          }
      }

      if ($dist->{dist} eq 'perl'){
          $self->diag("skipping $dist->{pathname}\n");
          return 1;
      }

      $self->diag("--> Working on $module\n");

      $dist->{dir} ||= $self->fetch_module($dist);

      unless ($dist->{dir}) {
          $self->diag_fail("Failed to fetch distribution $dist->{distvname}", 1);
          return;
      }

      $self->chat("Entering $dist->{dir}\n");
      $self->chdir($self->{base});
      $self->chdir($dist->{dir});

      if ($self->{cmd} eq 'look') {
          $self->look;
          return 1;
      }

      return $self->build_stuff($module, $dist, $depth);
  }

  sub format_dist {
      my($self, $dist) = @_;

      # TODO support --dist-format?
      return "$dist->{cpanid}/$dist->{filename}";
  }

  sub fetch_module {
      my($self, $dist) = @_;

      $self->chdir($self->{base});

      for my $uri (@{$dist->{uris}}) {
          $self->diag_progress("Fetching $uri");

          # Ugh, $dist->{filename} can contain sub directory
          my $filename = $dist->{filename} || $uri;
          my $name = File::Basename::basename($filename);

          my $cancelled;
          my $fetch = sub {
              my $file;
              eval {
                  local $SIG{INT} = sub { $cancelled = 1; die "SIGINT\n" };
                  $self->mirror($uri, $name);
                  $file = $name if -e $name;
              };
              $self->chat("$@") if $@ && $@ ne "SIGINT\n";
              return $file;
          };

          my($try, $file);
          while ($try++ < 3) {
              $file = $fetch->();
              last if $cancelled or $file;
              $self->diag_fail("Download $uri failed. Retrying ... ");
          }

          if ($cancelled) {
              $self->diag_fail("Download cancelled.");
              return;
          }

          unless ($file) {
              $self->diag_fail("Failed to download $uri");
              next;
          }

          $self->diag_ok;
          $dist->{local_path} = File::Spec->rel2abs($name);

          my $dir = $self->unpack($file);
          next unless $dir; # unpack failed

          if (my $save = $self->{save_dists}) {
              my $path = "$save/authors/id/$dist->{pathname}";
              $self->chat("Copying $name to $path\n");
              File::Path::mkpath([ File::Basename::dirname($path) ], 0, 0777);
              File::Copy::copy($file, $path) or warn $!;
          }

          return $dist, $dir;
      }
  }

  sub unpack {
      my($self, $file) = @_;
      $self->chat("Unpacking $file\n");
      my $dir = $file =~ /\.zip/i ? $self->unzip($file) : $self->untar($file);
      unless ($dir) {
          $self->diag_fail("Failed to unpack $file: no directory");
      }
      return $dir;
  }

  sub resolve_name {
      my($self, $module, $version) = @_;

      # URL
      if ($module =~ /^(ftp|https?|file):/) {
          if ($module =~ m!authors/id/!) {
              return $self->cpan_dist($module, $module);
          } else {
              return { uris => [ $module ] };
          }
      }

      # Directory
      if ($module =~ m!^[\./]! && -d $module) {
          return {
              source => 'local',
              dir => Cwd::abs_path($module),
          };
      }

      # File
      if (-f $module) {
          return {
              source => 'local',
              uris => [ "file://" . Cwd::abs_path($module) ],
          };
      }

      # cpan URI
      if ($module =~ s!^cpan:///distfile/!!) {
          return $self->cpan_dist($module);
      }

      # PAUSEID/foo
      if ($module =~ m!([A-Z]{3,})/!) {
          return $self->cpan_dist($module);
      }

      # Module name
      return $self->search_module($module, $version);
  }

  sub cpan_module {
      my($self, $module, $dist, $version) = @_;

      my $dist = $self->cpan_dist($dist);
      $dist->{module} = $module;
      $dist->{module_version} = $version if $version && $version ne 'undef';

      return $dist;
  }

  sub cpan_dist {
      my($self, $dist, $url) = @_;

      $dist =~ s!^([A-Z]{3})!substr($1,0,1)."/".substr($1,0,2)."/".$1!e;

      require CPAN::DistnameInfo;
      my $d = CPAN::DistnameInfo->new($dist);

      if ($url) {
          $url = [ $url ] unless ref $url eq 'ARRAY';
      } else {
          my $id = $d->cpanid;
          my $fn = substr($id, 0, 1) . "/" . substr($id, 0, 2) . "/" . $id . "/" . $d->filename;

          my @mirrors = @{$self->{mirrors}};
          my @urls    = map "$_/authors/id/$fn", @mirrors;

          $url = \@urls,
      }

      return {
          $d->properties,
          source  => 'cpan',
          uris    => $url,
      };
  }

  sub setup_module_build_patch {
      my $self = shift;

      open my $out, ">$self->{base}/ModuleBuildSkipMan.pm" or die $!;
      print $out <<EOF;
  package ModuleBuildSkipMan;
  CHECK {
    if (%Module::Build::) {
      no warnings 'redefine';
      *Module::Build::Base::ACTION_manpages = sub {};
      *Module::Build::Base::ACTION_docs     = sub {};
    }
  }
  1;
  EOF
  }

  sub check_module {
      my($self, $mod, $want_ver) = @_;

      require Module::Metadata;
      my $meta = Module::Metadata->new_from_module($mod, inc => $self->{search_inc})
          or return 0, undef;

      my $version = $meta->version;

      # When -L is in use, the version loaded from 'perl' library path
      # might be newer than (or actually wasn't core at) the version
      # that is shipped with the current perl
      if ($self->{self_contained} && $self->loaded_from_perl_lib($meta)) {
          require Module::CoreList;
          unless (exists $Module::CoreList::version{$]+0}{$mod}) {
              return 0, undef;
          }
          $version = $Module::CoreList::version{$]+0}{$mod};
      }

      $self->{local_versions}{$mod} = $version;

      if ($self->is_deprecated($meta)){
          return 0, $version;
      } elsif (!$want_ver or $version >= version->new($want_ver)) {
          return 1, ($version || 'undef');
      } else {
          return 0, $version;
      }
  }

  sub is_deprecated {
      my($self, $meta) = @_;

      my $deprecated = eval {
          require Module::CoreList;
          Module::CoreList::is_deprecated($meta->{module});
      };

      return unless $deprecated;
      return $self->loaded_from_perl_lib($meta);
  }

  sub loaded_from_perl_lib {
      my($self, $meta) = @_;

      require Config;
      for my $dir (qw(archlibexp privlibexp)) {
          my $confdir = $Config{$dir};
          if ($confdir eq substr($meta->filename, 0, length($confdir))) {
              return 1;
          }
      }

      return;
  }

  sub should_install {
      my($self, $mod, $ver) = @_;

      $self->chat("Checking if you have $mod $ver ... ");
      my($ok, $local) = $self->check_module($mod, $ver);

      if ($ok)       { $self->chat("Yes ($local)\n") }
      elsif ($local) { $self->chat("No ($local < $ver)\n") }
      else           { $self->chat("No\n") }

      return $mod unless $ok;
      return;
  }

  sub install_deps {
      my($self, $dir, $depth, @deps) = @_;

      my(@install, %seen);
      while (my($mod, $ver) = splice @deps, 0, 2) {
          next if $seen{$mod} or $mod eq 'perl' or $mod eq 'Config';
          if ($self->should_install($mod, $ver)) {
              push @install, [ $mod, $ver ];
              $seen{$mod} = 1;
          }
      }

      if (@install) {
          $self->diag("==> Found dependencies: " . join(", ",  map $_->[0], @install) . "\n");
      }

      my @fail;
      for my $mod (@install) {
          $self->install_module($mod->[0], $depth + 1, $mod->[1])
              or push @fail, $mod->[0];
      }

      $self->chdir($self->{base});
      $self->chdir($dir) if $dir;

      return @fail;
  }

  sub install_deps_bailout {
      my($self, $target, $dir, $depth, @deps) = @_;

      my @fail = $self->install_deps($dir, $depth, @deps);
      if (@fail) {
          unless ($self->prompt_bool("Installing the following dependencies failed:\n==> " .
                                     join(", ", @fail) . "\nDo you want to continue building $target anyway?", "n")) {
              $self->diag_fail("Bailing out the installation for $target. Retry with --prompt or --force.", 1);
              return;
          }
      }

      return 1;
  }

  sub build_stuff {
      my($self, $stuff, $dist, $depth) = @_;

      my @config_deps;
      if (!%{$dist->{meta} || {}} && -e 'META.yml') {
          $self->chat("Checking configure dependencies from META.yml\n");
          $dist->{meta} = $self->parse_meta('META.yml');
      }

      if (!$dist->{meta} && $dist->{source} eq 'cpan') {
          $self->chat("META.yml not found or unparsable. Fetching META.yml from search.cpan.org\n");
          $dist->{meta} = $self->fetch_meta_sco($dist);
      }

      $dist->{meta} ||= {};

      push @config_deps, %{$dist->{meta}{configure_requires} || {}};

      my $target = $dist->{meta}{name} ? "$dist->{meta}{name}-$dist->{meta}{version}" : $dist->{dir};

      $self->install_deps_bailout($target, $dist->{dir}, $depth, @config_deps)
          or return;

      $self->diag_progress("Configuring $target");

      my $configure_state = $self->configure_this($dist);

      $self->diag_ok($configure_state->{configured_ok} ? "OK" : "N/A");

      my @deps = $self->find_prereqs($dist);
      my $module_name = $self->find_module_name($configure_state) || $dist->{meta}{name};
      $module_name =~ s/-/::/g;

      if ($self->{showdeps}) {
          my %rootdeps = (@config_deps, @deps); # merge
          for my $mod (keys %rootdeps) {
              my $ver = $rootdeps{$mod};
              print $mod, ($ver ? "~$ver" : ""), "\n";
          }
          return 1;
      }

      my $distname = $dist->{meta}{name} ? "$dist->{meta}{name}-$dist->{meta}{version}" : $stuff;

      my $walkup;
      if ($self->{scandeps}) {
          $walkup = $self->scandeps_append_child($dist);
      }

      $self->install_deps_bailout($distname, $dist->{dir}, $depth, @deps)
          or return;

      if ($self->{scandeps}) {
          unless ($configure_state->{configured_ok}) {
              my $diag = <<DIAG;
  ! Configuring $distname failed. See $self->{log} for details.
  ! You might have to install the following modules first to get --scandeps working correctly.
  DIAG
              if (@config_deps) {
                  my @tree = @{$self->{scandeps_tree}};
                  $diag .= "!\n" . join("", map "! * $_->[0]{module}\n", @tree[0..$#tree-1]) if @tree;
              }
              $self->diag("!\n$diag!\n", 1);
          }
          $walkup->();
          return 1;
      }

      if ($self->{installdeps} && $depth == 0) {
          if ($configure_state->{configured_ok}) {
              $self->diag("<== Installed dependencies for $stuff. Finishing.\n");
              return 1;
          } else {
              $self->diag("! Configuring $distname failed. See $self->{log} for details.\n", 1);
              return;
          }
      }

      my $installed;
      if ($configure_state->{use_module_build} && -e 'Build' && -f _) {
          my @switches = $self->{pod2man} ? () : ("-I$self->{base}", "-MModuleBuildSkipMan");
          $self->diag_progress("Building " . ($self->{notest} ? "" : "and testing ") . $distname);
          $self->build([ $self->{perl}, @switches, "./Build" ], $distname) &&
          $self->test([ $self->{perl}, "./Build", "test" ], $distname) &&
          $self->install([ $self->{perl}, @switches, "./Build", "install" ], [ "--uninst", 1 ], $depth) &&
          $installed++;
      } elsif ($self->{make} && -e 'Makefile') {
          $self->diag_progress("Building " . ($self->{notest} ? "" : "and testing ") . $distname);
          $self->build([ $self->{make} ], $distname) &&
          $self->test([ $self->{make}, "test" ], $distname) &&
          $self->install([ $self->{make}, "install" ], [ "UNINST=1" ], $depth) &&
          $installed++;
      } else {
          my $why;
          my $configure_failed = $configure_state->{configured} && !$configure_state->{configured_ok};
          if ($configure_failed) { $why = "Configure failed for $distname." }
          elsif ($self->{make})  { $why = "The distribution doesn't have a proper Makefile.PL/Build.PL" }
          else                   { $why = "Can't configure the distribution. You probably need to have 'make'." }

          $self->diag_fail("$why See $self->{log} for details.", 1);
          return;
      }

      if ($installed && $self->{test_only}) {
          $self->diag_ok;
          $self->diag("Successfully tested $distname\n", 1);
      } elsif ($installed) {
          my $local   = $self->{local_versions}{$dist->{module} || ''};
          my $version = $dist->{module_version} || $dist->{meta}{version} || $dist->{version};
          my $reinstall = $local && ($local eq $version);

          my $how = $reinstall ? "reinstalled $distname"
                  : $local     ? "installed $distname (upgraded from $local)"
                               : "installed $distname" ;
          my $msg = "Successfully $how";
          $self->diag_ok;
          $self->diag("$msg\n", 1);
          $self->{installed_dists}++;
          $self->save_meta($stuff, $dist, $module_name, \@config_deps, \@deps);
          return 1;
      } else {
          my $what = $self->{test_only} ? "Testing" : "Installing";
          $self->diag_fail("$what $stuff failed. See $self->{log} for details.", 1);
          return;
      }
  }

  sub configure_this {
      my($self, $dist) = @_;

      if (-e 'cpanfile' && $self->{installdeps}) {
          require Module::CPANfile;
          $dist->{cpanfile} = eval { Module::CPANfile->load('cpanfile') };
          return {
              configured       => 1,
              configured_ok    => !!$dist->{cpanfile},
              use_module_build => 0,
          };
      }

      if ($self->{skip_configure}) {
          my $eumm = -e 'Makefile';
          my $mb   = -e 'Build' && -f _;
          return {
              configured => 1,
              configured_ok => $eumm || $mb,
              use_module_build => $mb,
          };
      }

      my @mb_switches;
      unless ($self->{pod2man}) {
          # it has to be push, so Module::Build is loaded from the adjusted path when -L is in use
          push @mb_switches, ("-I$self->{base}", "-MModuleBuildSkipMan");
      }

      my $state = {};

      my $try_eumm = sub {
          if (-e 'Makefile.PL') {
              $self->chat("Running Makefile.PL\n");

              # NOTE: according to Devel::CheckLib, most XS modules exit
              # with 0 even if header files are missing, to avoid receiving
              # tons of FAIL reports in such cases. So exit code can't be
              # trusted if it went well.
              if ($self->configure([ $self->{perl}, "Makefile.PL" ])) {
                  $state->{configured_ok} = -e 'Makefile';
              }
              $state->{configured}++;
          }
      };

      my $try_mb = sub {
          if (-e 'Build.PL') {
              $self->chat("Running Build.PL\n");
              if ($self->configure([ $self->{perl}, @mb_switches, "Build.PL" ])) {
                  $state->{configured_ok} = -e 'Build' && -f _;
              }
              $state->{use_module_build}++;
              $state->{configured}++;
          }
      };

      # Module::Build deps should use MakeMaker because that causes circular deps and fail
      # Otherwise we should prefer Build.PL
      my %should_use_mm = map { $_ => 1 } qw( version ExtUtils-ParseXS ExtUtils-Install ExtUtils-Manifest );

      my @try;
      if ($dist->{dist} && $should_use_mm{$dist->{dist}}) {
          @try = ($try_eumm, $try_mb);
      } else {
          @try = ($try_mb, $try_eumm);
      }

      for my $try (@try) {
          $try->();
          last if $state->{configured_ok};
      }

      unless ($state->{configured_ok}) {
          while (1) {
              my $ans = lc $self->prompt("Configuring $dist->{dist} failed.\nYou can s)kip, r)etry, e)xamine build log, or l)ook ?", "s");
              last                                if $ans eq 's';
              return $self->configure_this($dist) if $ans eq 'r';
              $self->show_build_log               if $ans eq 'e';
              $self->look                         if $ans eq 'l';
          }
      }

      return $state;
  }

  sub find_module_name {
      my($self, $state) = @_;

      return unless $state->{configured_ok};

      if ($state->{use_module_build} &&
          -e "_build/build_params") {
          my $params = do { open my $in, "_build/build_params"; $self->safe_eval(join "", <$in>) };
          return eval { $params->[2]{module_name} } || undef;
      } elsif (-e "Makefile") {
          open my $mf, "Makefile";
          while (<$mf>) {
              if (/^\#\s+NAME\s+=>\s+(.*)/) {
                  return $self->safe_eval($1);
              }
          }
      }

      return;
  }

  sub save_meta {
      my($self, $module, $dist, $module_name, $config_deps, $build_deps) = @_;

      return unless $dist->{distvname} && $dist->{source} eq 'cpan';

      my $base = ($ENV{PERL_MM_OPT} || '') =~ /INSTALL_BASE=/
          ? ($self->install_base($ENV{PERL_MM_OPT}) . "/lib/perl5") : $Config{sitelibexp};

      my $provides = $self->_merge_hashref(
          map Module::Metadata->package_versions_from_directory($_),
              qw( blib/lib blib/arch ) # FCGI.pm :(
      );

      mkdir "blib/meta", 0777 or die $!;

      my $local = {
          name => $module_name,
          target => $module,
          version => $provides->{$module_name}{version} || $dist->{version},
          dist => $dist->{distvname},
          pathname => $dist->{pathname},
          provides => $provides,
      };

      require JSON::PP;
      open my $fh, ">", "blib/meta/install.json" or die $!;
      print $fh JSON::PP::encode_json($local);

      # Existence of MYMETA.* Depends on EUMM/M::B versions and CPAN::Meta
      if (-e "MYMETA.json") {
          File::Copy::copy("MYMETA.json", "blib/meta/MYMETA.json");
      }

      my @cmd = (
          ($self->{sudo} ? 'sudo' : ()),
          $^X,
          '-MExtUtils::Install=install',
          '-e',
          qq[install({ 'blib/meta' => '$base/$Config{archname}/.meta/$dist->{distvname}' })],
      );
      $self->run(\@cmd);
  }

  sub _merge_hashref {
      my($self, @hashrefs) = @_;

      my %hash;
      for my $h (@hashrefs) {
          %hash = (%hash, %$h);
      }

      return \%hash;
  }

  sub install_base {
      my($self, $mm_opt) = @_;
      $mm_opt =~ /INSTALL_BASE=(\S+)/ and return $1;
      die "Your PERL_MM_OPT doesn't contain INSTALL_BASE";
  }

  sub safe_eval {
      my($self, $code) = @_;
      eval $code;
  }

  sub find_prereqs {
      my($self, $dist) = @_;

      my @deps = $self->extract_meta_prereqs($dist);

      if ($dist->{module} =~ /^Bundle::/i) {
          push @deps, $self->bundle_deps($dist);
      }

      return @deps;
  }

  sub extract_meta_prereqs {
      my($self, $dist) = @_;

      if ($dist->{cpanfile}) {
          my $prereq = $dist->{cpanfile}->prereq;
          my @phase = $self->{notest} ? qw( build runtime ) : qw( build test runtime );
          require CPAN::Meta::Requirements;
          my $req = CPAN::Meta::Requirements->new;
          $req->add_requirements($prereq->requirements_for($_, 'requires')) for @phase;
          return %{$req->as_string_hash};
      }

      my $meta = $dist->{meta};

      my @deps;
      if (-e "MYMETA.json") {
          require JSON::PP;
          $self->chat("Checking dependencies from MYMETA.json ...\n");
          my $json = do { open my $in, "<MYMETA.json"; local $/; <$in> };
          my $mymeta = JSON::PP::decode_json($json);
          if ($mymeta) {
              $meta->{$_} = $mymeta->{$_} for qw(name version);
              return $self->extract_requires($mymeta);
          }
      }

      if (-e 'MYMETA.yml') {
          $self->chat("Checking dependencies from MYMETA.yml ...\n");
          my $mymeta = $self->parse_meta('MYMETA.yml');
          if ($mymeta) {
              $meta->{$_} = $mymeta->{$_} for qw(name version);
              return $self->extract_requires($mymeta);
          }
      }

      if (-e '_build/prereqs') {
          $self->chat("Checking dependencies from _build/prereqs ...\n");
          my $mymeta = do { open my $in, "_build/prereqs"; $self->safe_eval(join "", <$in>) };
          @deps = $self->extract_requires($mymeta);
      } elsif (-e 'Makefile') {
          $self->chat("Finding PREREQ from Makefile ...\n");
          open my $mf, "Makefile";
          while (<$mf>) {
              if (/^\#\s+PREREQ_PM => \{\s*(.*?)\s*\}/) {
                  my @all;
                  my @pairs = split ', ', $1;
                  for (@pairs) {
                      my ($pkg, $v) = split '=>', $_;
                      push @all, [ $pkg, $v ];
                  }
                  my $list = join ", ", map { "'$_->[0]' => $_->[1]" } @all;
                  my $prereq = $self->safe_eval("no strict; +{ $list }");
                  push @deps, %$prereq if $prereq;
                  last;
              }
          }
      }

      return @deps;
  }

  sub bundle_deps {
      my($self, $dist) = @_;

      my @files;
      File::Find::find({
          wanted => sub { push @files, File::Spec->rel2abs($_) if /\.pm/i },
          no_chdir => 1,
      }, '.');

      my @deps;

      for my $file (@files) {
          open my $pod, "<", $file or next;
          my $in_contents;
          while (<$pod>) {
              if (/^=head\d\s+CONTENTS/) {
                  $in_contents = 1;
              } elsif (/^=/) {
                  $in_contents = 0;
              } elsif ($in_contents) {
                  /^(\S+)\s*(\S+)?/
                      and push @deps, $1, $self->maybe_version($2);
              }
          }
      }

      return @deps;
  }

  sub maybe_version {
      my($self, $string) = @_;
      return $string && $string =~ /^\.?\d/ ? $string : undef;
  }

  sub extract_requires {
      my($self, $meta) = @_;

      if ($meta->{'meta-spec'} && $meta->{'meta-spec'}{version} == 2) {
          my @phase = $self->{notest} ? qw( build runtime ) : qw( build test runtime );
          my @deps = map {
              my $p = $meta->{prereqs}{$_} || {};
              %{$p->{requires} || {}};
          } @phase;
          return @deps;
      }

      my @deps;
      push @deps, %{$meta->{build_requires}} if $meta->{build_requires};
      push @deps, %{$meta->{requires}} if $meta->{requires};

      return @deps;
  }

  sub cleanup_workdirs {
      my $self = shift;

      my $expire = time - 24 * 60 * 60 * $self->{auto_cleanup};
      my @targets;

      opendir my $dh, "$self->{home}/work";
      while (my $e = readdir $dh) {
          next if $e !~ /^(\d+)\.\d+$/; # {UNIX time}.{PID}
          my $time = $1;
          if ($time < $expire) {
              push @targets, "$self->{home}/work/$e";
          }
      }

      if (@targets) {
          $self->chat("Expiring ", scalar(@targets), " work directories.\n");
          File::Path::rmtree(\@targets, 0, 0); # safe = 0, since blib usually doesn't have write bits
      }
  }

  sub scandeps_append_child {
      my($self, $dist) = @_;

      my $new_node = [ $dist, [] ];

      my $curr_node = $self->{scandeps_current} || [ undef, $self->{scandeps_tree} ];
      push @{$curr_node->[1]}, $new_node;

      $self->{scandeps_current} = $new_node;

      return sub { $self->{scandeps_current} = $curr_node };
  }

  sub dump_scandeps {
      my $self = shift;

      if ($self->{format} eq 'tree') {
          $self->walk_down(sub {
              my($dist, $depth) = @_;
              if ($depth == 0) {
                  print "$dist->{distvname}\n";
              } else {
                  print " " x ($depth - 1);
                  print "\\_ $dist->{distvname}\n";
              }
          }, 1);
      } elsif ($self->{format} =~ /^dists?$/) {
          $self->walk_down(sub {
              my($dist, $depth) = @_;
              print $self->format_dist($dist), "\n";
          }, 0);
      } elsif ($self->{format} eq 'json') {
          require JSON::PP;
          print JSON::PP::encode_json($self->{scandeps_tree});
      } elsif ($self->{format} eq 'yaml') {
          require YAML;
          print YAML::Dump($self->{scandeps_tree});
      } else {
          $self->diag("Unknown format: $self->{format}\n");
      }
  }

  sub walk_down {
      my($self, $cb, $pre) = @_;
      $self->_do_walk_down($self->{scandeps_tree}, $cb, 0, $pre);
  }

  sub _do_walk_down {
      my($self, $children, $cb, $depth, $pre) = @_;

      # DFS - $pre determines when we call the callback
      for my $node (@$children) {
          $cb->($node->[0], $depth) if $pre;
          $self->_do_walk_down($node->[1], $cb, $depth + 1, $pre);
          $cb->($node->[0], $depth) unless $pre;
      }
  }

  sub DESTROY {
      my $self = shift;
      $self->{at_exit}->($self) if $self->{at_exit};
  }

  # Utils

  sub shell_quote {
      my($self, $stuff) = @_;
      $stuff =~ /^${quote}.+${quote}$/ ? $stuff : ($quote . $stuff . $quote);
  }

  sub which {
      my($self, $name) = @_;
      my $exe_ext = $Config{_exe};
      for my $dir (File::Spec->path) {
          my $fullpath = File::Spec->catfile($dir, $name);
          if (-x $fullpath || -x ($fullpath .= $exe_ext)) {
              if ($fullpath =~ /\s/ && $fullpath !~ /^$quote/) {
                  $fullpath = $self->shell_quote($fullpath);
              }
              return $fullpath;
          }
      }
      return;
  }

  sub get      { $_[0]->{_backends}{get}->(@_) };
  sub mirror   { $_[0]->{_backends}{mirror}->(@_) };
  sub untar    { $_[0]->{_backends}{untar}->(@_) };
  sub unzip    { $_[0]->{_backends}{unzip}->(@_) };

  sub file_get {
      my($self, $uri) = @_;
      open my $fh, "<$uri" or return;
      join '', <$fh>;
  }

  sub file_mirror {
      my($self, $uri, $path) = @_;
      File::Copy::copy($uri, $path);
  }

  sub init_tools {
      my $self = shift;

      return if $self->{initialized}++;

      if ($self->{make} = $self->which($Config{make})) {
          $self->chat("You have make $self->{make}\n");
      }

      # use --no-lwp if they have a broken LWP, to upgrade LWP
      if ($self->{try_lwp} && eval { require LWP::UserAgent; LWP::UserAgent->VERSION(5.802) }) {
          $self->chat("You have LWP $LWP::VERSION\n");
          my $ua = sub {
              LWP::UserAgent->new(
                  parse_head => 0,
                  env_proxy => 1,
                  agent => "cpanminus/$VERSION",
                  timeout => 30,
                  @_,
              );
          };
          $self->{_backends}{get} = sub {
              my $self = shift;
              my $res = $ua->()->request(HTTP::Request->new(GET => $_[0]));
              return unless $res->is_success;
              return $res->decoded_content;
          };
          $self->{_backends}{mirror} = sub {
              my $self = shift;
              my $res = $ua->()->mirror(@_);
              $res->code;
          };
      } elsif ($self->{try_wget} and my $wget = $self->which('wget')) {
          $self->chat("You have $wget\n");
          $self->{_backends}{get} = sub {
              my($self, $uri) = @_;
              return $self->file_get($uri) if $uri =~ s!^file:/+!/!;
              $self->safeexec( my $fh, $wget, $uri, ( $self->{verbose} ? () : '-q' ), '-O', '-' ) or die "wget $uri: $!";
              local $/;
              <$fh>;
          };
          $self->{_backends}{mirror} = sub {
              my($self, $uri, $path) = @_;
              return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;
              $self->safeexec( my $fh, $wget, '--retry-connrefused', $uri, ( $self->{verbose} ? () : '-q' ), '-O', $path ) or die "wget $uri: $!";
              local $/;
              <$fh>;
          };
      } elsif ($self->{try_curl} and my $curl = $self->which('curl')) {
          $self->chat("You have $curl\n");
          $self->{_backends}{get} = sub {
              my($self, $uri) = @_;
              return $self->file_get($uri) if $uri =~ s!^file:/+!/!;
              $self->safeexec( my $fh, $curl, '-L', ( $self->{verbose} ? () : '-s' ), $uri ) or die "curl $uri: $!";
              local $/;
              <$fh>;
          };
          $self->{_backends}{mirror} = sub {
              my($self, $uri, $path) = @_;
              return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;
              $self->safeexec( my $fh, $curl, '-L', $uri, ( $self->{verbose} ? () : '-s' ), '-#', '-o', $path ) or die "curl $uri: $!";
              local $/;
              <$fh>;
          };
      } else {
          require HTTP::Tiny;
          $self->chat("Falling back to HTTP::Tiny $HTTP::Tiny::VERSION\n");

          $self->{_backends}{get} = sub {
              my $self = shift;
              my $res = HTTP::Tiny->new->get($_[0]);
              return unless $res->{success};
              return $res->{content};
          };
          $self->{_backends}{mirror} = sub {
              my $self = shift;
              my $res = HTTP::Tiny->new->mirror(@_);
              return $res->{status};
          };
      }

      my $tar = $self->which('tar');
      my $tar_ver;
      my $maybe_bad_tar = sub { WIN32 || SUNOS || (($tar_ver = `$tar --version 2>/dev/null`) =~ /GNU.*1\.13/i) };

      if ($tar && !$maybe_bad_tar->()) {
          chomp $tar_ver;
          $self->chat("You have $tar: $tar_ver\n");
          $self->{_backends}{untar} = sub {
              my($self, $tarfile) = @_;

              my $xf = ($self->{verbose} ? 'v' : '')."xf";
              my $ar = $tarfile =~ /bz2$/ ? 'j' : 'z';

              my($root, @others) = `$tar ${ar}tf $tarfile`
                  or return undef;

              FILE: {
                  chomp $root;
                  $root =~ s!^\./!!;
                  $root =~ s{^(.+?)/.*$}{$1};

                  if (!length($root)) {
                      # archive had ./ as the first entry, so try again
                      $root = shift(@others);
                      redo FILE if $root;
                  }
              }

              system "$tar $ar$xf $tarfile";
              return $root if -d $root;

              $self->diag_fail("Bad archive: $tarfile");
              return undef;
          }
      } elsif (    $tar
               and my $gzip = $self->which('gzip')
               and my $bzip2 = $self->which('bzip2')) {
          $self->chat("You have $tar, $gzip and $bzip2\n");
          $self->{_backends}{untar} = sub {
              my($self, $tarfile) = @_;

              my $x  = "x" . ($self->{verbose} ? 'v' : '') . "f -";
              my $ar = $tarfile =~ /bz2$/ ? $bzip2 : $gzip;

              my($root, @others) = `$ar -dc $tarfile | $tar tf -`
                  or return undef;

              FILE: {
                  chomp $root;
                  $root =~ s!^\./!!;
                  $root =~ s{^(.+?)/.*$}{$1};

                  if (!length($root)) {
                      # archive had ./ as the first entry, so try again
                      $root = shift(@others);
                      redo FILE if $root;
                  }
              }

              system "$ar -dc $tarfile | $tar $x";
              return $root if -d $root;

              $self->diag_fail("Bad archive: $tarfile");
              return undef;
          }
      } elsif (eval { require Archive::Tar }) { # uses too much memory!
          $self->chat("Falling back to Archive::Tar $Archive::Tar::VERSION\n");
          $self->{_backends}{untar} = sub {
              my $self = shift;
              my $t = Archive::Tar->new($_[0]);
              my($root, @others) = $t->list_files;
              FILE: {
                  $root =~ s!^\./!!;
                  $root =~ s{^(.+?)/.*$}{$1};

                  if (!length($root)) {
                      # archive had ./ as the first entry, so try again
                      $root = shift(@others);
                      redo FILE if $root;
                  }
              }
              $t->extract;
              return -d $root ? $root : undef;
          };
      } else {
          $self->{_backends}{untar} = sub {
              die "Failed to extract $_[1] - You need to have tar or Archive::Tar installed.\n";
          };
      }

      if (my $unzip = $self->which('unzip')) {
          $self->chat("You have $unzip\n");
          $self->{_backends}{unzip} = sub {
              my($self, $zipfile) = @_;

              my $opt = $self->{verbose} ? '' : '-q';
              my(undef, $root, @others) = `$unzip -t $zipfile`
                  or return undef;

              chomp $root;
              $root =~ s{^\s+testing:\s+(.+?)/\s+OK$}{$1};

              system "$unzip $opt $zipfile";
              return $root if -d $root;

              $self->diag_fail("Bad archive: [$root] $zipfile");
              return undef;
          }
      } else {
          $self->{_backends}{unzip} = sub {
              eval { require Archive::Zip }
                  or  die "Failed to extract $_[1] - You need to have unzip or Archive::Zip installed.\n";
              my($self, $file) = @_;
              my $zip = Archive::Zip->new();
              my $status;
              $status = $zip->read($file);
              $self->diag_fail("Read of file[$file] failed")
                  if $status != Archive::Zip::AZ_OK();
              my @members = $zip->members();
              my $root;
              for my $member ( @members ) {
                  my $af = $member->fileName();
                  next if ($af =~ m!^(/|\.\./)!);
                  $root = $af unless $root;
                  $status = $member->extractToFileNamed( $af );
                  $self->diag_fail("Extracting of file[$af] from zipfile[$file failed")
                      if $status != Archive::Zip::AZ_OK();
              }
              return -d $root ? $root : undef;
          };
      }
  }

  sub safeexec {
      my $self = shift;
      my $rdr = $_[0] ||= Symbol::gensym();

      if (WIN32) {
          my $cmd = join q{ }, map { $self->shell_quote($_) } @_[ 1 .. $#_ ];
          return open( $rdr, "$cmd |" );
      }

      if ( my $pid = open( $rdr, '-|' ) ) {
          return $pid;
      }
      elsif ( defined $pid ) {
          exec( @_[ 1 .. $#_ ] );
          exit 1;
      }
      else {
          return;
      }
  }

  sub parse_meta {
      my($self, $file) = @_;
      return eval { (Parse::CPAN::Meta::LoadFile($file))[0] } || undef;
  }

  sub parse_meta_string {
      my($self, $yaml) = @_;
      return eval { (Parse::CPAN::Meta::Load($yaml))[0] } || undef;
  }

  1;
APP_CPANMINUS_SCRIPT

$fatpacked{"CPAN/DistnameInfo.pm"} = <<'CPAN_DISTNAMEINFO';

  package CPAN::DistnameInfo;

  $VERSION = "0.11";
  use strict;

  sub distname_info {
    my $file = shift or return;

    my ($dist, $version) = $file =~ /^
      ((?:[-+.]*(?:[A-Za-z0-9]+|(?<=\D)_|_(?=\D))*
       (?:
    [A-Za-z](?=[^A-Za-z]|$)
    |
    \d(?=-)
       )(?<![._-][vV])
      )+)(.*)
    $/xs or return ($file,undef,undef);

    if ($dist =~ /-undef\z/ and ! length $version) {
      $dist =~ s/-undef\z//;
    }

    # Remove potential -withoutworldwriteables suffix
    $version =~ s/-withoutworldwriteables$//;

    if ($version =~ /^(-[Vv].*)-(\d.*)/) {

      # Catch names like Unicode-Collate-Standard-V3_1_1-0.1
      # where the V3_1_1 is part of the distname
      $dist .= $1;
      $version = $2;
    }

    # Normalize the Dist.pm-1.23 convention which CGI.pm and
    # a few others use.
    $dist =~ s{\.pm$}{};

    $version = $1
      if !length $version and $dist =~ s/-(\d+\w)$//;

    $version = $1 . $version
      if $version =~ /^\d+$/ and $dist =~ s/-(\w+)$//;

    if ($version =~ /\d\.\d/) {
      $version =~ s/^[-_.]+//;
    }
    else {
      $version =~ s/^[-_]+//;
    }

    my $dev;
    if (length $version) {
      if ($file =~ /^perl-?\d+\.(\d+)(?:\D(\d+))?(-(?:TRIAL|RC)\d+)?$/) {
        $dev = 1 if (($1 > 6 and $1 & 1) or ($2 and $2 >= 50)) or $3;
      }
      elsif ($version =~ /\d\D\d+_\d/ or $version =~ /-TRIAL/) {
        $dev = 1;
      }
    }
    else {
      $version = undef;
    }

    ($dist, $version, $dev);
  }

  sub new {
    my $class = shift;
    my $distfile = shift;

    $distfile =~ s,//+,/,g;

    my %info = ( pathname => $distfile );

    ($info{filename} = $distfile) =~ s,^(((.*?/)?authors/)?id/)?([A-Z])/(\4[A-Z])/(\5[-A-Z0-9]*)/,,
      and $info{cpanid} = $6;

    if ($distfile =~ m,([^/]+)\.(tar\.(?:g?z|bz2)|zip|tgz)$,i) { # support more ?
      $info{distvname} = $1;
      $info{extension} = $2;
    }

    @info{qw(dist version beta)} = distname_info($info{distvname});
    $info{maturity} = delete $info{beta} ? 'developer' : 'released';

    return bless \%info, $class;
  }

  sub dist      { shift->{dist} }
  sub version   { shift->{version} }
  sub maturity  { shift->{maturity} }
  sub filename  { shift->{filename} }
  sub cpanid    { shift->{cpanid} }
  sub distvname { shift->{distvname} }
  sub extension { shift->{extension} }
  sub pathname  { shift->{pathname} }

  sub properties { %{ $_[0] } }

  1;

  __END__

CPAN_DISTNAMEINFO

$fatpacked{"CPAN/Meta.pm"} = <<'CPAN_META';
  use 5.006;
  use strict;
  use warnings;
  package CPAN::Meta;
  BEGIN {
    $CPAN::Meta::VERSION = '2.110930';
  }
  # ABSTRACT: the distribution metadata for a CPAN dist


  use Carp qw(carp croak);
  use CPAN::Meta::Feature;
  use CPAN::Meta::Prereqs;
  use CPAN::Meta::Converter;
  use CPAN::Meta::Validator;
  use Parse::CPAN::Meta 1.4400 ();

  sub _dclone {
    my $ref = shift;
    my $backend = Parse::CPAN::Meta->json_backend();
    return $backend->new->decode(
      $backend->new->convert_blessed->encode($ref)
    );
  }


  BEGIN {
    my @STRING_READERS = qw(
      abstract
      description
      dynamic_config
      generated_by
      name
      release_status
      version
    );

    no strict 'refs';
    for my $attr (@STRING_READERS) {
      *$attr = sub { $_[0]{ $attr } };
    }
  }


  BEGIN {
    my @LIST_READERS = qw(
      author
      keywords
      license
    );

    no strict 'refs';
    for my $attr (@LIST_READERS) {
      *$attr = sub {
        my $value = $_[0]{ $attr };
        croak "$attr must be called in list context"
          unless wantarray;
        return @{ _dclone($value) } if ref $value;
        return $value;
      };
    }
  }

  sub authors  { $_[0]->author }
  sub licenses { $_[0]->license }


  BEGIN {
    my @MAP_READERS = qw(
      meta-spec
      resources
      provides
      no_index

      prereqs
      optional_features
    );

    no strict 'refs';
    for my $attr (@MAP_READERS) {
      (my $subname = $attr) =~ s/-/_/;
      *$subname = sub {
        my $value = $_[0]{ $attr };
        return _dclone($value) if $value;
        return {};
      };
    }
  }


  sub custom_keys {
    return grep { /^x_/i } keys %{$_[0]};
  }

  sub custom {
    my ($self, $attr) = @_;
    my $value = $self->{$attr};
    return _dclone($value) if ref $value;
    return $value;
  }


  sub _new {
    my ($class, $struct, $options) = @_;
    my $self;

    if ( $options->{lazy_validation} ) {
      # try to convert to a valid structure; if succeeds, then return it
      my $cmc = CPAN::Meta::Converter->new( $struct );
      $self = $cmc->convert( version => 2 ); # valid or dies
      return bless $self, $class;
    }
    else {
      # validate original struct
      my $cmv = CPAN::Meta::Validator->new( $struct );
      unless ( $cmv->is_valid) {
        die "Invalid metadata structure. Errors: "
          . join(", ", $cmv->errors) . "\n";
      }
    }

    # up-convert older spec versions
    my $version = $struct->{'meta-spec'}{version} || '1.0';
    if ( $version == 2 ) {
      $self = $struct;
    }
    else {
      my $cmc = CPAN::Meta::Converter->new( $struct );
      $self = $cmc->convert( version => 2 );
    }

    return bless $self, $class;
  }

  sub new {
    my ($class, $struct, $options) = @_;
    my $self = eval { $class->_new($struct, $options) };
    croak($@) if $@;
    return $self;
  }


  sub create {
    my ($class, $struct, $options) = @_;
    my $version = __PACKAGE__->VERSION || 2;
    $struct->{generated_by} ||= __PACKAGE__ . " version $version" ;
    $struct->{'meta-spec'}{version} ||= int($version);
    my $self = eval { $class->_new($struct, $options) };
    croak ($@) if $@;
    return $self;
  }


  sub load_file {
    my ($class, $file, $options) = @_;
    $options->{lazy_validation} = 1 unless exists $options->{lazy_validation};

    croak "load_file() requires a valid, readable filename"
      unless -r $file;

    my $self;
    eval {
      my $struct = Parse::CPAN::Meta->load_file( $file );
      $self = $class->_new($struct, $options);
    };
    croak($@) if $@;
    return $self;
  }


  sub load_yaml_string {
    my ($class, $yaml, $options) = @_;
    $options->{lazy_validation} = 1 unless exists $options->{lazy_validation};

    my $self;
    eval {
      my ($struct) = Parse::CPAN::Meta->load_yaml_string( $yaml );
      $self = $class->_new($struct, $options);
    };
    croak($@) if $@;
    return $self;
  }


  sub load_json_string {
    my ($class, $json, $options) = @_;
    $options->{lazy_validation} = 1 unless exists $options->{lazy_validation};

    my $self;
    eval {
      my $struct = Parse::CPAN::Meta->load_json_string( $json );
      $self = $class->_new($struct, $options);
    };
    croak($@) if $@;
    return $self;
  }


  sub save {
    my ($self, $file, $options) = @_;

    my $version = $options->{version} || '2';
    my $layer = $] ge '5.008001' ? ':utf8' : '';

    if ( $version ge '2' ) {
      carp "'$file' should end in '.json'"
        unless $file =~ m{\.json$};
    }
    else {
      carp "'$file' should end in '.yml'"
        unless $file =~ m{\.yml$};
    }

    my $data = $self->as_string( $options );
    open my $fh, ">$layer", $file
      or die "Error opening '$file' for writing: $!\n";

    print {$fh} $data;
    close $fh
      or die "Error closing '$file': $!\n";

    return 1;
  }


  sub meta_spec_version {
    my ($self) = @_;
    return $self->meta_spec->{version};
  }


  sub effective_prereqs {
    my ($self, $features) = @_;
    $features ||= [];

    my $prereq = CPAN::Meta::Prereqs->new($self->prereqs);

    return $prereq unless @$features;

    my @other = map {; $self->feature($_)->prereqs } @$features;

    return $prereq->with_merged_prereqs(\@other);
  }


  sub should_index_file {
    my ($self, $filename) = @_;

    for my $no_index_file (@{ $self->no_index->{file} || [] }) {
      return if $filename eq $no_index_file;
    }

    for my $no_index_dir (@{ $self->no_index->{directory} }) {
      $no_index_dir =~ s{$}{/} unless $no_index_dir =~ m{/\z};
      return if index($filename, $no_index_dir) == 0;
    }

    return 1;
  }


  sub should_index_package {
    my ($self, $package) = @_;

    for my $no_index_pkg (@{ $self->no_index->{package} || [] }) {
      return if $package eq $no_index_pkg;
    }

    for my $no_index_ns (@{ $self->no_index->{namespace} }) {
      return if index($package, "${no_index_ns}::") == 0;
    }

    return 1;
  }


  sub features {
    my ($self) = @_;

    my $opt_f = $self->optional_features;
    my @features = map {; CPAN::Meta::Feature->new($_ => $opt_f->{ $_ }) }
                   keys %$opt_f;

    return @features;
  }


  sub feature {
    my ($self, $ident) = @_;

    croak "no feature named $ident"
      unless my $f = $self->optional_features->{ $ident };

    return CPAN::Meta::Feature->new($ident, $f);
  }


  sub as_struct {
    my ($self, $options) = @_;
    my $struct = _dclone($self);
    if ( $options->{version} ) {
      my $cmc = CPAN::Meta::Converter->new( $struct );
      $struct = $cmc->convert( version => $options->{version} );
    }
    return $struct;
  }


  sub as_string {
    my ($self, $options) = @_;

    my $version = $options->{version} || '2';

    my $struct;
    if ( $self->meta_spec_version ne $version ) {
      my $cmc = CPAN::Meta::Converter->new( $self->as_struct );
      $struct = $cmc->convert( version => $version );
    }
    else {
      $struct = $self->as_struct;
    }

    my ($data, $backend);
    if ( $version ge '2' ) {
      $backend = Parse::CPAN::Meta->json_backend();
      $data = $backend->new->pretty->canonical->encode($struct);
    }
    else {
      $backend = Parse::CPAN::Meta->yaml_backend();
      $data = eval { no strict 'refs'; &{"$backend\::Dump"}($struct) };
      if ( $@ ) {
        croak $backend->can('errstr') ? $backend->errstr : $@
      }
    }

    return $data;
  }

  # Used by JSON::PP, etc. for "convert_blessed"
  sub TO_JSON {
    return { %{ $_[0] } };
  }

  1;




  __END__


CPAN_META

$fatpacked{"CPAN/Meta/Converter.pm"} = <<'CPAN_META_CONVERTER';
  use 5.006;
  use strict;
  use warnings;
  package CPAN::Meta::Converter;
  BEGIN {
    $CPAN::Meta::Converter::VERSION = '2.110930';
  }
  # ABSTRACT: Convert CPAN distribution metadata structures


  use CPAN::Meta::Validator;
  use version 0.82 ();
  use Parse::CPAN::Meta 1.4400 ();

  sub _dclone {
    my $ref = shift;
    my $backend = Parse::CPAN::Meta->json_backend();
    return $backend->new->decode(
      $backend->new->convert_blessed->encode($ref)
    );
  }

  my %known_specs = (
      '2'   => 'http://search.cpan.org/perldoc?CPAN::Meta::Spec',
      '1.4' => 'http://module-build.sourceforge.net/META-spec-v1.4.html',
      '1.3' => 'http://module-build.sourceforge.net/META-spec-v1.3.html',
      '1.2' => 'http://module-build.sourceforge.net/META-spec-v1.2.html',
      '1.1' => 'http://module-build.sourceforge.net/META-spec-v1.1.html',
      '1.0' => 'http://module-build.sourceforge.net/META-spec-v1.0.html'
  );

  my @spec_list = sort { $a <=> $b } keys %known_specs;
  my ($LOWEST, $HIGHEST) = @spec_list[0,-1];

  #--------------------------------------------------------------------------#
  # converters
  #
  # called as $converter->($element, $field_name, $full_meta, $to_version)
  #
  # defined return value used for field
  # undef return value means field is skipped
  #--------------------------------------------------------------------------#

  sub _keep { $_[0] }

  sub _keep_or_one { defined($_[0]) ? $_[0] : 1 }

  sub _keep_or_zero { defined($_[0]) ? $_[0] : 0 }

  sub _keep_or_unknown { defined($_[0]) && length($_[0]) ? $_[0] : "unknown" }

  sub _generated_by {
    my $gen = shift;
    my $sig = __PACKAGE__ . " version " . (__PACKAGE__->VERSION || "<dev>");

    return $sig unless defined $gen and length $gen;
    return $gen if $gen =~ /(, )\Q$sig/;
    return "$gen, $sig";
  }

  sub _listify { ! defined $_[0] ? undef : ref $_[0] eq 'ARRAY' ? $_[0] : [$_[0]] }

  sub _prefix_custom {
    my $key = shift;
    $key =~ s/^(?!x_)   # Unless it already starts with x_
               (?:x-?)? # Remove leading x- or x (if present)
             /x_/ix;    # and prepend x_
    return $key;
  }

  sub _ucfirst_custom {
    my $key = shift;
    $key = ucfirst $key unless $key =~ /[A-Z]/;
    return $key;
  }

  sub _change_meta_spec {
    my ($element, undef, undef, $version) = @_;
    $element->{version} = $version;
    $element->{url} = $known_specs{$version};
    return $element;
  }

  my @valid_licenses_1 = (
    'perl',
    'gpl',
    'apache',
    'artistic',
    'artistic_2',
    'lgpl',
    'bsd',
    'gpl',
    'mit',
    'mozilla',
    'open_source',
    'unrestricted',
    'restrictive',
    'unknown',
  );

  my %license_map_1 = (
    ( map { $_ => $_ } @valid_licenses_1 ),
    artistic2 => 'artistic_2',
  );

  sub _license_1 {
    my ($element) = @_;
    return 'unknown' unless defined $element;
    if ( $license_map_1{lc $element} ) {
      return $license_map_1{lc $element};
    }
    return 'unknown';
  }

  my @valid_licenses_2 = qw(
    agpl_3
    apache_1_1
    apache_2_0
    artistic_1
    artistic_2
    bsd
    freebsd
    gfdl_1_2
    gfdl_1_3
    gpl_1
    gpl_2
    gpl_3
    lgpl_2_1
    lgpl_3_0
    mit
    mozilla_1_0
    mozilla_1_1
    openssl
    perl_5
    qpl_1_0
    ssleay
    sun
    zlib
    open_source
    restricted
    unrestricted
    unknown
  );

  # The "old" values were defined by Module::Build, and were often vague.  I have
  # made the decisions below based on reading Module::Build::API and how clearly
  # it specifies the version of the license.
  my %license_map_2 = (
    (map { $_ => $_ } @valid_licenses_2),
    apache      => 'apache_2_0',  # clearly stated as 2.0
    artistic    => 'artistic_1',  # clearly stated as 1
    artistic2   => 'artistic_2',  # clearly stated as 2
    gpl         => 'open_source', # we don't know which GPL; punt
    lgpl        => 'open_source', # we don't know which LGPL; punt
    mozilla     => 'open_source', # we don't know which MPL; punt
    perl        => 'perl_5',      # clearly Perl 5
    restrictive => 'restricted',
  );

  sub _license_2 {
    my ($element) = @_;
    return [ 'unknown' ] unless defined $element;
    $element = [ $element ] unless ref $element eq 'ARRAY';
    my @new_list;
    for my $lic ( @$element ) {
      next unless defined $lic;
      if ( my $new = $license_map_2{lc $lic} ) {
        push @new_list, $new;
      }
    }
    return @new_list ? \@new_list : [ 'unknown' ];
  }

  my %license_downgrade_map = qw(
    agpl_3            open_source
    apache_1_1        apache
    apache_2_0        apache
    artistic_1        artistic
    artistic_2        artistic_2
    bsd               bsd
    freebsd           open_source
    gfdl_1_2          open_source
    gfdl_1_3          open_source
    gpl_1             gpl
    gpl_2             gpl
    gpl_3             gpl
    lgpl_2_1          lgpl
    lgpl_3_0          lgpl
    mit               mit
    mozilla_1_0       mozilla
    mozilla_1_1       mozilla
    openssl           open_source
    perl_5            perl
    qpl_1_0           open_source
    ssleay            open_source
    sun               open_source
    zlib              open_source
    open_source       open_source
    restricted        restrictive
    unrestricted      unrestricted
    unknown           unknown
  );

  sub _downgrade_license {
    my ($element) = @_;
    if ( ! defined $element ) {
      return "unknown";
    }
    elsif( ref $element eq 'ARRAY' ) {
      if ( @$element == 1 ) {
        return $license_downgrade_map{$element->[0]} || "unknown";
      }
    }
    elsif ( ! ref $element ) {
      return $license_downgrade_map{$element} || "unknown";
    }
    return "unknown";
  }

  my $no_index_spec_1_2 = {
    'file' => \&_listify,
    'dir' => \&_listify,
    'package' => \&_listify,
    'namespace' => \&_listify,
  };

  my $no_index_spec_1_3 = {
    'file' => \&_listify,
    'directory' => \&_listify,
    'package' => \&_listify,
    'namespace' => \&_listify,
  };

  my $no_index_spec_2 = {
    'file' => \&_listify,
    'directory' => \&_listify,
    'package' => \&_listify,
    'namespace' => \&_listify,
    ':custom'  => \&_prefix_custom,
  };

  sub _no_index_1_2 {
    my (undef, undef, $meta) = @_;
    my $no_index = $meta->{no_index} || $meta->{private};
    return unless $no_index;

    # cleanup wrong format
    if ( ! ref $no_index ) {
      my $item = $no_index;
      $no_index = { dir => [ $item ], file => [ $item ] };
    }
    elsif ( ref $no_index eq 'ARRAY' ) {
      my $list = $no_index;
      $no_index = { dir => [ @$list ], file => [ @$list ] };
    }

    # common mistake: files -> file
    if ( exists $no_index->{files} ) {
      $no_index->{file} = delete $no_index->{file};
    }
    # common mistake: modules -> module
    if ( exists $no_index->{modules} ) {
      $no_index->{module} = delete $no_index->{module};
    }
    return _convert($no_index, $no_index_spec_1_2);
  }

  sub _no_index_directory {
    my ($element, $key, $meta, $version) = @_;
    return unless $element;

    # cleanup wrong format
    if ( ! ref $element ) {
      my $item = $element;
      $element = { directory => [ $item ], file => [ $item ] };
    }
    elsif ( ref $element eq 'ARRAY' ) {
      my $list = $element;
      $element = { directory => [ @$list ], file => [ @$list ] };
    }

    if ( exists $element->{dir} ) {
      $element->{directory} = delete $element->{dir};
    }
    # common mistake: files -> file
    if ( exists $element->{files} ) {
      $element->{file} = delete $element->{file};
    }
    # common mistake: modules -> module
    if ( exists $element->{modules} ) {
      $element->{module} = delete $element->{module};
    }
    my $spec = $version == 2 ? $no_index_spec_2 : $no_index_spec_1_3;
    return _convert($element, $spec);
  }

  sub _is_module_name {
    my $mod = shift;
    return unless defined $mod && length $mod;
    return $mod =~ m{^[A-Za-z][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)*$};
  }

  sub _clean_version {
    my ($element, $key, $meta, $to_version) = @_;
    return 0 if ! defined $element;

    $element =~ s{^\s*}{};
    $element =~ s{\s*$}{};
    $element =~ s{^\.}{0.};

    return 0 if ! length $element;
    return 0 if ( $element eq 'undef' || $element eq '<undef>' );

    if ( my $v = eval { version->new($element) } ) {
      return $v->is_qv ? $v->normal : $element;
    }
    else {
      return 0;
    }
  }

  sub _version_map {
    my ($element) = @_;
    return undef unless defined $element;
    if ( ref $element eq 'HASH' ) {
      my $new_map = {};
      for my $k ( keys %$element ) {
        next unless _is_module_name($k);
        my $value = $element->{$k};
        if ( ! ( defined $value && length $value ) ) {
          $new_map->{$k} = 0;
        }
        elsif ( $value eq 'undef' || $value eq '<undef>' ) {
          $new_map->{$k} = 0;
        }
        elsif ( _is_module_name( $value ) ) { # some weird, old META have this
          $new_map->{$k} = 0;
          $new_map->{$value} = 0;
        }
        else {
          $new_map->{$k} = _clean_version($value);
        }
      }
      return $new_map;
    }
    elsif ( ref $element eq 'ARRAY' ) {
      my $hashref = { map { $_ => 0 } @$element };
      return _version_map($hashref); # cleanup any weird stuff
    }
    elsif ( ref $element eq '' && length $element ) {
      return { $element => 0 }
    }
    return;
  }

  sub _prereqs_from_1 {
    my (undef, undef, $meta) = @_;
    my $prereqs = {};
    for my $phase ( qw/build configure/ ) {
      my $key = "${phase}_requires";
      $prereqs->{$phase}{requires} = _version_map($meta->{$key})
        if $meta->{$key};
    }
    for my $rel ( qw/requires recommends conflicts/ ) {
      $prereqs->{runtime}{$rel} = _version_map($meta->{$rel})
        if $meta->{$rel};
    }
    return $prereqs;
  }

  my $prereqs_spec = {
    configure => \&_prereqs_rel,
    build     => \&_prereqs_rel,
    test      => \&_prereqs_rel,
    runtime   => \&_prereqs_rel,
    develop   => \&_prereqs_rel,
    ':custom'  => \&_prefix_custom,
  };

  my $relation_spec = {
    requires   => \&_version_map,
    recommends => \&_version_map,
    suggests   => \&_version_map,
    conflicts  => \&_version_map,
    ':custom'  => \&_prefix_custom,
  };

  sub _cleanup_prereqs {
    my ($prereqs, $key, $meta, $to_version) = @_;
    return unless $prereqs && ref $prereqs eq 'HASH';
    return _convert( $prereqs, $prereqs_spec, $to_version );
  }

  sub _prereqs_rel {
    my ($relation, $key, $meta, $to_version) = @_;
    return unless $relation && ref $relation eq 'HASH';
    return _convert( $relation, $relation_spec, $to_version );
  }


  BEGIN {
    my @old_prereqs = qw(
      requires
      configure_requires
      recommends
      conflicts
    );

    for ( @old_prereqs ) {
      my $sub = "_get_$_";
      my ($phase,$type) = split qr/_/, $_;
      if ( ! defined $type ) {
        $type = $phase;
        $phase = 'runtime';
      }
      no strict 'refs';
      *{$sub} = sub { _extract_prereqs($_[2]->{prereqs},$phase,$type) };
    }
  }

  sub _get_build_requires {
    my ($data, $key, $meta) = @_;

    my $test_h  = _extract_prereqs($_[2]->{prereqs}, qw(test  requires)) || {};
    my $build_h = _extract_prereqs($_[2]->{prereqs}, qw(build requires)) || {};

    require Version::Requirements;
    my $test_req  = Version::Requirements->from_string_hash($test_h);
    my $build_req = Version::Requirements->from_string_hash($build_h);

    $test_req->add_requirements($build_req)->as_string_hash;
  }

  sub _extract_prereqs {
    my ($prereqs, $phase, $type) = @_;
    return unless ref $prereqs eq 'HASH';
    return $prereqs->{$phase}{$type};
  }

  sub _downgrade_optional_features {
    my (undef, undef, $meta) = @_;
    return undef unless exists $meta->{optional_features};
    my $origin = $meta->{optional_features};
    my $features = {};
    for my $name ( keys %$origin ) {
      $features->{$name} = {
        description => $origin->{$name}{description},
        requires => _extract_prereqs($origin->{$name}{prereqs},'runtime','requires'),
        configure_requires => _extract_prereqs($origin->{$name}{prereqs},'runtime','configure_requires'),
        build_requires => _extract_prereqs($origin->{$name}{prereqs},'runtime','build_requires'),
        recommends => _extract_prereqs($origin->{$name}{prereqs},'runtime','recommends'),
        conflicts => _extract_prereqs($origin->{$name}{prereqs},'runtime','conflicts'),
      };
      for my $k (keys %{$features->{$name}} ) {
        delete $features->{$name}{$k} unless defined $features->{$name}{$k};
      }
    }
    return $features;
  }

  sub _upgrade_optional_features {
    my (undef, undef, $meta) = @_;
    return undef unless exists $meta->{optional_features};
    my $origin = $meta->{optional_features};
    my $features = {};
    for my $name ( keys %$origin ) {
      $features->{$name} = {
        description => $origin->{$name}{description},
        prereqs => _prereqs_from_1(undef, undef, $origin->{$name}),
      };
      delete $features->{$name}{prereqs}{configure};
    }
    return $features;
  }

  my $optional_features_2_spec = {
    description => \&_keep,
    prereqs => \&_cleanup_prereqs,
    ':custom'  => \&_prefix_custom,
  };

  sub _feature_2 {
    my ($element, $key, $meta, $to_version) = @_;
    return unless $element && ref $element eq 'HASH';
    _convert( $element, $optional_features_2_spec, $to_version );
  }

  sub _cleanup_optional_features_2 {
    my ($element, $key, $meta, $to_version) = @_;
    return unless $element && ref $element eq 'HASH';
    my $new_data = {};
    for my $k ( keys %$element ) {
      $new_data->{$k} = _feature_2( $element->{$k}, $k, $meta, $to_version );
    }
    return unless keys %$new_data;
    return $new_data;
  }

  sub _optional_features_1_4 {
    my ($element) = @_;
    return unless $element;
    $element = _optional_features_as_map($element);
    for my $name ( keys %$element ) {
      for my $drop ( qw/requires_packages requires_os excluded_os/ ) {
        delete $element->{$name}{$drop};
      }
    }
    return $element;
  }

  sub _optional_features_as_map {
    my ($element) = @_;
    return unless $element;
    if ( ref $element eq 'ARRAY' ) {
      my %map;
      for my $feature ( @$element ) {
        my (@parts) = %$feature;
        $map{$parts[0]} = $parts[1];
      }
      $element = \%map;
    }
    return $element;
  }

  sub _is_urlish { defined $_[0] && $_[0] =~ m{\A[-+.a-z0-9]+:.+}i }

  sub _url_or_drop {
    my ($element) = @_;
    return $element if _is_urlish($element);
    return;
  }

  sub _url_list {
    my ($element) = @_;
    return unless $element;
    $element = _listify( $element );
    $element = [ grep { _is_urlish($_) } @$element ];
    return unless @$element;
    return $element;
  }

  sub _author_list {
    my ($element) = @_;
    return [ 'unknown' ] unless $element;
    $element = _listify( $element );
    $element = [ map { defined $_ && length $_ ? $_ : 'unknown' } @$element ];
    return [ 'unknown' ] unless @$element;
    return $element;
  }

  my $resource2_upgrade = {
    license    => sub { return _is_urlish($_[0]) ? _listify( $_[0] ) : undef },
    homepage   => \&_url_or_drop,
    bugtracker => sub {
      my ($item) = @_;
      return unless $item;
      if ( $item =~ m{^mailto:(.*)$} ) { return { mailto => $1 } }
      elsif( _is_urlish($item) ) { return { web => $item } }
      else { return undef }
    },
    repository => sub { return _is_urlish($_[0]) ? { url => $_[0] } : undef },
    ':custom'  => \&_prefix_custom,
  };

  sub _upgrade_resources_2 {
    my (undef, undef, $meta, $version) = @_;
    return undef unless exists $meta->{resources};
    return _convert($meta->{resources}, $resource2_upgrade);
  }

  my $bugtracker2_spec = {
    web => \&_url_or_drop,
    mailto => \&_keep,
    ':custom'  => \&_prefix_custom,
  };

  sub _repo_type {
    my ($element, $key, $meta, $to_version) = @_;
    return $element if defined $element;
    return unless exists $meta->{url};
    my $repo_url = $meta->{url};
    for my $type ( qw/git svn/ ) {
      return $type if $repo_url =~ m{\A$type};
    }
    return;
  }

  my $repository2_spec = {
    web => \&_url_or_drop,
    url => \&_url_or_drop,
    type => \&_repo_type,
    ':custom'  => \&_prefix_custom,
  };

  my $resources2_cleanup = {
    license    => \&_url_list,
    homepage   => \&_url_or_drop,
    bugtracker => sub { ref $_[0] ? _convert( $_[0], $bugtracker2_spec ) : undef },
    repository => sub { my $data = shift; ref $data ? _convert( $data, $repository2_spec ) : undef },
    ':custom'  => \&_prefix_custom,
  };

  sub _cleanup_resources_2 {
    my ($resources, $key, $meta, $to_version) = @_;
    return undef unless $resources && ref $resources eq 'HASH';
    return _convert($resources, $resources2_cleanup, $to_version);
  }

  my $resource1_spec = {
    license    => \&_url_or_drop,
    homepage   => \&_url_or_drop,
    bugtracker => \&_url_or_drop,
    repository => \&_url_or_drop,
    ':custom'  => \&_keep,
  };

  sub _resources_1_3 {
    my (undef, undef, $meta, $version) = @_;
    return undef unless exists $meta->{resources};
    return _convert($meta->{resources}, $resource1_spec);
  }

  *_resources_1_4 = *_resources_1_3;

  sub _resources_1_2 {
    my (undef, undef, $meta) = @_;
    my $resources = $meta->{resources} || {};
    if ( $meta->{license_url} && ! $resources->{license} ) {
      $resources->{license} = $meta->license_url
        if _is_urlish($meta->{license_url});
    }
    return undef unless keys %$resources;
    return _convert($resources, $resource1_spec);
  }

  my $resource_downgrade_spec = {
    license    => sub { return ref $_[0] ? $_[0]->[0] : $_[0] },
    homepage   => \&_url_or_drop,
    bugtracker => sub { return $_[0]->{web} },
    repository => sub { return $_[0]->{url} || $_[0]->{web} },
    ':custom'  => \&_ucfirst_custom,
  };

  sub _downgrade_resources {
    my (undef, undef, $meta, $version) = @_;
    return undef unless exists $meta->{resources};
    return _convert($meta->{resources}, $resource_downgrade_spec);
  }

  sub _release_status {
    my ($element, undef, $meta) = @_;
    return $element if $element && $element =~ m{\A(?:stable|testing|unstable)\z};
    return _release_status_from_version(undef, undef, $meta);
  }

  sub _release_status_from_version {
    my (undef, undef, $meta) = @_;
    my $version = $meta->{version} || '';
    return ( $version =~ /_/ ) ? 'testing' : 'stable';
  }

  my $provides_spec = {
    file => \&_keep,
    version => \&_clean_version,
  };

  my $provides_spec_2 = {
    file => \&_keep,
    version => \&_clean_version,
    ':custom'  => \&_prefix_custom,
  };

  sub _provides {
    my ($element, $key, $meta, $to_version) = @_;
    return unless defined $element && ref $element eq 'HASH';
    my $spec = $to_version == 2 ? $provides_spec_2 : $provides_spec;
    my $new_data = {};
    for my $k ( keys %$element ) {
      $new_data->{$k} = _convert($element->{$k}, $spec, $to_version);
    }
    return $new_data;
  }

  sub _convert {
    my ($data, $spec, $to_version) = @_;

    my $new_data = {};
    for my $key ( keys %$spec ) {
      next if $key eq ':custom' || $key eq ':drop';
      next unless my $fcn = $spec->{$key};
      die "spec for '$key' is not a coderef"
        unless ref $fcn && ref $fcn eq 'CODE';
      my $new_value = $fcn->($data->{$key}, $key, $data, $to_version);
      $new_data->{$key} = $new_value if defined $new_value;
    }

    my $drop_list   = $spec->{':drop'};
    my $customizer  = $spec->{':custom'} || \&_keep;

    for my $key ( keys %$data ) {
      next if $drop_list && grep { $key eq $_ } @$drop_list;
      next if exists $spec->{$key}; # we handled it
      $new_data->{ $customizer->($key) } = $data->{$key};
    }

    return $new_data;
  }

  #--------------------------------------------------------------------------#
  # define converters for each conversion
  #--------------------------------------------------------------------------#

  # each converts from prior version
  # special ":custom" field is used for keys not recognized in spec
  my %up_convert = (
    '2-from-1.4' => {
      # PRIOR MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_2,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # CHANGED TO MANDATORY
      'dynamic_config'      => \&_keep_or_one,
      # ADDED MANDATORY
      'release_status'      => \&_release_status_from_version,
      # PRIOR OPTIONAL
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_directory,
      'optional_features'   => \&_upgrade_optional_features,
      'provides'            => \&_provides,
      'resources'           => \&_upgrade_resources_2,
      # ADDED OPTIONAL
      'description'         => \&_keep,
      'prereqs'             => \&_prereqs_from_1,

      # drop these deprecated fields, but only after we convert
      ':drop' => [ qw(
          build_requires
          configure_requires
          conflicts
          distribution_type
          license_url
          private
          recommends
          requires
      ) ],

      # other random keys need x_ prefixing
      ':custom'              => \&_prefix_custom,
    },
    '1.4-from-1.3' => {
      # PRIOR MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_directory,
      'optional_features'   => \&_optional_features_1_4,
      'provides'            => \&_provides,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      'resources'           => \&_resources_1_4,
      # ADDED OPTIONAL
      'configure_requires'  => \&_keep,

      # drop these deprecated fields, but only after we convert
      ':drop' => [ qw(
        license_url
        private
      )],

      # other random keys are OK if already valid
      ':custom'              => \&_keep
    },
    '1.3-from-1.2' => {
      # PRIOR MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_directory,
      'optional_features'   => \&_optional_features_as_map,
      'provides'            => \&_provides,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      'resources'           => \&_resources_1_3,

      # drop these deprecated fields, but only after we convert
      ':drop' => [ qw(
        license_url
        private
      )],

      # other random keys are OK if already valid
      ':custom'              => \&_keep
    },
    '1.2-from-1.1' => {
      # PRIOR MANDATORY
      'version'             => \&_keep,
      # CHANGED TO MANDATORY
      'license'             => \&_license_1,
      'name'                => \&_keep,
      'generated_by'        => \&_generated_by,
      # ADDED MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'meta-spec'           => \&_change_meta_spec,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      # ADDED OPTIONAL
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_1_2,
      'optional_features'   => \&_optional_features_as_map,
      'provides'            => \&_provides,
      'resources'           => \&_resources_1_2,

      # drop these deprecated fields, but only after we convert
      ':drop' => [ qw(
        license_url
        private
      )],

      # other random keys are OK if already valid
      ':custom'              => \&_keep
    },
    '1.1-from-1.0' => {
      # CHANGED TO MANDATORY
      'version'             => \&_keep,
      # IMPLIED MANDATORY
      'name'                => \&_keep,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      # ADDED OPTIONAL
      'license_url'         => \&_url_or_drop,
      'private'             => \&_keep,

      # other random keys are OK if already valid
      ':custom'              => \&_keep
    },
  );

  my %down_convert = (
    '1.4-from-2' => {
      # MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_downgrade_license,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # OPTIONAL
      'build_requires'      => \&_get_build_requires,
      'configure_requires'  => \&_get_configure_requires,
      'conflicts'           => \&_get_conflicts,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_directory,
      'optional_features'   => \&_downgrade_optional_features,
      'provides'            => \&_provides,
      'recommends'          => \&_get_recommends,
      'requires'            => \&_get_requires,
      'resources'           => \&_downgrade_resources,

      # drop these unsupported fields (after conversion)
      ':drop' => [ qw(
        description
        prereqs
        release_status
      )],

      # custom keys will be left unchanged
      ':custom'              => \&_keep
    },
    '1.3-from-1.4' => {
      # MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_directory,
      'optional_features'   => \&_optional_features_as_map,
      'provides'            => \&_provides,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      'resources'           => \&_resources_1_3,

      # drop these unsupported fields, but only after we convert
      ':drop' => [ qw(
        configure_requires
      )],

      # other random keys are OK if already valid
      ':custom'              => \&_keep,
    },
    '1.2-from-1.3' => {
      # MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_1_2,
      'optional_features'   => \&_optional_features_as_map,
      'provides'            => \&_provides,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      'resources'           => \&_resources_1_3,

      # other random keys are OK if already valid
      ':custom'              => \&_keep,
    },
    '1.1-from-1.2' => {
      # MANDATORY
      'version'             => \&_keep,
      # IMPLIED MANDATORY
      'name'                => \&_keep,
      'meta-spec'           => \&_change_meta_spec,
      # OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'private'             => \&_keep,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,

      # drop unsupported fields
      ':drop' => [ qw(
        abstract
        author
        provides
        no_index
        keywords
        resources
      )],

      # other random keys are OK if already valid
      ':custom'              => \&_keep,
    },
    '1.0-from-1.1' => {
      # IMPLIED MANDATORY
      'name'                => \&_keep,
      'meta-spec'           => \&_change_meta_spec,
      'version'             => \&_keep,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,

      # other random keys are OK if already valid
      ':custom'              => \&_keep,
    },
  );

  my %cleanup = (
    '2' => {
      # PRIOR MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_2,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # CHANGED TO MANDATORY
      'dynamic_config'      => \&_keep_or_one,
      # ADDED MANDATORY
      'release_status'      => \&_release_status,
      # PRIOR OPTIONAL
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_directory,
      'optional_features'   => \&_cleanup_optional_features_2,
      'provides'            => \&_provides,
      'resources'           => \&_cleanup_resources_2,
      # ADDED OPTIONAL
      'description'         => \&_keep,
      'prereqs'             => \&_cleanup_prereqs,

      # drop these deprecated fields, but only after we convert
      ':drop' => [ qw(
          build_requires
          configure_requires
          conflicts
          distribution_type
          license_url
          private
          recommends
          requires
      ) ],

      # other random keys need x_ prefixing
      ':custom'              => \&_prefix_custom,
    },
    '1.4' => {
      # PRIOR MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_directory,
      'optional_features'   => \&_optional_features_1_4,
      'provides'            => \&_provides,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      'resources'           => \&_resources_1_4,
      # ADDED OPTIONAL
      'configure_requires'  => \&_keep,

      # other random keys are OK if already valid
      ':custom'             => \&_keep
    },
    '1.3' => {
      # PRIOR MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'meta-spec'           => \&_change_meta_spec,
      'name'                => \&_keep,
      'version'             => \&_keep,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_directory,
      'optional_features'   => \&_optional_features_as_map,
      'provides'            => \&_provides,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      'resources'           => \&_resources_1_3,

      # other random keys are OK if already valid
      ':custom'             => \&_keep
    },
    '1.2' => {
      # PRIOR MANDATORY
      'version'             => \&_keep,
      # CHANGED TO MANDATORY
      'license'             => \&_license_1,
      'name'                => \&_keep,
      'generated_by'        => \&_generated_by,
      # ADDED MANDATORY
      'abstract'            => \&_keep_or_unknown,
      'author'              => \&_author_list,
      'meta-spec'           => \&_change_meta_spec,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      # ADDED OPTIONAL
      'keywords'            => \&_keep,
      'no_index'            => \&_no_index_1_2,
      'optional_features'   => \&_optional_features_as_map,
      'provides'            => \&_provides,
      'resources'           => \&_resources_1_2,

      # other random keys are OK if already valid
      ':custom'             => \&_keep
    },
    '1.1' => {
      # CHANGED TO MANDATORY
      'version'             => \&_keep,
      # IMPLIED MANDATORY
      'name'                => \&_keep,
      'meta-spec'           => \&_change_meta_spec,
      # PRIOR OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,
      # ADDED OPTIONAL
      'license_url'         => \&_url_or_drop,
      'private'             => \&_keep,

      # other random keys are OK if already valid
      ':custom'             => \&_keep
    },
    '1.0' => {
      # IMPLIED MANDATORY
      'name'                => \&_keep,
      'meta-spec'           => \&_change_meta_spec,
      'version'             => \&_keep,
      # IMPLIED OPTIONAL
      'build_requires'      => \&_version_map,
      'conflicts'           => \&_version_map,
      'distribution_type'   => \&_keep,
      'dynamic_config'      => \&_keep_or_one,
      'generated_by'        => \&_generated_by,
      'license'             => \&_license_1,
      'recommends'          => \&_version_map,
      'requires'            => \&_version_map,

      # other random keys are OK if already valid
      ':custom'             => \&_keep,
    },
  );

  #--------------------------------------------------------------------------#
  # Code
  #--------------------------------------------------------------------------#


  sub new {
    my ($class,$data) = @_;

    # create an attributes hash
    my $self = {
      'data'    => $data,
      'spec'    => $data->{'meta-spec'}{'version'} || "1.0",
    };

    # create the object
    return bless $self, $class;
  }


  sub convert {
    my ($self, %args) = @_;
    my $args = { %args };

    my $new_version = $args->{version} || $HIGHEST;

    my ($old_version) = $self->{spec};
    my $converted = _dclone($self->{data});

    if ( $old_version == $new_version ) {
      $converted = _convert( $converted, $cleanup{$old_version}, $old_version );
      my $cmv = CPAN::Meta::Validator->new( $converted );
      unless ( $cmv->is_valid ) {
        my $errs = join("\n", $cmv->errors);
        die "Failed to clean-up $old_version metadata. Errors:\n$errs\n";
      }
      return $converted;
    }
    elsif ( $old_version > $new_version )  {
      my @vers = sort { $b <=> $a } keys %known_specs;
      for my $i ( 0 .. $#vers-1 ) {
        next if $vers[$i] > $old_version;
        last if $vers[$i+1] < $new_version;
        my $spec_string = "$vers[$i+1]-from-$vers[$i]";
        $converted = _convert( $converted, $down_convert{$spec_string}, $vers[$i+1] );
        my $cmv = CPAN::Meta::Validator->new( $converted );
        unless ( $cmv->is_valid ) {
          my $errs = join("\n", $cmv->errors);
          die "Failed to downconvert metadata to $vers[$i+1]. Errors:\n$errs\n";
        }
      }
      return $converted;
    }
    else {
      my @vers = sort { $a <=> $b } keys %known_specs;
      for my $i ( 0 .. $#vers-1 ) {
        next if $vers[$i] < $old_version;
        last if $vers[$i+1] > $new_version;
        my $spec_string = "$vers[$i+1]-from-$vers[$i]";
        $converted = _convert( $converted, $up_convert{$spec_string}, $vers[$i+1] );
        my $cmv = CPAN::Meta::Validator->new( $converted );
        unless ( $cmv->is_valid ) {
          my $errs = join("\n", $cmv->errors);
          die "Failed to upconvert metadata to $vers[$i+1]. Errors:\n$errs\n";
        }
      }
      return $converted;
    }
  }

  1;




  __END__


CPAN_META_CONVERTER

$fatpacked{"CPAN/Meta/Feature.pm"} = <<'CPAN_META_FEATURE';
  use 5.006;
  use strict;
  use warnings;
  package CPAN::Meta::Feature;
  BEGIN {
    $CPAN::Meta::Feature::VERSION = '2.110930';
  }
  # ABSTRACT: an optional feature provided by a CPAN distribution

  use CPAN::Meta::Prereqs;


  sub new {
    my ($class, $identifier, $spec) = @_;

    my %guts = (
      identifier  => $identifier,
      description => $spec->{description},
      prereqs     => CPAN::Meta::Prereqs->new($spec->{prereqs}),
    );

    bless \%guts => $class;
  }


  sub identifier  { $_[0]{identifier}  }


  sub description { $_[0]{description} }


  sub prereqs     { $_[0]{prereqs} }

  1;




  __END__



CPAN_META_FEATURE

$fatpacked{"CPAN/Meta/History.pm"} = <<'CPAN_META_HISTORY';
  # vi:tw=72
  use 5.006;
  use strict;
  use warnings;
  package CPAN::Meta::History;
  BEGIN {
    $CPAN::Meta::History::VERSION = '2.110930';
  }
  # ABSTRACT: history of CPAN Meta Spec changes
  1;



  __END__
  =pod

CPAN_META_HISTORY

$fatpacked{"CPAN/Meta/Prereqs.pm"} = <<'CPAN_META_PREREQS';
  use 5.006;
  use strict;
  use warnings;
  package CPAN::Meta::Prereqs;
  BEGIN {
    $CPAN::Meta::Prereqs::VERSION = '2.110930';
  }
  # ABSTRACT: a set of distribution prerequisites by phase and type


  use Carp qw(confess);
  use Scalar::Util qw(blessed);
  use Version::Requirements 0.101020; # finalize


  sub __legal_phases { qw(configure build test runtime develop)   }
  sub __legal_types  { qw(requires recommends suggests conflicts) }

  # expect a prereq spec from META.json -- rjbs, 2010-04-11
  sub new {
    my ($class, $prereq_spec) = @_;
    $prereq_spec ||= {};

    my %is_legal_phase = map {; $_ => 1 } $class->__legal_phases;
    my %is_legal_type  = map {; $_ => 1 } $class->__legal_types;

    my %guts;
    PHASE: for my $phase (keys %$prereq_spec) {
      next PHASE unless $phase =~ /\Ax_/i or $is_legal_phase{$phase};

      my $phase_spec = $prereq_spec->{ $phase };
      next PHASE unless keys %$phase_spec;

      TYPE: for my $type (keys %$phase_spec) {
        next TYPE unless $type =~ /\Ax_/i or $is_legal_type{$type};

        my $spec = $phase_spec->{ $type };

        next TYPE unless keys %$spec;

        $guts{prereqs}{$phase}{$type} = Version::Requirements->from_string_hash(
          $spec
        );
      }
    }

    return bless \%guts => $class;
  }


  sub requirements_for {
    my ($self, $phase, $type) = @_;

    confess "requirements_for called without phase" unless defined $phase;
    confess "requirements_for called without type"  unless defined $type;

    unless ($phase =~ /\Ax_/i or grep { $phase eq $_ } $self->__legal_phases) {
      confess "requested requirements for unknown phase: $phase";
    }

    unless ($type =~ /\Ax_/i or grep { $type eq $_ } $self->__legal_types) {
      confess "requested requirements for unknown type: $type";
    }

    my $req = ($self->{prereqs}{$phase}{$type} ||= Version::Requirements->new);

    $req->finalize if $self->is_finalized;

    return $req;
  }


  sub with_merged_prereqs {
    my ($self, $other) = @_;

    my @other = blessed($other) ? $other : @$other;

    my @prereq_objs = ($self, @other);

    my %new_arg;

    for my $phase ($self->__legal_phases) {
      for my $type ($self->__legal_types) {
        my $req = Version::Requirements->new;

        for my $prereq (@prereq_objs) {
          my $this_req = $prereq->requirements_for($phase, $type);
          next unless $this_req->required_modules;

          $req->add_requirements($this_req);
        }

        next unless $req->required_modules;

        $new_arg{ $phase }{ $type } = $req->as_string_hash;
      }
    }

    return (ref $self)->new(\%new_arg);
  }


  sub as_string_hash {
    my ($self) = @_;

    my %hash;

    for my $phase ($self->__legal_phases) {
      for my $type ($self->__legal_types) {
        my $req = $self->requirements_for($phase, $type);
        next unless $req->required_modules;

        $hash{ $phase }{ $type } = $req->as_string_hash;
      }
    }

    return \%hash;
  }


  sub is_finalized { $_[0]{finalized} }


  sub finalize {
    my ($self) = @_;

    $self->{finalized} = 1;

    for my $phase (keys %{ $self->{prereqs} }) {
      $_->finalize for values %{ $self->{prereqs}{$phase} };
    }
  }


  sub clone {
    my ($self) = @_;

    my $clone = (ref $self)->new( $self->as_string_hash );
  }

  1;




  __END__



CPAN_META_PREREQS

$fatpacked{"CPAN/Meta/Spec.pm"} = <<'CPAN_META_SPEC';
  # vi:tw=72
  use 5.006;
  use strict;
  use warnings;
  package CPAN::Meta::Spec;
  BEGIN {
    $CPAN::Meta::Spec::VERSION = '2.110930';
  }
  # ABSTRACT: specification for CPAN distribution metadata
  1;



  __END__
  =pod

CPAN_META_SPEC

$fatpacked{"CPAN/Meta/Validator.pm"} = <<'CPAN_META_VALIDATOR';
  use 5.006;
  use strict;
  use warnings;
  package CPAN::Meta::Validator;
  BEGIN {
    $CPAN::Meta::Validator::VERSION = '2.110930';
  }
  # ABSTRACT: validate CPAN distribution metadata structures


  #--------------------------------------------------------------------------#
  # This code copied and adapted from Test::CPAN::Meta
  # by Barbie, <barbie@cpan.org> for Miss Barbell Productions,
  # L<http://www.missbarbell.co.uk>
  #--------------------------------------------------------------------------#

  #--------------------------------------------------------------------------#
  # Specification Definitions
  #--------------------------------------------------------------------------#

  my %known_specs = (
      '1.4' => 'http://module-build.sourceforge.net/META-spec-v1.4.html',
      '1.3' => 'http://module-build.sourceforge.net/META-spec-v1.3.html',
      '1.2' => 'http://module-build.sourceforge.net/META-spec-v1.2.html',
      '1.1' => 'http://module-build.sourceforge.net/META-spec-v1.1.html',
      '1.0' => 'http://module-build.sourceforge.net/META-spec-v1.0.html'
  );
  my %known_urls = map {$known_specs{$_} => $_} keys %known_specs;

  my $module_map1 = { 'map' => { ':key' => { name => \&module, value => \&exversion } } };

  my $module_map2 = { 'map' => { ':key' => { name => \&module, value => \&version   } } };

  my $no_index_2 = {
      'map'       => { file       => { list => { value => \&string } },
                       directory  => { list => { value => \&string } },
                       'package'  => { list => { value => \&string } },
                       namespace  => { list => { value => \&string } },
                      ':key'      => { name => \&custom_2, value => \&anything },
      }
  };

  my $no_index_1_3 = {
      'map'       => { file       => { list => { value => \&string } },
                       directory  => { list => { value => \&string } },
                       'package'  => { list => { value => \&string } },
                       namespace  => { list => { value => \&string } },
                       ':key'     => { name => \&string, value => \&anything },
      }
  };

  my $no_index_1_2 = {
      'map'       => { file       => { list => { value => \&string } },
                       dir        => { list => { value => \&string } },
                       'package'  => { list => { value => \&string } },
                       namespace  => { list => { value => \&string } },
                       ':key'     => { name => \&string, value => \&anything },
      }
  };

  my $no_index_1_1 = {
      'map'       => { ':key'     => { name => \&string, list => { value => \&string } },
      }
  };

  my $prereq_map = {
    map => {
      ':key' => {
        name => \&phase,
        'map' => {
          ':key'  => {
            name => \&relation,
            %$module_map1,
          },
        },
      }
    },
  };

  my %definitions = (
    '2' => {
      # REQUIRED
      'abstract'            => { mandatory => 1, value => \&string  },
      'author'              => { mandatory => 1, lazylist => { value => \&string } },
      'dynamic_config'      => { mandatory => 1, value => \&boolean },
      'generated_by'        => { mandatory => 1, value => \&string  },
      'license'             => { mandatory => 1, lazylist => { value => \&license } },
      'meta-spec' => {
        mandatory => 1,
        'map' => {
          version => { mandatory => 1, value => \&version},
          url     => { value => \&url },
          ':key' => { name => \&custom_2, value => \&anything },
        }
      },
      'name'                => { mandatory => 1, value => \&string  },
      'release_status'      => { mandatory => 1, value => \&release_status },
      'version'             => { mandatory => 1, value => \&version },

      # OPTIONAL
      'description' => { value => \&string },
      'keywords'    => { lazylist => { value => \&string } },
      'no_index'    => $no_index_2,
      'optional_features'   => {
        'map'       => {
          ':key'  => {
            name => \&string,
            'map'   => {
              description        => { value => \&string },
              prereqs => $prereq_map,
              ':key' => { name => \&custom_2, value => \&anything },
            }
          }
        }
      },
      'prereqs' => $prereq_map,
      'provides'    => {
        'map'       => {
          ':key' => {
            name  => \&module,
            'map' => {
              file    => { mandatory => 1, value => \&file },
              version => { value => \&version },
              ':key' => { name => \&custom_2, value => \&anything },
            }
          }
        }
      },
      'resources'   => {
        'map'       => {
          license    => { lazylist => { value => \&url } },
          homepage   => { value => \&url },
          bugtracker => {
            'map' => {
              web => { value => \&url },
              mailto => { value => \&string},
              ':key' => { name => \&custom_2, value => \&anything },
            }
          },
          repository => {
            'map' => {
              web => { value => \&url },
              url => { value => \&url },
              type => { value => \&string },
              ':key' => { name => \&custom_2, value => \&anything },
            }
          },
          ':key'     => { value => \&string, name => \&custom_2 },
        }
      },

      # CUSTOM -- additional user defined key/value pairs
      # note we can only validate the key name, as the structure is user defined
      ':key'        => { name => \&custom_2, value => \&anything },
    },

  '1.4' => {
    'meta-spec'           => {
      mandatory => 1,
      'map' => {
        version => { mandatory => 1, value => \&version},
        url     => { mandatory => 1, value => \&urlspec },
        ':key'  => { name => \&string, value => \&anything },
      },
    },

    'name'                => { mandatory => 1, value => \&string  },
    'version'             => { mandatory => 1, value => \&version },
    'abstract'            => { mandatory => 1, value => \&string  },
    'author'              => { mandatory => 1, list  => { value => \&string } },
    'license'             => { mandatory => 1, value => \&license },
    'generated_by'        => { mandatory => 1, value => \&string  },

    'distribution_type'   => { value => \&string  },
    'dynamic_config'      => { value => \&boolean },

    'requires'            => $module_map1,
    'recommends'          => $module_map1,
    'build_requires'      => $module_map1,
    'configure_requires'  => $module_map1,
    'conflicts'           => $module_map2,

    'optional_features'   => {
      'map'       => {
          ':key'  => { name => \&string,
              'map'   => { description        => { value => \&string },
                           requires           => $module_map1,
                           recommends         => $module_map1,
                           build_requires     => $module_map1,
                           conflicts          => $module_map2,
                           ':key'  => { name => \&string, value => \&anything },
              }
          }
       }
    },

    'provides'    => {
      'map'       => {
        ':key' => { name  => \&module,
          'map' => {
            file    => { mandatory => 1, value => \&file },
            version => { value => \&version },
            ':key'  => { name => \&string, value => \&anything },
          }
        }
      }
    },

    'no_index'    => $no_index_1_3,
    'private'     => $no_index_1_3,

    'keywords'    => { list => { value => \&string } },

    'resources'   => {
      'map'       => { license    => { value => \&url },
                       homepage   => { value => \&url },
                       bugtracker => { value => \&url },
                       repository => { value => \&url },
                       ':key'     => { value => \&string, name => \&custom_1 },
      }
    },

    # additional user defined key/value pairs
    # note we can only validate the key name, as the structure is user defined
    ':key'        => { name => \&string, value => \&anything },
  },

  '1.3' => {
    'meta-spec'           => {
      mandatory => 1,
      'map' => {
        version => { mandatory => 1, value => \&version},
        url     => { mandatory => 1, value => \&urlspec },
        ':key'  => { name => \&string, value => \&anything },
      },
    },

    'name'                => { mandatory => 1, value => \&string  },
    'version'             => { mandatory => 1, value => \&version },
    'abstract'            => { mandatory => 1, value => \&string  },
    'author'              => { mandatory => 1, list  => { value => \&string } },
    'license'             => { mandatory => 1, value => \&license },
    'generated_by'        => { mandatory => 1, value => \&string  },

    'distribution_type'   => { value => \&string  },
    'dynamic_config'      => { value => \&boolean },

    'requires'            => $module_map1,
    'recommends'          => $module_map1,
    'build_requires'      => $module_map1,
    'conflicts'           => $module_map2,

    'optional_features'   => {
      'map'       => {
          ':key'  => { name => \&string,
              'map'   => { description        => { value => \&string },
                           requires           => $module_map1,
                           recommends         => $module_map1,
                           build_requires     => $module_map1,
                           conflicts          => $module_map2,
                           ':key'  => { name => \&string, value => \&anything },
              }
          }
       }
    },

    'provides'    => {
      'map'       => {
        ':key' => { name  => \&module,
          'map' => {
            file    => { mandatory => 1, value => \&file },
            version => { value => \&version },
            ':key'  => { name => \&string, value => \&anything },
          }
        }
      }
    },


    'no_index'    => $no_index_1_3,
    'private'     => $no_index_1_3,

    'keywords'    => { list => { value => \&string } },

    'resources'   => {
      'map'       => { license    => { value => \&url },
                       homepage   => { value => \&url },
                       bugtracker => { value => \&url },
                       repository => { value => \&url },
                       ':key'     => { value => \&string, name => \&custom_1 },
      }
    },

    # additional user defined key/value pairs
    # note we can only validate the key name, as the structure is user defined
    ':key'        => { name => \&string, value => \&anything },
  },

  # v1.2 is misleading, it seems to assume that a number of fields where created
  # within v1.1, when they were created within v1.2. This may have been an
  # original mistake, and that a v1.1 was retro fitted into the timeline, when
  # v1.2 was originally slated as v1.1. But I could be wrong ;)
  '1.2' => {
    'meta-spec'           => {
      mandatory => 1,
      'map' => {
        version => { mandatory => 1, value => \&version},
        url     => { mandatory => 1, value => \&urlspec },
        ':key'  => { name => \&string, value => \&anything },
      },
    },


    'name'                => { mandatory => 1, value => \&string  },
    'version'             => { mandatory => 1, value => \&version },
    'license'             => { mandatory => 1, value => \&license },
    'generated_by'        => { mandatory => 1, value => \&string  },
    'author'              => { mandatory => 1, list => { value => \&string } },
    'abstract'            => { mandatory => 1, value => \&string  },

    'distribution_type'   => { value => \&string  },
    'dynamic_config'      => { value => \&boolean },

    'keywords'            => { list => { value => \&string } },

    'private'             => $no_index_1_2,
    '$no_index'           => $no_index_1_2,

    'requires'            => $module_map1,
    'recommends'          => $module_map1,
    'build_requires'      => $module_map1,
    'conflicts'           => $module_map2,

    'optional_features'   => {
      'map'       => {
          ':key'  => { name => \&string,
              'map'   => { description        => { value => \&string },
                           requires           => $module_map1,
                           recommends         => $module_map1,
                           build_requires     => $module_map1,
                           conflicts          => $module_map2,
                           ':key'  => { name => \&string, value => \&anything },
              }
          }
       }
    },

    'provides'    => {
      'map'       => {
        ':key' => { name  => \&module,
          'map' => {
            file    => { mandatory => 1, value => \&file },
            version => { value => \&version },
            ':key'  => { name => \&string, value => \&anything },
          }
        }
      }
    },

    'resources'   => {
      'map'       => { license    => { value => \&url },
                       homepage   => { value => \&url },
                       bugtracker => { value => \&url },
                       repository => { value => \&url },
                       ':key'     => { value => \&string, name => \&custom_1 },
      }
    },

    # additional user defined key/value pairs
    # note we can only validate the key name, as the structure is user defined
    ':key'        => { name => \&string, value => \&anything },
  },

  # note that the 1.1 spec only specifies 'version' as mandatory
  '1.1' => {
    'name'                => { value => \&string  },
    'version'             => { mandatory => 1, value => \&version },
    'license'             => { value => \&license },
    'generated_by'        => { value => \&string  },

    'license_uri'         => { value => \&url },
    'distribution_type'   => { value => \&string  },
    'dynamic_config'      => { value => \&boolean },

    'private'             => $no_index_1_1,

    'requires'            => $module_map1,
    'recommends'          => $module_map1,
    'build_requires'      => $module_map1,
    'conflicts'           => $module_map2,

    # additional user defined key/value pairs
    # note we can only validate the key name, as the structure is user defined
    ':key'        => { name => \&string, value => \&anything },
  },

  # note that the 1.0 spec doesn't specify optional or mandatory fields
  # but we will treat version as mandatory since otherwise META 1.0 is
  # completely arbitrary and pointless
  '1.0' => {
    'name'                => { value => \&string  },
    'version'             => { mandatory => 1, value => \&version },
    'license'             => { value => \&license },
    'generated_by'        => { value => \&string  },

    'license_uri'         => { value => \&url },
    'distribution_type'   => { value => \&string  },
    'dynamic_config'      => { value => \&boolean },

    'requires'            => $module_map1,
    'recommends'          => $module_map1,
    'build_requires'      => $module_map1,
    'conflicts'           => $module_map2,

    # additional user defined key/value pairs
    # note we can only validate the key name, as the structure is user defined
    ':key'        => { name => \&string, value => \&anything },
  },
  );

  #--------------------------------------------------------------------------#
  # Code
  #--------------------------------------------------------------------------#


  sub new {
    my ($class,$data) = @_;

    # create an attributes hash
    my $self = {
      'data'    => $data,
      'spec'    => $data->{'meta-spec'}{'version'} || "1.0",
      'errors'  => undef,
    };

    # create the object
    return bless $self, $class;
  }


  sub is_valid {
      my $self = shift;
      my $data = $self->{data};
      my $spec_version = $self->{spec};
      $self->check_map($definitions{$spec_version},$data);
      return ! $self->errors;
  }


  sub errors {
      my $self = shift;
      return ()   unless(defined $self->{errors});
      return @{$self->{errors}};
  }


  my $spec_error = "Missing validation action in specification. "
    . "Must be one of 'map', 'list', 'lazylist', or 'value'";

  sub check_map {
      my ($self,$spec,$data) = @_;

      if(ref($spec) ne 'HASH') {
          $self->_error( "Unknown META specification, cannot validate." );
          return;
      }

      if(ref($data) ne 'HASH') {
          $self->_error( "Expected a map structure from string or file." );
          return;
      }

      for my $key (keys %$spec) {
          next    unless($spec->{$key}->{mandatory});
          next    if(defined $data->{$key});
          push @{$self->{stack}}, $key;
          $self->_error( "Missing mandatory field, '$key'" );
          pop @{$self->{stack}};
      }

      for my $key (keys %$data) {
          push @{$self->{stack}}, $key;
          if($spec->{$key}) {
              if($spec->{$key}{value}) {
                  $spec->{$key}{value}->($self,$key,$data->{$key});
              } elsif($spec->{$key}{'map'}) {
                  $self->check_map($spec->{$key}{'map'},$data->{$key});
              } elsif($spec->{$key}{'list'}) {
                  $self->check_list($spec->{$key}{'list'},$data->{$key});
              } elsif($spec->{$key}{'lazylist'}) {
                  $self->check_lazylist($spec->{$key}{'lazylist'},$data->{$key});
              } else {
                  $self->_error( "$spec_error for '$key'" );
              }

          } elsif ($spec->{':key'}) {
              $spec->{':key'}{name}->($self,$key,$key);
              if($spec->{':key'}{value}) {
                  $spec->{':key'}{value}->($self,$key,$data->{$key});
              } elsif($spec->{':key'}{'map'}) {
                  $self->check_map($spec->{':key'}{'map'},$data->{$key});
              } elsif($spec->{':key'}{'list'}) {
                  $self->check_list($spec->{':key'}{'list'},$data->{$key});
              } elsif($spec->{':key'}{'lazylist'}) {
                  $self->check_lazylist($spec->{':key'}{'lazylist'},$data->{$key});
              } else {
                  $self->_error( "$spec_error for ':key'" );
              }


          } else {
              $self->_error( "Unknown key, '$key', found in map structure" );
          }
          pop @{$self->{stack}};
      }
  }

  # if it's a string, make it into a list and check the list
  sub check_lazylist {
      my ($self,$spec,$data) = @_;

      if ( defined $data && ! ref($data) ) {
        $data = [ $data ];
      }

      $self->check_list($spec,$data);
  }

  sub check_list {
      my ($self,$spec,$data) = @_;

      if(ref($data) ne 'ARRAY') {
          $self->_error( "Expected a list structure" );
          return;
      }

      if(defined $spec->{mandatory}) {
          if(!defined $data->[0]) {
              $self->_error( "Missing entries from mandatory list" );
          }
      }

      for my $value (@$data) {
          push @{$self->{stack}}, $value || "<undef>";
          if(defined $spec->{value}) {
              $spec->{value}->($self,'list',$value);
          } elsif(defined $spec->{'map'}) {
              $self->check_map($spec->{'map'},$value);
          } elsif(defined $spec->{'list'}) {
              $self->check_list($spec->{'list'},$value);
          } elsif(defined $spec->{'lazylist'}) {
              $self->check_lazylist($spec->{'lazylist'},$value);
          } elsif ($spec->{':key'}) {
              $self->check_map($spec,$value);
          } else {
            $self->_error( "$spec_error associated with '$self->{stack}[-2]'" );
          }
          pop @{$self->{stack}};
      }
  }


  sub header {
      my ($self,$key,$value) = @_;
      if(defined $value) {
          return 1    if($value && $value =~ /^--- #YAML:1.0/);
      }
      $self->_error( "file does not have a valid YAML header." );
      return 0;
  }

  sub release_status {
    my ($self,$key,$value) = @_;
    if(defined $value) {
      my $version = $self->{data}{version} || '';
      if ( $version =~ /_/ ) {
        return 1 if ( $value =~ /\A(?:testing|unstable)\z/ );
        $self->_error( "'$value' for '$key' is invalid for version '$version'" );
      }
      else {
        return 1 if ( $value =~ /\A(?:stable|testing|unstable)\z/ );
        $self->_error( "'$value' for '$key' is invalid" );
      }
    }
    else {
      $self->_error( "'$key' is not defined" );
    }
    return 0;
  }

  # _uri_split taken from URI::Split by Gisle Aas, Copyright 2003
  sub _uri_split {
       return $_[0] =~ m,(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?,;
  }

  sub url {
      my ($self,$key,$value) = @_;
      if(defined $value) {
        my ($scheme, $auth, $path, $query, $frag) = _uri_split($value);
        unless ( defined $scheme && length $scheme ) {
          $self->_error( "'$value' for '$key' does not have a URL scheme" );
          return 0;
        }
        unless ( defined $auth && length $auth ) {
          $self->_error( "'$value' for '$key' does not have a URL authority" );
          return 0;
        }
        return 1;
      }
      $value ||= '';
      $self->_error( "'$value' for '$key' is not a valid URL." );
      return 0;
  }

  sub urlspec {
      my ($self,$key,$value) = @_;
      if(defined $value) {
          return 1    if($value && $known_specs{$self->{spec}} eq $value);
          if($value && $known_urls{$value}) {
              $self->_error( 'META specification URL does not match version' );
              return 0;
          }
      }
      $self->_error( 'Unknown META specification' );
      return 0;
  }

  sub anything { return 1 }

  sub string {
      my ($self,$key,$value) = @_;
      if(defined $value) {
          return 1    if($value || $value =~ /^0$/);
      }
      $self->_error( "value is an undefined string" );
      return 0;
  }

  sub string_or_undef {
      my ($self,$key,$value) = @_;
      return 1    unless(defined $value);
      return 1    if($value || $value =~ /^0$/);
      $self->_error( "No string defined for '$key'" );
      return 0;
  }

  sub file {
      my ($self,$key,$value) = @_;
      return 1    if(defined $value);
      $self->_error( "No file defined for '$key'" );
      return 0;
  }

  sub exversion {
      my ($self,$key,$value) = @_;
      if(defined $value && ($value || $value =~ /0/)) {
          my $pass = 1;
          for(split(",",$value)) { $self->version($key,$_) or ($pass = 0); }
          return $pass;
      }
      $value = '<undef>'  unless(defined $value);
      $self->_error( "'$value' for '$key' is not a valid version." );
      return 0;
  }

  sub version {
      my ($self,$key,$value) = @_;
      if(defined $value) {
          return 0    unless($value || $value =~ /0/);
          return 1    if($value =~ /^\s*((<|<=|>=|>|!=|==)\s*)?v?\d+((\.\d+((_|\.)\d+)?)?)/);
      } else {
          $value = '<undef>';
      }
      $self->_error( "'$value' for '$key' is not a valid version." );
      return 0;
  }

  sub boolean {
      my ($self,$key,$value) = @_;
      if(defined $value) {
          return 1    if($value =~ /^(0|1|true|false)$/);
      } else {
          $value = '<undef>';
      }
      $self->_error( "'$value' for '$key' is not a boolean value." );
      return 0;
  }

  my %v1_licenses = (
      'perl'         => 'http://dev.perl.org/licenses/',
      'gpl'          => 'http://www.opensource.org/licenses/gpl-license.php',
      'apache'       => 'http://apache.org/licenses/LICENSE-2.0',
      'artistic'     => 'http://opensource.org/licenses/artistic-license.php',
      'artistic_2'   => 'http://opensource.org/licenses/artistic-license-2.0.php',
      'lgpl'         => 'http://www.opensource.org/licenses/lgpl-license.phpt',
      'bsd'          => 'http://www.opensource.org/licenses/bsd-license.php',
      'gpl'          => 'http://www.opensource.org/licenses/gpl-license.php',
      'mit'          => 'http://opensource.org/licenses/mit-license.php',
      'mozilla'      => 'http://opensource.org/licenses/mozilla1.1.php',
      'open_source'  => undef,
      'unrestricted' => undef,
      'restrictive'  => undef,
      'unknown'      => undef,
  );

  my %v2_licenses = map { $_ => 1 } qw(
    agpl_3
    apache_1_1
    apache_2_0
    artistic_1
    artistic_2
    bsd
    freebsd
    gfdl_1_2
    gfdl_1_3
    gpl_1
    gpl_2
    gpl_3
    lgpl_2_1
    lgpl_3_0
    mit
    mozilla_1_0
    mozilla_1_1
    openssl
    perl_5
    qpl_1_0
    ssleay
    sun
    zlib
    open_source
    restricted
    unrestricted
    unknown
  );

  sub license {
      my ($self,$key,$value) = @_;
      my $licenses = $self->{spec} < 2 ? \%v1_licenses : \%v2_licenses;
      if(defined $value) {
          return 1    if($value && exists $licenses->{$value});
      } else {
          $value = '<undef>';
      }
      $self->_error( "License '$value' is invalid" );
      return 0;
  }

  sub custom_1 {
      my ($self,$key) = @_;
      if(defined $key) {
          # a valid user defined key should be alphabetic
          # and contain at least one capital case letter.
          return 1    if($key && $key =~ /^[_a-z]+$/i && $key =~ /[A-Z]/);
      } else {
          $key = '<undef>';
      }
      $self->_error( "Custom resource '$key' must be in CamelCase." );
      return 0;
  }

  sub custom_2 {
      my ($self,$key) = @_;
      if(defined $key) {
          return 1    if($key && $key =~ /^x_/i);  # user defined
      } else {
          $key = '<undef>';
      }
      $self->_error( "Custom key '$key' must begin with 'x_' or 'X_'." );
      return 0;
  }

  sub identifier {
      my ($self,$key) = @_;
      if(defined $key) {
          return 1    if($key && $key =~ /^([a-z][_a-z]+)$/i);    # spec 2.0 defined
      } else {
          $key = '<undef>';
      }
      $self->_error( "Key '$key' is not a legal identifier." );
      return 0;
  }

  sub module {
      my ($self,$key) = @_;
      if(defined $key) {
          return 1    if($key && $key =~ /^[A-Za-z0-9_]+(::[A-Za-z0-9_]+)*$/);
      } else {
          $key = '<undef>';
      }
      $self->_error( "Key '$key' is not a legal module name." );
      return 0;
  }

  my @valid_phases = qw/ configure build test runtime develop /;
  sub phase {
      my ($self,$key) = @_;
      if(defined $key) {
          return 1 if( length $key && grep { $key eq $_ } @valid_phases );
          return 1 if $key =~ /x_/i;
      } else {
          $key = '<undef>';
      }
      $self->_error( "Key '$key' is not a legal phase." );
      return 0;
  }

  my @valid_relations = qw/ requires recommends suggests conflicts /;
  sub relation {
      my ($self,$key) = @_;
      if(defined $key) {
          return 1 if( length $key && grep { $key eq $_ } @valid_relations );
          return 1 if $key =~ /x_/i;
      } else {
          $key = '<undef>';
      }
      $self->_error( "Key '$key' is not a legal prereq relationship." );
      return 0;
  }

  sub _error {
      my $self = shift;
      my $mess = shift;

      $mess .= ' ('.join(' -> ',@{$self->{stack}}).')'  if($self->{stack});
      $mess .= " [Validation: $self->{spec}]";

      push @{$self->{errors}}, $mess;
  }

  1;




  __END__



CPAN_META_VALIDATOR

$fatpacked{"CPAN/Meta/YAML.pm"} = <<'CPAN_META_YAML';
  package CPAN::Meta::YAML;
  BEGIN {
    $CPAN::Meta::YAML::VERSION = '0.003';
  }

  use strict;

  # UTF Support?
  sub HAVE_UTF8 () { $] >= 5.007003 }
  BEGIN {
    if ( HAVE_UTF8 ) {
      # The string eval helps hide this from Test::MinimumVersion
      eval "require utf8;";
      die "Failed to load UTF-8 support" if $@;
    }

    # Class structure
    require 5.004;
    require Exporter;
    require Carp;
    @CPAN::Meta::YAML::ISA       = qw{ Exporter  };
    @CPAN::Meta::YAML::EXPORT    = qw{ Load Dump };
    @CPAN::Meta::YAML::EXPORT_OK = qw{ LoadFile DumpFile freeze thaw };

    # Error storage
    $CPAN::Meta::YAML::errstr    = '';
  }

  # The character class of all characters we need to escape
  # NOTE: Inlined, since it's only used once
  # my $RE_ESCAPE = '[\\x00-\\x08\\x0b-\\x0d\\x0e-\\x1f\"\n]';

  # Printed form of the unprintable characters in the lowest range
  # of ASCII characters, listed by ASCII ordinal position.
  my @UNPRINTABLE = qw(
    z    x01  x02  x03  x04  x05  x06  a
    x08  t    n    v    f    r    x0e  x0f
    x10  x11  x12  x13  x14  x15  x16  x17
    x18  x19  x1a  e    x1c  x1d  x1e  x1f
  );

  # Printable characters for escapes
  my %UNESCAPES = (
    z => "\x00", a => "\x07", t    => "\x09",
    n => "\x0a", v => "\x0b", f    => "\x0c",
    r => "\x0d", e => "\x1b", '\\' => '\\',
  );

  # Special magic boolean words
  my %QUOTE = map { $_ => 1 } qw{
    null Null NULL
    y Y yes Yes YES n N no No NO
    true True TRUE false False FALSE
    on On ON off Off OFF
  };





  #####################################################################
  # Implementation

  # Create an empty CPAN::Meta::YAML object
  sub new {
    my $class = shift;
    bless [ @_ ], $class;
  }

  # Create an object from a file
  sub read {
    my $class = ref $_[0] ? ref shift : shift;

    # Check the file
    my $file = shift or return $class->_error( 'You did not specify a file name' );
    return $class->_error( "File '$file' does not exist" )              unless -e $file;
    return $class->_error( "'$file' is a directory, not a file" )       unless -f _;
    return $class->_error( "Insufficient permissions to read '$file'" ) unless -r _;

    # Slurp in the file
    local $/ = undef;
    local *CFG;
    unless ( open(CFG, $file) ) {
      return $class->_error("Failed to open file '$file': $!");
    }
    my $contents = <CFG>;
    unless ( close(CFG) ) {
      return $class->_error("Failed to close file '$file': $!");
    }

    $class->read_string( $contents );
  }

  # Create an object from a string
  sub read_string {
    my $class  = ref $_[0] ? ref shift : shift;
    my $self   = bless [], $class;
    my $string = $_[0];
    eval {
      unless ( defined $string ) {
        die \"Did not provide a string to load";
      }

      # Byte order marks
      # NOTE: Keeping this here to educate maintainers
      # my %BOM = (
      #     "\357\273\277" => 'UTF-8',
      #     "\376\377"     => 'UTF-16BE',
      #     "\377\376"     => 'UTF-16LE',
      #     "\377\376\0\0" => 'UTF-32LE'
      #     "\0\0\376\377" => 'UTF-32BE',
      # );
      if ( $string =~ /^(?:\376\377|\377\376|\377\376\0\0|\0\0\376\377)/ ) {
        die \"Stream has a non UTF-8 BOM";
      } else {
        # Strip UTF-8 bom if found, we'll just ignore it
        $string =~ s/^\357\273\277//;
      }

      # Try to decode as utf8
      utf8::decode($string) if HAVE_UTF8;

      # Check for some special cases
      return $self unless length $string;
      unless ( $string =~ /[\012\015]+\z/ ) {
        die \"Stream does not end with newline character";
      }

      # Split the file into lines
      my @lines = grep { ! /^\s*(?:\#.*)?\z/ }
            split /(?:\015{1,2}\012|\015|\012)/, $string;

      # Strip the initial YAML header
      @lines and $lines[0] =~ /^\%YAML[: ][\d\.]+.*\z/ and shift @lines;

      # A nibbling parser
      while ( @lines ) {
        # Do we have a document header?
        if ( $lines[0] =~ /^---\s*(?:(.+)\s*)?\z/ ) {
          # Handle scalar documents
          shift @lines;
          if ( defined $1 and $1 !~ /^(?:\#.+|\%YAML[: ][\d\.]+)\z/ ) {
            push @$self, $self->_read_scalar( "$1", [ undef ], \@lines );
            next;
          }
        }

        if ( ! @lines or $lines[0] =~ /^(?:---|\.\.\.)/ ) {
          # A naked document
          push @$self, undef;
          while ( @lines and $lines[0] !~ /^---/ ) {
            shift @lines;
          }

        } elsif ( $lines[0] =~ /^\s*\-/ ) {
          # An array at the root
          my $document = [ ];
          push @$self, $document;
          $self->_read_array( $document, [ 0 ], \@lines );

        } elsif ( $lines[0] =~ /^(\s*)\S/ ) {
          # A hash at the root
          my $document = { };
          push @$self, $document;
          $self->_read_hash( $document, [ length($1) ], \@lines );

        } else {
          die \"CPAN::Meta::YAML failed to classify the line '$lines[0]'";
        }
      }
    };
    if ( ref $@ eq 'SCALAR' ) {
      return $self->_error(${$@});
    } elsif ( $@ ) {
      require Carp;
      Carp::croak($@);
    }

    return $self;
  }

  # Deparse a scalar string to the actual scalar
  sub _read_scalar {
    my ($self, $string, $indent, $lines) = @_;

    # Trim trailing whitespace
    $string =~ s/\s*\z//;

    # Explitic null/undef
    return undef if $string eq '~';

    # Single quote
    if ( $string =~ /^\'(.*?)\'(?:\s+\#.*)?\z/ ) {
      return '' unless defined $1;
      $string = $1;
      $string =~ s/\'\'/\'/g;
      return $string;
    }

    # Double quote.
    # The commented out form is simpler, but overloaded the Perl regex
    # engine due to recursion and backtracking problems on strings
    # larger than 32,000ish characters. Keep it for reference purposes.
    # if ( $string =~ /^\"((?:\\.|[^\"])*)\"\z/ ) {
    if ( $string =~ /^\"([^\\"]*(?:\\.[^\\"]*)*)\"(?:\s+\#.*)?\z/ ) {
      # Reusing the variable is a little ugly,
      # but avoids a new variable and a string copy.
      $string = $1;
      $string =~ s/\\"/"/g;
      $string =~ s/\\([never\\fartz]|x([0-9a-fA-F]{2}))/(length($1)>1)?pack("H2",$2):$UNESCAPES{$1}/gex;
      return $string;
    }

    # Special cases
    if ( $string =~ /^[\'\"!&]/ ) {
      die \"CPAN::Meta::YAML does not support a feature in line '$string'";
    }
    return {} if $string =~ /^{}(?:\s+\#.*)?\z/;
    return [] if $string =~ /^\[\](?:\s+\#.*)?\z/;

    # Regular unquoted string
    if ( $string !~ /^[>|]/ ) {
      if (
        $string =~ /^(?:-(?:\s|$)|[\@\%\`])/
        or
        $string =~ /:(?:\s|$)/
      ) {
        die \"CPAN::Meta::YAML found illegal characters in plain scalar: '$string'";
      }
      $string =~ s/\s+#.*\z//;
      return $string;
    }

    # Error
    die \"CPAN::Meta::YAML failed to find multi-line scalar content" unless @$lines;

    # Check the indent depth
    $lines->[0]   =~ /^(\s*)/;
    $indent->[-1] = length("$1");
    if ( defined $indent->[-2] and $indent->[-1] <= $indent->[-2] ) {
      die \"CPAN::Meta::YAML found bad indenting in line '$lines->[0]'";
    }

    # Pull the lines
    my @multiline = ();
    while ( @$lines ) {
      $lines->[0] =~ /^(\s*)/;
      last unless length($1) >= $indent->[-1];
      push @multiline, substr(shift(@$lines), length($1));
    }

    my $j = (substr($string, 0, 1) eq '>') ? ' ' : "\n";
    my $t = (substr($string, 1, 1) eq '-') ? ''  : "\n";
    return join( $j, @multiline ) . $t;
  }

  # Parse an array
  sub _read_array {
    my ($self, $array, $indent, $lines) = @_;

    while ( @$lines ) {
      # Check for a new document
      if ( $lines->[0] =~ /^(?:---|\.\.\.)/ ) {
        while ( @$lines and $lines->[0] !~ /^---/ ) {
          shift @$lines;
        }
        return 1;
      }

      # Check the indent level
      $lines->[0] =~ /^(\s*)/;
      if ( length($1) < $indent->[-1] ) {
        return 1;
      } elsif ( length($1) > $indent->[-1] ) {
        die \"CPAN::Meta::YAML found bad indenting in line '$lines->[0]'";
      }

      if ( $lines->[0] =~ /^(\s*\-\s+)[^\'\"]\S*\s*:(?:\s+|$)/ ) {
        # Inline nested hash
        my $indent2 = length("$1");
        $lines->[0] =~ s/-/ /;
        push @$array, { };
        $self->_read_hash( $array->[-1], [ @$indent, $indent2 ], $lines );

      } elsif ( $lines->[0] =~ /^\s*\-(\s*)(.+?)\s*\z/ ) {
        # Array entry with a value
        shift @$lines;
        push @$array, $self->_read_scalar( "$2", [ @$indent, undef ], $lines );

      } elsif ( $lines->[0] =~ /^\s*\-\s*\z/ ) {
        shift @$lines;
        unless ( @$lines ) {
          push @$array, undef;
          return 1;
        }
        if ( $lines->[0] =~ /^(\s*)\-/ ) {
          my $indent2 = length("$1");
          if ( $indent->[-1] == $indent2 ) {
            # Null array entry
            push @$array, undef;
          } else {
            # Naked indenter
            push @$array, [ ];
            $self->_read_array( $array->[-1], [ @$indent, $indent2 ], $lines );
          }

        } elsif ( $lines->[0] =~ /^(\s*)\S/ ) {
          push @$array, { };
          $self->_read_hash( $array->[-1], [ @$indent, length("$1") ], $lines );

        } else {
          die \"CPAN::Meta::YAML failed to classify line '$lines->[0]'";
        }

      } elsif ( defined $indent->[-2] and $indent->[-1] == $indent->[-2] ) {
        # This is probably a structure like the following...
        # ---
        # foo:
        # - list
        # bar: value
        #
        # ... so lets return and let the hash parser handle it
        return 1;

      } else {
        die \"CPAN::Meta::YAML failed to classify line '$lines->[0]'";
      }
    }

    return 1;
  }

  # Parse an array
  sub _read_hash {
    my ($self, $hash, $indent, $lines) = @_;

    while ( @$lines ) {
      # Check for a new document
      if ( $lines->[0] =~ /^(?:---|\.\.\.)/ ) {
        while ( @$lines and $lines->[0] !~ /^---/ ) {
          shift @$lines;
        }
        return 1;
      }

      # Check the indent level
      $lines->[0] =~ /^(\s*)/;
      if ( length($1) < $indent->[-1] ) {
        return 1;
      } elsif ( length($1) > $indent->[-1] ) {
        die \"CPAN::Meta::YAML found bad indenting in line '$lines->[0]'";
      }

      # Get the key
      unless ( $lines->[0] =~ s/^\s*([^\'\" ][^\n]*?)\s*:(\s+(?:\#.*)?|$)// ) {
        if ( $lines->[0] =~ /^\s*[?\'\"]/ ) {
          die \"CPAN::Meta::YAML does not support a feature in line '$lines->[0]'";
        }
        die \"CPAN::Meta::YAML failed to classify line '$lines->[0]'";
      }
      my $key = $1;

      # Do we have a value?
      if ( length $lines->[0] ) {
        # Yes
        $hash->{$key} = $self->_read_scalar( shift(@$lines), [ @$indent, undef ], $lines );
      } else {
        # An indent
        shift @$lines;
        unless ( @$lines ) {
          $hash->{$key} = undef;
          return 1;
        }
        if ( $lines->[0] =~ /^(\s*)-/ ) {
          $hash->{$key} = [];
          $self->_read_array( $hash->{$key}, [ @$indent, length($1) ], $lines );
        } elsif ( $lines->[0] =~ /^(\s*)./ ) {
          my $indent2 = length("$1");
          if ( $indent->[-1] >= $indent2 ) {
            # Null hash entry
            $hash->{$key} = undef;
          } else {
            $hash->{$key} = {};
            $self->_read_hash( $hash->{$key}, [ @$indent, length($1) ], $lines );
          }
        }
      }
    }

    return 1;
  }

  # Save an object to a file
  sub write {
    my $self = shift;
    my $file = shift or return $self->_error('No file name provided');

    # Write it to the file
    open( CFG, '>' . $file ) or return $self->_error(
      "Failed to open file '$file' for writing: $!"
      );
    print CFG $self->write_string;
    close CFG;

    return 1;
  }

  # Save an object to a string
  sub write_string {
    my $self = shift;
    return '' unless @$self;

    # Iterate over the documents
    my $indent = 0;
    my @lines  = ();
    foreach my $cursor ( @$self ) {
      push @lines, '---';

      # An empty document
      if ( ! defined $cursor ) {
        # Do nothing

      # A scalar document
      } elsif ( ! ref $cursor ) {
        $lines[-1] .= ' ' . $self->_write_scalar( $cursor, $indent );

      # A list at the root
      } elsif ( ref $cursor eq 'ARRAY' ) {
        unless ( @$cursor ) {
          $lines[-1] .= ' []';
          next;
        }
        push @lines, $self->_write_array( $cursor, $indent, {} );

      # A hash at the root
      } elsif ( ref $cursor eq 'HASH' ) {
        unless ( %$cursor ) {
          $lines[-1] .= ' {}';
          next;
        }
        push @lines, $self->_write_hash( $cursor, $indent, {} );

      } else {
        Carp::croak("Cannot serialize " . ref($cursor));
      }
    }

    join '', map { "$_\n" } @lines;
  }

  sub _write_scalar {
    my $string = $_[1];
    return '~'  unless defined $string;
    return "''" unless length  $string;
    if ( $string =~ /[\x00-\x08\x0b-\x0d\x0e-\x1f\"\'\n]/ ) {
      $string =~ s/\\/\\\\/g;
      $string =~ s/"/\\"/g;
      $string =~ s/\n/\\n/g;
      $string =~ s/([\x00-\x1f])/\\$UNPRINTABLE[ord($1)]/g;
      return qq|"$string"|;
    }
    if ( $string =~ /(?:^\W|\s)/ or $QUOTE{$string} ) {
      return "'$string'";
    }
    return $string;
  }

  sub _write_array {
    my ($self, $array, $indent, $seen) = @_;
    if ( $seen->{refaddr($array)}++ ) {
      die "CPAN::Meta::YAML does not support circular references";
    }
    my @lines  = ();
    foreach my $el ( @$array ) {
      my $line = ('  ' x $indent) . '-';
      my $type = ref $el;
      if ( ! $type ) {
        $line .= ' ' . $self->_write_scalar( $el, $indent + 1 );
        push @lines, $line;

      } elsif ( $type eq 'ARRAY' ) {
        if ( @$el ) {
          push @lines, $line;
          push @lines, $self->_write_array( $el, $indent + 1, $seen );
        } else {
          $line .= ' []';
          push @lines, $line;
        }

      } elsif ( $type eq 'HASH' ) {
        if ( keys %$el ) {
          push @lines, $line;
          push @lines, $self->_write_hash( $el, $indent + 1, $seen );
        } else {
          $line .= ' {}';
          push @lines, $line;
        }

      } else {
        die "CPAN::Meta::YAML does not support $type references";
      }
    }

    @lines;
  }

  sub _write_hash {
    my ($self, $hash, $indent, $seen) = @_;
    if ( $seen->{refaddr($hash)}++ ) {
      die "CPAN::Meta::YAML does not support circular references";
    }
    my @lines  = ();
    foreach my $name ( sort keys %$hash ) {
      my $el   = $hash->{$name};
      my $line = ('  ' x $indent) . "$name:";
      my $type = ref $el;
      if ( ! $type ) {
        $line .= ' ' . $self->_write_scalar( $el, $indent + 1 );
        push @lines, $line;

      } elsif ( $type eq 'ARRAY' ) {
        if ( @$el ) {
          push @lines, $line;
          push @lines, $self->_write_array( $el, $indent + 1, $seen );
        } else {
          $line .= ' []';
          push @lines, $line;
        }

      } elsif ( $type eq 'HASH' ) {
        if ( keys %$el ) {
          push @lines, $line;
          push @lines, $self->_write_hash( $el, $indent + 1, $seen );
        } else {
          $line .= ' {}';
          push @lines, $line;
        }

      } else {
        die "CPAN::Meta::YAML does not support $type references";
      }
    }

    @lines;
  }

  # Set error
  sub _error {
    $CPAN::Meta::YAML::errstr = $_[1];
    undef;
  }

  # Retrieve error
  sub errstr {
    $CPAN::Meta::YAML::errstr;
  }





  #####################################################################
  # YAML Compatibility

  sub Dump {
    CPAN::Meta::YAML->new(@_)->write_string;
  }

  sub Load {
    my $self = CPAN::Meta::YAML->read_string(@_);
    unless ( $self ) {
      Carp::croak("Failed to load YAML document from string");
    }
    if ( wantarray ) {
      return @$self;
    } else {
      # To match YAML.pm, return the last document
      return $self->[-1];
    }
  }

  BEGIN {
    *freeze = *Dump;
    *thaw   = *Load;
  }

  sub DumpFile {
    my $file = shift;
    CPAN::Meta::YAML->new(@_)->write($file);
  }

  sub LoadFile {
    my $self = CPAN::Meta::YAML->read($_[0]);
    unless ( $self ) {
      Carp::croak("Failed to load YAML document from '" . ($_[0] || '') . "'");
    }
    if ( wantarray ) {
      return @$self;
    } else {
      # Return only the last document to match YAML.pm,
      return $self->[-1];
    }
  }





  #####################################################################
  # Use Scalar::Util if possible, otherwise emulate it

  BEGIN {
    eval {
      require Scalar::Util;
      *refaddr = *Scalar::Util::refaddr;
    };
    eval <<'END_PERL' if $@;
  # Failed to load Scalar::Util
  sub refaddr {
    my $pkg = ref($_[0]) or return undef;
    if ( !! UNIVERSAL::can($_[0], 'can') ) {
      bless $_[0], 'Scalar::Util::Fake';
    } else {
      $pkg = undef;
    }
    "$_[0]" =~ /0x(\w+)/;
    my $i = do { local $^W; hex $1 };
    bless $_[0], $pkg if defined $pkg;
    $i;
  }
  END_PERL

  }

  1;




  __END__


  # ABSTRACT: Read and write a subset of YAML for CPAN Meta files


CPAN_META_YAML

$fatpacked{"HTTP/Tiny.pm"} = <<'HTTP_TINY';
  # vim: ts=4 sts=4 sw=4 et:
  #
  # This file is part of HTTP-Tiny
  #
  # This software is copyright (c) 2011 by Christian Hansen.
  #
  # This is free software; you can redistribute it and/or modify it under
  # the same terms as the Perl 5 programming language system itself.
  #
  package HTTP::Tiny;
  BEGIN {
    $HTTP::Tiny::VERSION = '0.009';
  }
  use strict;
  use warnings;
  # ABSTRACT: A small, simple, correct HTTP/1.1 client

  use Carp ();


  my @attributes;
  BEGIN {
      @attributes = qw(agent default_headers max_redirect max_size proxy timeout);
      no strict 'refs';
      for my $accessor ( @attributes ) {
          *{$accessor} = sub {
              @_ > 1 ? $_[0]->{$accessor} = $_[1] : $_[0]->{$accessor};
          };
      }
  }

  sub new {
      my($class, %args) = @_;
      (my $agent = $class) =~ s{::}{-}g;
      my $self = {
          agent        => $agent . "/" . ($class->VERSION || 0),
          max_redirect => 5,
          timeout      => 60,
      };
      for my $key ( @attributes ) {
          $self->{$key} = $args{$key} if exists $args{$key}
      }
      return bless $self, $class;
  }


  sub get {
      my ($self, $url, $args) = @_;
      @_ == 2 || (@_ == 3 && ref $args eq 'HASH')
        or Carp::croak(q/Usage: $http->get(URL, [HASHREF])/);
      return $self->request('GET', $url, $args || {});
  }


  sub mirror {
      my ($self, $url, $file, $args) = @_;
      @_ == 3 || (@_ == 4 && ref $args eq 'HASH')
        or Carp::croak(q/Usage: $http->mirror(URL, FILE, [HASHREF])/);
      if ( -e $file and my $mtime = (stat($file))[9] ) {
          $args->{headers}{'if-modified-since'} ||= $self->_http_date($mtime);
      }
      my $tempfile = $file . int(rand(2**31));
      open my $fh, ">", $tempfile
          or Carp::croak(qq/Error: Could not open temporary file $tempfile for downloading: $!/);
      $args->{data_callback} = sub { print {$fh} $_[0] };
      my $response = $self->request('GET', $url, $args);
      close $fh
          or Carp::croak(qq/Error: Could not close temporary file $tempfile: $!/);
      if ( $response->{success} ) {
          rename $tempfile, $file
              or Carp::croak "Error replacing $file with $tempfile: $!\n";
          my $lm = $response->{headers}{'last-modified'};
          if ( $lm and my $mtime = $self->_parse_http_date($lm) ) {
              utime $mtime, $mtime, $file;
          }
      }
      $response->{success} ||= $response->{status} eq '304';
      unlink $tempfile;
      return $response;
  }


  my %idempotent = map { $_ => 1 } qw/GET HEAD PUT DELETE OPTIONS TRACE/;

  sub request {
      my ($self, $method, $url, $args) = @_;
      @_ == 3 || (@_ == 4 && ref $args eq 'HASH')
        or Carp::croak(q/Usage: $http->request(METHOD, URL, [HASHREF])/);
      $args ||= {}; # we keep some state in this during _request

      # RFC 2616 Section 8.1.4 mandates a single retry on broken socket
      my $response;
      for ( 0 .. 1 ) {
          $response = eval { $self->_request($method, $url, $args) };
          last unless $@ && $idempotent{$method}
              && $@ =~ m{^(?:Socket closed|Unexpected end)};
      }

      if (my $e = "$@") {
          $response = {
              success => q{},
              status  => 599,
              reason  => 'Internal Exception',
              content => $e,
              headers => {
                  'content-type'   => 'text/plain',
                  'content-length' => length $e,
              }
          };
      }
      return $response;
  }

  my %DefaultPort = (
      http => 80,
      https => 443,
  );

  sub _request {
      my ($self, $method, $url, $args) = @_;

      my ($scheme, $host, $port, $path_query) = $self->_split_url($url);

      my $request = {
          method    => $method,
          scheme    => $scheme,
          host_port => ($port == $DefaultPort{$scheme} ? $host : "$host:$port"),
          uri       => $path_query,
          headers   => {},
      };

      my $handle  = HTTP::Tiny::Handle->new(timeout => $self->{timeout});

      if ($self->{proxy}) {
          $request->{uri} = "$scheme://$request->{host_port}$path_query";
          croak(qq/HTTPS via proxy is not supported/)
              if $request->{scheme} eq 'https';
          $handle->connect(($self->_split_url($self->{proxy}))[0..2]);
      }
      else {
          $handle->connect($scheme, $host, $port);
      }

      $self->_prepare_headers_and_cb($request, $args);
      $handle->write_request($request);

      my $response;
      do { $response = $handle->read_response_header }
          until (substr($response->{status},0,1) ne '1');

      if ( my @redir_args = $self->_maybe_redirect($request, $response, $args) ) {
          $handle->close;
          return $self->_request(@redir_args, $args);
      }

      if ($method eq 'HEAD' || $response->{status} =~ /^[23]04/) {
          # response has no message body
      }
      else {
          my $data_cb = $self->_prepare_data_cb($response, $args);
          $handle->read_body($data_cb, $response);
      }

      $handle->close;
      $response->{success} = substr($response->{status},0,1) eq '2';
      return $response;
  }

  sub _prepare_headers_and_cb {
      my ($self, $request, $args) = @_;

      for ($self->{default_headers}, $args->{headers}) {
          next unless defined;
          while (my ($k, $v) = each %$_) {
              $request->{headers}{lc $k} = $v;
          }
      }
      $request->{headers}{'host'}         = $request->{host_port};
      $request->{headers}{'connection'}   = "close";
      $request->{headers}{'user-agent'} ||= $self->{agent};

      if (defined $args->{content}) {
          $request->{headers}{'content-type'} ||= "application/octet-stream";
          if (ref $args->{content} eq 'CODE') {
              $request->{headers}{'transfer-encoding'} = 'chunked'
                unless $request->{headers}{'content-length'}
                    || $request->{headers}{'transfer-encoding'};
              $request->{cb} = $args->{content};
          }
          else {
              my $content = $args->{content};
              if ( $] ge '5.008' ) {
                  utf8::downgrade($content, 1)
                      or Carp::croak(q/Wide character in request message body/);
              }
              $request->{headers}{'content-length'} = length $content
                unless $request->{headers}{'content-length'}
                    || $request->{headers}{'transfer-encoding'};
              $request->{cb} = sub { substr $content, 0, length $content, '' };
          }
          $request->{trailer_cb} = $args->{trailer_callback}
              if ref $args->{trailer_callback} eq 'CODE';
      }
      return;
  }

  sub _prepare_data_cb {
      my ($self, $response, $args) = @_;
      my $data_cb = $args->{data_callback};
      $response->{content} = '';

      if (!$data_cb || $response->{status} !~ /^2/) {
          if (defined $self->{max_size}) {
              $data_cb = sub {
                  $_[1]->{content} .= $_[0];
                  die(qq/Size of response body exceeds the maximum allowed of $self->{max_size}\n/)
                    if length $_[1]->{content} > $self->{max_size};
              };
          }
          else {
              $data_cb = sub { $_[1]->{content} .= $_[0] };
          }
      }
      return $data_cb;
  }

  sub _maybe_redirect {
      my ($self, $request, $response, $args) = @_;
      my $headers = $response->{headers};
      my ($status, $method) = ($response->{status}, $request->{method});
      if (($status eq '303' or ($status =~ /^30[127]/ && $method =~ /^GET|HEAD$/))
          and $headers->{location}
          and ++$args->{redirects} <= $self->{max_redirect}
      ) {
          my $location = ($headers->{location} =~ /^\//)
              ? "$request->{scheme}://$request->{host_port}$headers->{location}"
              : $headers->{location} ;
          return (($status eq '303' ? 'GET' : $method), $location);
      }
      return;
  }

  sub _split_url {
      my $url = pop;

      # URI regex adapted from the URI module
      my ($scheme, $authority, $path_query) = $url =~ m<\A([^:/?#]+)://([^/?#]*)([^#]*)>
        or Carp::croak(qq/Cannot parse URL: '$url'/);

      $scheme     = lc $scheme;
      $path_query = "/$path_query" unless $path_query =~ m<\A/>;

      my $host = (length($authority)) ? lc $authority : 'localhost';
         $host =~ s/\A[^@]*@//;   # userinfo
      my $port = do {
         $host =~ s/:([0-9]*)\z// && length $1
           ? $1
           : ($scheme eq 'http' ? 80 : $scheme eq 'https' ? 443 : undef);
      };

      return ($scheme, $host, $port, $path_query);
  }

  # Date conversions adapted from HTTP::Date
  my $DoW = "Sun|Mon|Tue|Wed|Thu|Fri|Sat";
  my $MoY = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec";
  sub _http_date {
      my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime($_[1]);
      return sprintf("%s, %02d %s %04d %02d:%02d:%02d GMT",
          substr($DoW,$wday*4,3),
          $mday, substr($MoY,$mon*4,3), $year+1900,
          $hour, $min, $sec
      );
  }

  sub _parse_http_date {
      my ($self, $str) = @_;
      require Time::Local;
      my @tl_parts;
      if ($str =~ /^[SMTWF][a-z]+, +(\d{1,2}) ($MoY) +(\d\d\d\d) +(\d\d):(\d\d):(\d\d) +GMT$/) {
          @tl_parts = ($6, $5, $4, $1, (index($MoY,$2)/4), $3);
      }
      elsif ($str =~ /^[SMTWF][a-z]+, +(\d\d)-($MoY)-(\d{2,4}) +(\d\d):(\d\d):(\d\d) +GMT$/ ) {
          @tl_parts = ($6, $5, $4, $1, (index($MoY,$2)/4), $3);
      }
      elsif ($str =~ /^[SMTWF][a-z]+ +($MoY) +(\d{1,2}) +(\d\d):(\d\d):(\d\d) +(?:[^0-9]+ +)?(\d\d\d\d)$/ ) {
          @tl_parts = ($5, $4, $3, $2, (index($MoY,$1)/4), $6);
      }
      return eval {
          my $t = @tl_parts ? Time::Local::timegm(@tl_parts) : -1;
          $t < 0 ? undef : $t;
      };
  }

  package
      HTTP::Tiny::Handle; # hide from PAUSE/indexers
  use strict;
  use warnings;

  use Carp       qw[croak];
  use Errno      qw[EINTR EPIPE];
  use IO::Socket qw[SOCK_STREAM];

  sub BUFSIZE () { 32768 }

  my $Printable = sub {
      local $_ = shift;
      s/\r/\\r/g;
      s/\n/\\n/g;
      s/\t/\\t/g;
      s/([^\x20-\x7E])/sprintf('\\x%.2X', ord($1))/ge;
      $_;
  };

  my $Token = qr/[\x21\x23-\x27\x2A\x2B\x2D\x2E\x30-\x39\x41-\x5A\x5E-\x7A\x7C\x7E]/;

  sub new {
      my ($class, %args) = @_;
      return bless {
          rbuf             => '',
          timeout          => 60,
          max_line_size    => 16384,
          max_header_lines => 64,
          %args
      }, $class;
  }

  my $ssl_verify_args = {
      check_cn => "when_only",
      wildcards_in_alt => "anywhere",
      wildcards_in_cn => "anywhere"
  };

  sub connect {
      @_ == 4 || croak(q/Usage: $handle->connect(scheme, host, port)/);
      my ($self, $scheme, $host, $port) = @_;

      if ( $scheme eq 'https' ) {
          eval "require IO::Socket::SSL"
              unless exists $INC{'IO/Socket/SSL.pm'};
          croak(qq/IO::Socket::SSL must be installed for https support\n/)
              unless $INC{'IO/Socket/SSL.pm'};
      }
      elsif ( $scheme ne 'http' ) {
        croak(qq/Unsupported URL scheme '$scheme'/);
      }

      $self->{fh} = 'IO::Socket::INET'->new(
          PeerHost  => $host,
          PeerPort  => $port,
          Proto     => 'tcp',
          Type      => SOCK_STREAM,
          Timeout   => $self->{timeout}
      ) or croak(qq/Could not connect to '$host:$port': $@/);

      binmode($self->{fh})
        or croak(qq/Could not binmode() socket: '$!'/);

      if ( $scheme eq 'https') {
          IO::Socket::SSL->start_SSL($self->{fh});
          ref($self->{fh}) eq 'IO::Socket::SSL'
              or die(qq/SSL connection failed for $host\n/);
          $self->{fh}->verify_hostname( $host, $ssl_verify_args )
              or die(qq/SSL certificate not valid for $host\n/);
      }

      $self->{host} = $host;
      $self->{port} = $port;

      return $self;
  }

  sub close {
      @_ == 1 || croak(q/Usage: $handle->close()/);
      my ($self) = @_;
      CORE::close($self->{fh})
        or croak(qq/Could not close socket: '$!'/);
  }

  sub write {
      @_ == 2 || croak(q/Usage: $handle->write(buf)/);
      my ($self, $buf) = @_;

      if ( $] ge '5.008' ) {
          utf8::downgrade($buf, 1)
              or croak(q/Wide character in write()/);
      }

      my $len = length $buf;
      my $off = 0;

      local $SIG{PIPE} = 'IGNORE';

      while () {
          $self->can_write
            or croak(q/Timed out while waiting for socket to become ready for writing/);
          my $r = syswrite($self->{fh}, $buf, $len, $off);
          if (defined $r) {
              $len -= $r;
              $off += $r;
              last unless $len > 0;
          }
          elsif ($! == EPIPE) {
              croak(qq/Socket closed by remote server: $!/);
          }
          elsif ($! != EINTR) {
              croak(qq/Could not write to socket: '$!'/);
          }
      }
      return $off;
  }

  sub read {
      @_ == 2 || @_ == 3 || croak(q/Usage: $handle->read(len [, allow_partial])/);
      my ($self, $len, $allow_partial) = @_;

      my $buf  = '';
      my $got = length $self->{rbuf};

      if ($got) {
          my $take = ($got < $len) ? $got : $len;
          $buf  = substr($self->{rbuf}, 0, $take, '');
          $len -= $take;
      }

      while ($len > 0) {
          $self->can_read
            or croak(q/Timed out while waiting for socket to become ready for reading/);
          my $r = sysread($self->{fh}, $buf, $len, length $buf);
          if (defined $r) {
              last unless $r;
              $len -= $r;
          }
          elsif ($! != EINTR) {
              croak(qq/Could not read from socket: '$!'/);
          }
      }
      if ($len && !$allow_partial) {
          croak(q/Unexpected end of stream/);
      }
      return $buf;
  }

  sub readline {
      @_ == 1 || croak(q/Usage: $handle->readline()/);
      my ($self) = @_;

      while () {
          if ($self->{rbuf} =~ s/\A ([^\x0D\x0A]* \x0D?\x0A)//x) {
              return $1;
          }
          if (length $self->{rbuf} >= $self->{max_line_size}) {
              croak(qq/Line size exceeds the maximum allowed size of $self->{max_line_size}/);
          }
          $self->can_read
            or croak(q/Timed out while waiting for socket to become ready for reading/);
          my $r = sysread($self->{fh}, $self->{rbuf}, BUFSIZE, length $self->{rbuf});
          if (defined $r) {
              last unless $r;
          }
          elsif ($! != EINTR) {
              croak(qq/Could not read from socket: '$!'/);
          }
      }
      croak(q/Unexpected end of stream while looking for line/);
  }

  sub read_header_lines {
      @_ == 1 || @_ == 2 || croak(q/Usage: $handle->read_header_lines([headers])/);
      my ($self, $headers) = @_;
      $headers ||= {};
      my $lines   = 0;
      my $val;

      while () {
           my $line = $self->readline;

           if (++$lines >= $self->{max_header_lines}) {
               croak(qq/Header lines exceeds maximum number allowed of $self->{max_header_lines}/);
           }
           elsif ($line =~ /\A ([^\x00-\x1F\x7F:]+) : [\x09\x20]* ([^\x0D\x0A]*)/x) {
               my ($field_name) = lc $1;
               if (exists $headers->{$field_name}) {
                   for ($headers->{$field_name}) {
                       $_ = [$_] unless ref $_ eq "ARRAY";
                       push @$_, $2;
                       $val = \$_->[-1];
                   }
               }
               else {
                   $val = \($headers->{$field_name} = $2);
               }
           }
           elsif ($line =~ /\A [\x09\x20]+ ([^\x0D\x0A]*)/x) {
               $val
                 or croak(q/Unexpected header continuation line/);
               next unless length $1;
               $$val .= ' ' if length $$val;
               $$val .= $1;
           }
           elsif ($line =~ /\A \x0D?\x0A \z/x) {
              last;
           }
           else {
              croak(q/Malformed header line: / . $Printable->($line));
           }
      }
      return $headers;
  }

  sub write_request {
      @_ == 2 || croak(q/Usage: $handle->write_request(request)/);
      my($self, $request) = @_;
      $self->write_request_header(@{$request}{qw/method uri headers/});
      $self->write_body($request) if $request->{cb};
      return;
  }

  my %HeaderCase = (
      'content-md5'      => 'Content-MD5',
      'etag'             => 'ETag',
      'te'               => 'TE',
      'www-authenticate' => 'WWW-Authenticate',
      'x-xss-protection' => 'X-XSS-Protection',
  );

  sub write_header_lines {
      (@_ == 2 && ref $_[1] eq 'HASH') || croak(q/Usage: $handle->write_header_lines(headers)/);
      my($self, $headers) = @_;

      my $buf = '';
      while (my ($k, $v) = each %$headers) {
          my $field_name = lc $k;
          if (exists $HeaderCase{$field_name}) {
              $field_name = $HeaderCase{$field_name};
          }
          else {
              $field_name =~ /\A $Token+ \z/xo
                or croak(q/Invalid HTTP header field name: / . $Printable->($field_name));
              $field_name =~ s/\b(\w)/\u$1/g;
              $HeaderCase{lc $field_name} = $field_name;
          }
          for (ref $v eq 'ARRAY' ? @$v : $v) {
              /[^\x0D\x0A]/
                or croak(qq/Invalid HTTP header field value ($field_name): / . $Printable->($_));
              $buf .= "$field_name: $_\x0D\x0A";
          }
      }
      $buf .= "\x0D\x0A";
      return $self->write($buf);
  }

  sub read_body {
      @_ == 3 || croak(q/Usage: $handle->read_body(callback, response)/);
      my ($self, $cb, $response) = @_;
      my $te = $response->{headers}{'transfer-encoding'} || '';
      if ( grep { /chunked/i } ( ref $te eq 'ARRAY' ? @$te : $te ) ) {
          $self->read_chunked_body($cb, $response);
      }
      else {
          $self->read_content_body($cb, $response);
      }
      return;
  }

  sub write_body {
      @_ == 2 || croak(q/Usage: $handle->write_body(request)/);
      my ($self, $request) = @_;
      if ($request->{headers}{'content-length'}) {
          return $self->write_content_body($request);
      }
      else {
          return $self->write_chunked_body($request);
      }
  }

  sub read_content_body {
      @_ == 3 || @_ == 4 || croak(q/Usage: $handle->read_content_body(callback, response, [read_length])/);
      my ($self, $cb, $response, $content_length) = @_;
      $content_length ||= $response->{headers}{'content-length'};

      if ( $content_length ) {
          my $len = $content_length;
          while ($len > 0) {
              my $read = ($len > BUFSIZE) ? BUFSIZE : $len;
              $cb->($self->read($read, 0), $response);
              $len -= $read;
          }
      }
      else {
          my $chunk;
          $cb->($chunk, $response) while length( $chunk = $self->read(BUFSIZE, 1) );
      }

      return;
  }

  sub write_content_body {
      @_ == 2 || croak(q/Usage: $handle->write_content_body(request)/);
      my ($self, $request) = @_;

      my ($len, $content_length) = (0, $request->{headers}{'content-length'});
      while () {
          my $data = $request->{cb}->();

          defined $data && length $data
            or last;

          if ( $] ge '5.008' ) {
              utf8::downgrade($data, 1)
                  or croak(q/Wide character in write_content()/);
          }

          $len += $self->write($data);
      }

      $len == $content_length
        or croak(qq/Content-Length missmatch (got: $len expected: $content_length)/);

      return $len;
  }

  sub read_chunked_body {
      @_ == 3 || croak(q/Usage: $handle->read_chunked_body(callback, $response)/);
      my ($self, $cb, $response) = @_;

      while () {
          my $head = $self->readline;

          $head =~ /\A ([A-Fa-f0-9]+)/x
            or croak(q/Malformed chunk head: / . $Printable->($head));

          my $len = hex($1)
            or last;

          $self->read_content_body($cb, $response, $len);

          $self->read(2) eq "\x0D\x0A"
            or croak(q/Malformed chunk: missing CRLF after chunk data/);
      }
      $self->read_header_lines($response->{headers});
      return;
  }

  sub write_chunked_body {
      @_ == 2 || croak(q/Usage: $handle->write_chunked_body(request)/);
      my ($self, $request) = @_;

      my $len = 0;
      while () {
          my $data = $request->{cb}->();

          defined $data && length $data
            or last;

          if ( $] ge '5.008' ) {
              utf8::downgrade($data, 1)
                  or croak(q/Wide character in write_chunked_body()/);
          }

          $len += length $data;

          my $chunk  = sprintf '%X', length $data;
             $chunk .= "\x0D\x0A";
             $chunk .= $data;
             $chunk .= "\x0D\x0A";

          $self->write($chunk);
      }
      $self->write("0\x0D\x0A");
      $self->write_header_lines($request->{trailer_cb}->())
          if ref $request->{trailer_cb} eq 'CODE';
      return $len;
  }

  sub read_response_header {
      @_ == 1 || croak(q/Usage: $handle->read_response_header()/);
      my ($self) = @_;

      my $line = $self->readline;

      $line =~ /\A (HTTP\/(0*\d+\.0*\d+)) [\x09\x20]+ ([0-9]{3}) [\x09\x20]+ ([^\x0D\x0A]*) \x0D?\x0A/x
        or croak(q/Malformed Status-Line: / . $Printable->($line));

      my ($protocol, $version, $status, $reason) = ($1, $2, $3, $4);

      croak (qq/Unsupported HTTP protocol: $protocol/)
          unless $version =~ /0*1\.0*[01]/;

      return {
          status   => $status,
          reason   => $reason,
          headers  => $self->read_header_lines,
          protocol => $protocol,
      };
  }

  sub write_request_header {
      @_ == 4 || croak(q/Usage: $handle->write_request_header(method, request_uri, headers)/);
      my ($self, $method, $request_uri, $headers) = @_;

      return $self->write("$method $request_uri HTTP/1.1\x0D\x0A")
           + $self->write_header_lines($headers);
  }

  sub _do_timeout {
      my ($self, $type, $timeout) = @_;
      $timeout = $self->{timeout}
          unless defined $timeout && $timeout >= 0;

      my $fd = fileno $self->{fh};
      defined $fd && $fd >= 0
        or croak(q/select(2): 'Bad file descriptor'/);

      my $initial = time;
      my $pending = $timeout;
      my $nfound;

      vec(my $fdset = '', $fd, 1) = 1;

      while () {
          $nfound = ($type eq 'read')
              ? select($fdset, undef, undef, $pending)
              : select(undef, $fdset, undef, $pending) ;
          if ($nfound == -1) {
              $! == EINTR
                or croak(qq/select(2): '$!'/);
              redo if !$timeout || ($pending = $timeout - (time - $initial)) > 0;
              $nfound = 0;
          }
          last;
      }
      $! = 0;
      return $nfound;
  }

  sub can_read {
      @_ == 1 || @_ == 2 || croak(q/Usage: $handle->can_read([timeout])/);
      my $self = shift;
      return $self->_do_timeout('read', @_)
  }

  sub can_write {
      @_ == 1 || @_ == 2 || croak(q/Usage: $handle->can_write([timeout])/);
      my $self = shift;
      return $self->_do_timeout('write', @_)
  }

  1;



  __END__
  =pod

HTTP_TINY

$fatpacked{"JSON/PP.pm"} = <<'JSON_PP';
  package JSON::PP;

  # JSON-2.0

  use 5.005;
  use strict;
  use base qw(Exporter);
  use overload ();

  use Carp ();
  use B ();
  #use Devel::Peek;

  $JSON::PP::VERSION = '2.27200';

  @JSON::PP::EXPORT = qw(encode_json decode_json from_json to_json);

  # instead of hash-access, i tried index-access for speed.
  # but this method is not faster than what i expected. so it will be changed.

  use constant P_ASCII                => 0;
  use constant P_LATIN1               => 1;
  use constant P_UTF8                 => 2;
  use constant P_INDENT               => 3;
  use constant P_CANONICAL            => 4;
  use constant P_SPACE_BEFORE         => 5;
  use constant P_SPACE_AFTER          => 6;
  use constant P_ALLOW_NONREF         => 7;
  use constant P_SHRINK               => 8;
  use constant P_ALLOW_BLESSED        => 9;
  use constant P_CONVERT_BLESSED      => 10;
  use constant P_RELAXED              => 11;

  use constant P_LOOSE                => 12;
  use constant P_ALLOW_BIGNUM         => 13;
  use constant P_ALLOW_BAREKEY        => 14;
  use constant P_ALLOW_SINGLEQUOTE    => 15;
  use constant P_ESCAPE_SLASH         => 16;
  use constant P_AS_NONBLESSED        => 17;

  use constant P_ALLOW_UNKNOWN        => 18;

  use constant OLD_PERL => $] < 5.008 ? 1 : 0;

  BEGIN {
      my @xs_compati_bit_properties = qw(
              latin1 ascii utf8 indent canonical space_before space_after allow_nonref shrink
              allow_blessed convert_blessed relaxed allow_unknown
      );
      my @pp_bit_properties = qw(
              allow_singlequote allow_bignum loose
              allow_barekey escape_slash as_nonblessed
      );

      # Perl version check, Unicode handling is enable?
      # Helper module sets @JSON::PP::_properties.
      if ($] < 5.008 ) {
          my $helper = $] >= 5.006 ? 'JSON::PP::Compat5006' : 'JSON::PP::Compat5005';
          eval qq| require $helper |;
          if ($@) { Carp::croak $@; }
      }

      for my $name (@xs_compati_bit_properties, @pp_bit_properties) {
          my $flag_name = 'P_' . uc($name);

          eval qq/
              sub $name {
                  my \$enable = defined \$_[1] ? \$_[1] : 1;

                  if (\$enable) {
                      \$_[0]->{PROPS}->[$flag_name] = 1;
                  }
                  else {
                      \$_[0]->{PROPS}->[$flag_name] = 0;
                  }

                  \$_[0];
              }

              sub get_$name {
                  \$_[0]->{PROPS}->[$flag_name] ? 1 : '';
              }
          /;
      }

  }



  # Functions

  my %encode_allow_method
       = map {($_ => 1)} qw/utf8 pretty allow_nonref latin1 self_encode escape_slash
                            allow_blessed convert_blessed indent indent_length allow_bignum
                            as_nonblessed
                          /;
  my %decode_allow_method
       = map {($_ => 1)} qw/utf8 allow_nonref loose allow_singlequote allow_bignum
                            allow_barekey max_size relaxed/;


  my $JSON; # cache

  sub encode_json ($) { # encode
      ($JSON ||= __PACKAGE__->new->utf8)->encode(@_);
  }


  sub decode_json { # decode
      ($JSON ||= __PACKAGE__->new->utf8)->decode(@_);
  }

  # Obsoleted

  sub to_json($) {
     Carp::croak ("JSON::PP::to_json has been renamed to encode_json.");
  }


  sub from_json($) {
     Carp::croak ("JSON::PP::from_json has been renamed to decode_json.");
  }


  # Methods

  sub new {
      my $class = shift;
      my $self  = {
          max_depth   => 512,
          max_size    => 0,
          indent      => 0,
          FLAGS       => 0,
          fallback      => sub { encode_error('Invalid value. JSON can only reference.') },
          indent_length => 3,
      };

      bless $self, $class;
  }


  sub encode {
      return $_[0]->PP_encode_json($_[1]);
  }


  sub decode {
      return $_[0]->PP_decode_json($_[1], 0x00000000);
  }


  sub decode_prefix {
      return $_[0]->PP_decode_json($_[1], 0x00000001);
  }


  # accessor


  # pretty printing

  sub pretty {
      my ($self, $v) = @_;
      my $enable = defined $v ? $v : 1;

      if ($enable) { # indent_length(3) for JSON::XS compatibility
          $self->indent(1)->indent_length(3)->space_before(1)->space_after(1);
      }
      else {
          $self->indent(0)->space_before(0)->space_after(0);
      }

      $self;
  }

  # etc

  sub max_depth {
      my $max  = defined $_[1] ? $_[1] : 0x80000000;
      $_[0]->{max_depth} = $max;
      $_[0];
  }


  sub get_max_depth { $_[0]->{max_depth}; }


  sub max_size {
      my $max  = defined $_[1] ? $_[1] : 0;
      $_[0]->{max_size} = $max;
      $_[0];
  }


  sub get_max_size { $_[0]->{max_size}; }


  sub filter_json_object {
      $_[0]->{cb_object} = defined $_[1] ? $_[1] : 0;
      $_[0]->{F_HOOK} = ($_[0]->{cb_object} or $_[0]->{cb_sk_object}) ? 1 : 0;
      $_[0];
  }

  sub filter_json_single_key_object {
      if (@_ > 1) {
          $_[0]->{cb_sk_object}->{$_[1]} = $_[2];
      }
      $_[0]->{F_HOOK} = ($_[0]->{cb_object} or $_[0]->{cb_sk_object}) ? 1 : 0;
      $_[0];
  }

  sub indent_length {
      if (!defined $_[1] or $_[1] > 15 or $_[1] < 0) {
          Carp::carp "The acceptable range of indent_length() is 0 to 15.";
      }
      else {
          $_[0]->{indent_length} = $_[1];
      }
      $_[0];
  }

  sub get_indent_length {
      $_[0]->{indent_length};
  }

  sub sort_by {
      $_[0]->{sort_by} = defined $_[1] ? $_[1] : 1;
      $_[0];
  }

  sub allow_bigint {
      Carp::carp("allow_bigint() is obsoleted. use allow_bignum() insted.");
  }

  ###############################

  ###
  ### Perl => JSON
  ###


  { # Convert

      my $max_depth;
      my $indent;
      my $ascii;
      my $latin1;
      my $utf8;
      my $space_before;
      my $space_after;
      my $canonical;
      my $allow_blessed;
      my $convert_blessed;

      my $indent_length;
      my $escape_slash;
      my $bignum;
      my $as_nonblessed;

      my $depth;
      my $indent_count;
      my $keysort;


      sub PP_encode_json {
          my $self = shift;
          my $obj  = shift;

          $indent_count = 0;
          $depth        = 0;

          my $idx = $self->{PROPS};

          ($ascii, $latin1, $utf8, $indent, $canonical, $space_before, $space_after, $allow_blessed,
              $convert_blessed, $escape_slash, $bignum, $as_nonblessed)
           = @{$idx}[P_ASCII .. P_SPACE_AFTER, P_ALLOW_BLESSED, P_CONVERT_BLESSED,
                      P_ESCAPE_SLASH, P_ALLOW_BIGNUM, P_AS_NONBLESSED];

          ($max_depth, $indent_length) = @{$self}{qw/max_depth indent_length/};

          $keysort = $canonical ? sub { $a cmp $b } : undef;

          if ($self->{sort_by}) {
              $keysort = ref($self->{sort_by}) eq 'CODE' ? $self->{sort_by}
                       : $self->{sort_by} =~ /\D+/       ? $self->{sort_by}
                       : sub { $a cmp $b };
          }

          encode_error("hash- or arrayref expected (not a simple scalar, use allow_nonref to allow this)")
               if(!ref $obj and !$idx->[ P_ALLOW_NONREF ]);

          my $str  = $self->object_to_json($obj);

          $str .= "\n" if ( $indent ); # JSON::XS 2.26 compatible

          unless ($ascii or $latin1 or $utf8) {
              utf8::upgrade($str);
          }

          if ($idx->[ P_SHRINK ]) {
              utf8::downgrade($str, 1);
          }

          return $str;
      }


      sub object_to_json {
          my ($self, $obj) = @_;
          my $type = ref($obj);

          if($type eq 'HASH'){
              return $self->hash_to_json($obj);
          }
          elsif($type eq 'ARRAY'){
              return $self->array_to_json($obj);
          }
          elsif ($type) { # blessed object?
              if (blessed($obj)) {

                  return $self->value_to_json($obj) if ( $obj->isa('JSON::PP::Boolean') );

                  if ( $convert_blessed and $obj->can('TO_JSON') ) {
                      my $result = $obj->TO_JSON();
                      if ( defined $result and ref( $result ) ) {
                          if ( refaddr( $obj ) eq refaddr( $result ) ) {
                              encode_error( sprintf(
                                  "%s::TO_JSON method returned same object as was passed instead of a new one",
                                  ref $obj
                              ) );
                          }
                      }

                      return $self->object_to_json( $result );
                  }

                  return "$obj" if ( $bignum and _is_bignum($obj) );
                  return $self->blessed_to_json($obj) if ($allow_blessed and $as_nonblessed); # will be removed.

                  encode_error( sprintf("encountered object '%s', but neither allow_blessed "
                      . "nor convert_blessed settings are enabled", $obj)
                  ) unless ($allow_blessed);

                  return 'null';
              }
              else {
                  return $self->value_to_json($obj);
              }
          }
          else{
              return $self->value_to_json($obj);
          }
      }


      sub hash_to_json {
          my ($self, $obj) = @_;
          my @res;

          encode_error("json text or perl structure exceeds maximum nesting level (max_depth set too low?)")
                                           if (++$depth > $max_depth);

          my ($pre, $post) = $indent ? $self->_up_indent() : ('', '');
          my $del = ($space_before ? ' ' : '') . ':' . ($space_after ? ' ' : '');

          for my $k ( _sort( $obj ) ) {
              if ( OLD_PERL ) { utf8::decode($k) } # key for Perl 5.6 / be optimized
              push @res, string_to_json( $self, $k )
                            .  $del
                            . ( $self->object_to_json( $obj->{$k} ) || $self->value_to_json( $obj->{$k} ) );
          }

          --$depth;
          $self->_down_indent() if ($indent);

          return   '{' . ( @res ? $pre : '' ) . ( @res ? join( ",$pre", @res ) . $post : '' )  . '}';
      }


      sub array_to_json {
          my ($self, $obj) = @_;
          my @res;

          encode_error("json text or perl structure exceeds maximum nesting level (max_depth set too low?)")
                                           if (++$depth > $max_depth);

          my ($pre, $post) = $indent ? $self->_up_indent() : ('', '');

          for my $v (@$obj){
              push @res, $self->object_to_json($v) || $self->value_to_json($v);
          }

          --$depth;
          $self->_down_indent() if ($indent);

          return '[' . ( @res ? $pre : '' ) . ( @res ? join( ",$pre", @res ) . $post : '' ) . ']';
      }


      sub value_to_json {
          my ($self, $value) = @_;

          return 'null' if(!defined $value);

          my $b_obj = B::svref_2object(\$value);  # for round trip problem
          my $flags = $b_obj->FLAGS;

          return $value # as is
              if $flags & ( B::SVp_IOK | B::SVp_NOK ) and !( $flags & B::SVp_POK ); # SvTYPE is IV or NV?

          my $type = ref($value);

          if(!$type){
              return string_to_json($self, $value);
          }
          elsif( blessed($value) and  $value->isa('JSON::PP::Boolean') ){
              return $$value == 1 ? 'true' : 'false';
          }
          elsif ($type) {
              if ((overload::StrVal($value) =~ /=(\w+)/)[0]) {
                  return $self->value_to_json("$value");
              }

              if ($type eq 'SCALAR' and defined $$value) {
                  return   $$value eq '1' ? 'true'
                         : $$value eq '0' ? 'false'
                         : $self->{PROPS}->[ P_ALLOW_UNKNOWN ] ? 'null'
                         : encode_error("cannot encode reference to scalar");
              }

               if ( $self->{PROPS}->[ P_ALLOW_UNKNOWN ] ) {
                   return 'null';
               }
               else {
                   if ( $type eq 'SCALAR' or $type eq 'REF' ) {
                      encode_error("cannot encode reference to scalar");
                   }
                   else {
                      encode_error("encountered $value, but JSON can only represent references to arrays or hashes");
                   }
               }

          }
          else {
              return $self->{fallback}->($value)
                   if ($self->{fallback} and ref($self->{fallback}) eq 'CODE');
              return 'null';
          }

      }


      my %esc = (
          "\n" => '\n',
          "\r" => '\r',
          "\t" => '\t',
          "\f" => '\f',
          "\b" => '\b',
          "\"" => '\"',
          "\\" => '\\\\',
          "\'" => '\\\'',
      );


      sub string_to_json {
          my ($self, $arg) = @_;

          $arg =~ s/([\x22\x5c\n\r\t\f\b])/$esc{$1}/g;
          $arg =~ s/\//\\\//g if ($escape_slash);
          $arg =~ s/([\x00-\x08\x0b\x0e-\x1f])/'\\u00' . unpack('H2', $1)/eg;

          if ($ascii) {
              $arg = JSON_PP_encode_ascii($arg);
          }

          if ($latin1) {
              $arg = JSON_PP_encode_latin1($arg);
          }

          if ($utf8) {
              utf8::encode($arg);
          }

          return '"' . $arg . '"';
      }


      sub blessed_to_json {
          my $reftype = reftype($_[1]) || '';
          if ($reftype eq 'HASH') {
              return $_[0]->hash_to_json($_[1]);
          }
          elsif ($reftype eq 'ARRAY') {
              return $_[0]->array_to_json($_[1]);
          }
          else {
              return 'null';
          }
      }


      sub encode_error {
          my $error  = shift;
          Carp::croak "$error";
      }


      sub _sort {
          defined $keysort ? (sort $keysort (keys %{$_[0]})) : keys %{$_[0]};
      }


      sub _up_indent {
          my $self  = shift;
          my $space = ' ' x $indent_length;

          my ($pre,$post) = ('','');

          $post = "\n" . $space x $indent_count;

          $indent_count++;

          $pre = "\n" . $space x $indent_count;

          return ($pre,$post);
      }


      sub _down_indent { $indent_count--; }


      sub PP_encode_box {
          {
              depth        => $depth,
              indent_count => $indent_count,
          };
      }

  } # Convert


  sub _encode_ascii {
      join('',
          map {
              $_ <= 127 ?
                  chr($_) :
              $_ <= 65535 ?
                  sprintf('\u%04x', $_) : sprintf('\u%x\u%x', _encode_surrogates($_));
          } unpack('U*', $_[0])
      );
  }


  sub _encode_latin1 {
      join('',
          map {
              $_ <= 255 ?
                  chr($_) :
              $_ <= 65535 ?
                  sprintf('\u%04x', $_) : sprintf('\u%x\u%x', _encode_surrogates($_));
          } unpack('U*', $_[0])
      );
  }


  sub _encode_surrogates { # from perlunicode
      my $uni = $_[0] - 0x10000;
      return ($uni / 0x400 + 0xD800, $uni % 0x400 + 0xDC00);
  }


  sub _is_bignum {
      $_[0]->isa('Math::BigInt') or $_[0]->isa('Math::BigFloat');
  }



  #
  # JSON => Perl
  #

  my $max_intsize;

  BEGIN {
      my $checkint = 1111;
      for my $d (5..64) {
          $checkint .= 1;
          my $int   = eval qq| $checkint |;
          if ($int =~ /[eE]/) {
              $max_intsize = $d - 1;
              last;
          }
      }
  }

  { # PARSE

      my %escapes = ( #  by Jeremy Muhlich <jmuhlich [at] bitflood.org>
          b    => "\x8",
          t    => "\x9",
          n    => "\xA",
          f    => "\xC",
          r    => "\xD",
          '\\' => '\\',
          '"'  => '"',
          '/'  => '/',
      );

      my $text; # json data
      my $at;   # offset
      my $ch;   # 1chracter
      my $len;  # text length (changed according to UTF8 or NON UTF8)
      # INTERNAL
      my $depth;          # nest counter
      my $encoding;       # json text encoding
      my $is_valid_utf8;  # temp variable
      my $utf8_len;       # utf8 byte length
      # FLAGS
      my $utf8;           # must be utf8
      my $max_depth;      # max nest nubmer of objects and arrays
      my $max_size;
      my $relaxed;
      my $cb_object;
      my $cb_sk_object;

      my $F_HOOK;

      my $allow_bigint;   # using Math::BigInt
      my $singlequote;    # loosely quoting
      my $loose;          #
      my $allow_barekey;  # bareKey

      # $opt flag
      # 0x00000001 .... decode_prefix
      # 0x10000000 .... incr_parse

      sub PP_decode_json {
          my ($self, $opt); # $opt is an effective flag during this decode_json.

          ($self, $text, $opt) = @_;

          ($at, $ch, $depth) = (0, '', 0);

          if ( !defined $text or ref $text ) {
              decode_error("malformed JSON string, neither array, object, number, string or atom");
          }

          my $idx = $self->{PROPS};

          ($utf8, $relaxed, $loose, $allow_bigint, $allow_barekey, $singlequote)
              = @{$idx}[P_UTF8, P_RELAXED, P_LOOSE .. P_ALLOW_SINGLEQUOTE];

          if ( $utf8 ) {
              utf8::downgrade( $text, 1 ) or Carp::croak("Wide character in subroutine entry");
          }
          else {
              utf8::upgrade( $text );
          }

          $len = length $text;

          ($max_depth, $max_size, $cb_object, $cb_sk_object, $F_HOOK)
               = @{$self}{qw/max_depth  max_size cb_object cb_sk_object F_HOOK/};

          if ($max_size > 1) {
              use bytes;
              my $bytes = length $text;
              decode_error(
                  sprintf("attempted decode of JSON text of %s bytes size, but max_size is set to %s"
                      , $bytes, $max_size), 1
              ) if ($bytes > $max_size);
          }

          # Currently no effect
          # should use regexp
          my @octets = unpack('C4', $text);
          $encoding =   ( $octets[0] and  $octets[1]) ? 'UTF-8'
                      : (!$octets[0] and  $octets[1]) ? 'UTF-16BE'
                      : (!$octets[0] and !$octets[1]) ? 'UTF-32BE'
                      : ( $octets[2]                ) ? 'UTF-16LE'
                      : (!$octets[2]                ) ? 'UTF-32LE'
                      : 'unknown';

          white(); # remove head white space

          my $valid_start = defined $ch; # Is there a first character for JSON structure?

          my $result = value();

          return undef if ( !$result && ( $opt & 0x10000000 ) ); # for incr_parse

          decode_error("malformed JSON string, neither array, object, number, string or atom") unless $valid_start;

          if ( !$idx->[ P_ALLOW_NONREF ] and !ref $result ) {
                  decode_error(
                  'JSON text must be an object or array (but found number, string, true, false or null,'
                         . ' use allow_nonref to allow this)', 1);
          }

          Carp::croak('something wrong.') if $len < $at; # we won't arrive here.

          my $consumed = defined $ch ? $at - 1 : $at; # consumed JSON text length

          white(); # remove tail white space

          if ( $ch ) {
              return ( $result, $consumed ) if ($opt & 0x00000001); # all right if decode_prefix
              decode_error("garbage after JSON object");
          }

          ( $opt & 0x00000001 ) ? ( $result, $consumed ) : $result;
      }


      sub next_chr {
          return $ch = undef if($at >= $len);
          $ch = substr($text, $at++, 1);
      }


      sub value {
          white();
          return          if(!defined $ch);
          return object() if($ch eq '{');
          return array()  if($ch eq '[');
          return string() if($ch eq '"' or ($singlequote and $ch eq "'"));
          return number() if($ch =~ /[0-9]/ or $ch eq '-');
          return word();
      }

      sub string {
          my ($i, $s, $t, $u);
          my $utf16;
          my $is_utf8;

          ($is_valid_utf8, $utf8_len) = ('', 0);

          $s = ''; # basically UTF8 flag on

          if($ch eq '"' or ($singlequote and $ch eq "'")){
              my $boundChar = $ch;

              OUTER: while( defined(next_chr()) ){

                  if($ch eq $boundChar){
                      next_chr();

                      if ($utf16) {
                          decode_error("missing low surrogate character in surrogate pair");
                      }

                      utf8::decode($s) if($is_utf8);

                      return $s;
                  }
                  elsif($ch eq '\\'){
                      next_chr();
                      if(exists $escapes{$ch}){
                          $s .= $escapes{$ch};
                      }
                      elsif($ch eq 'u'){ # UNICODE handling
                          my $u = '';

                          for(1..4){
                              $ch = next_chr();
                              last OUTER if($ch !~ /[0-9a-fA-F]/);
                              $u .= $ch;
                          }

                          # U+D800 - U+DBFF
                          if ($u =~ /^[dD][89abAB][0-9a-fA-F]{2}/) { # UTF-16 high surrogate?
                              $utf16 = $u;
                          }
                          # U+DC00 - U+DFFF
                          elsif ($u =~ /^[dD][c-fC-F][0-9a-fA-F]{2}/) { # UTF-16 low surrogate?
                              unless (defined $utf16) {
                                  decode_error("missing high surrogate character in surrogate pair");
                              }
                              $is_utf8 = 1;
                              $s .= JSON_PP_decode_surrogates($utf16, $u) || next;
                              $utf16 = undef;
                          }
                          else {
                              if (defined $utf16) {
                                  decode_error("surrogate pair expected");
                              }

                              if ( ( my $hex = hex( $u ) ) > 127 ) {
                                  $is_utf8 = 1;
                                  $s .= JSON_PP_decode_unicode($u) || next;
                              }
                              else {
                                  $s .= chr $hex;
                              }
                          }

                      }
                      else{
                          unless ($loose) {
                              $at -= 2;
                              decode_error('illegal backslash escape sequence in string');
                          }
                          $s .= $ch;
                      }
                  }
                  else{

                      if ( ord $ch  > 127 ) {
                          if ( $utf8 ) {
                              unless( $ch = is_valid_utf8($ch) ) {
                                  $at -= 1;
                                  decode_error("malformed UTF-8 character in JSON string");
                              }
                              else {
                                  $at += $utf8_len - 1;
                              }
                          }
                          else {
                              utf8::encode( $ch );
                          }

                          $is_utf8 = 1;
                      }

                      if (!$loose) {
                          if ($ch =~ /[\x00-\x1f\x22\x5c]/)  { # '/' ok
                              $at--;
                              decode_error('invalid character encountered while parsing JSON string');
                          }
                      }

                      $s .= $ch;
                  }
              }
          }

          decode_error("unexpected end of string while parsing JSON string");
      }


      sub white {
          while( defined $ch  ){
              if($ch le ' '){
                  next_chr();
              }
              elsif($ch eq '/'){
                  next_chr();
                  if(defined $ch and $ch eq '/'){
                      1 while(defined(next_chr()) and $ch ne "\n" and $ch ne "\r");
                  }
                  elsif(defined $ch and $ch eq '*'){
                      next_chr();
                      while(1){
                          if(defined $ch){
                              if($ch eq '*'){
                                  if(defined(next_chr()) and $ch eq '/'){
                                      next_chr();
                                      last;
                                  }
                              }
                              else{
                                  next_chr();
                              }
                          }
                          else{
                              decode_error("Unterminated comment");
                          }
                      }
                      next;
                  }
                  else{
                      $at--;
                      decode_error("malformed JSON string, neither array, object, number, string or atom");
                  }
              }
              else{
                  if ($relaxed and $ch eq '#') { # correctly?
                      pos($text) = $at;
                      $text =~ /\G([^\n]*(?:\r\n|\r|\n|$))/g;
                      $at = pos($text);
                      next_chr;
                      next;
                  }

                  last;
              }
          }
      }


      sub array {
          my $a  = $_[0] || []; # you can use this code to use another array ref object.

          decode_error('json text or perl structure exceeds maximum nesting level (max_depth set too low?)')
                                                      if (++$depth > $max_depth);

          next_chr();
          white();

          if(defined $ch and $ch eq ']'){
              --$depth;
              next_chr();
              return $a;
          }
          else {
              while(defined($ch)){
                  push @$a, value();

                  white();

                  if (!defined $ch) {
                      last;
                  }

                  if($ch eq ']'){
                      --$depth;
                      next_chr();
                      return $a;
                  }

                  if($ch ne ','){
                      last;
                  }

                  next_chr();
                  white();

                  if ($relaxed and $ch eq ']') {
                      --$depth;
                      next_chr();
                      return $a;
                  }

              }
          }

          decode_error(", or ] expected while parsing array");
      }


      sub object {
          my $o = $_[0] || {}; # you can use this code to use another hash ref object.
          my $k;

          decode_error('json text or perl structure exceeds maximum nesting level (max_depth set too low?)')
                                                  if (++$depth > $max_depth);
          next_chr();
          white();

          if(defined $ch and $ch eq '}'){
              --$depth;
              next_chr();
              if ($F_HOOK) {
                  return _json_object_hook($o);
              }
              return $o;
          }
          else {
              while (defined $ch) {
                  $k = ($allow_barekey and $ch ne '"' and $ch ne "'") ? bareKey() : string();
                  white();

                  if(!defined $ch or $ch ne ':'){
                      $at--;
                      decode_error("':' expected");
                  }

                  next_chr();
                  $o->{$k} = value();
                  white();

                  last if (!defined $ch);

                  if($ch eq '}'){
                      --$depth;
                      next_chr();
                      if ($F_HOOK) {
                          return _json_object_hook($o);
                      }
                      return $o;
                  }

                  if($ch ne ','){
                      last;
                  }

                  next_chr();
                  white();

                  if ($relaxed and $ch eq '}') {
                      --$depth;
                      next_chr();
                      if ($F_HOOK) {
                          return _json_object_hook($o);
                      }
                      return $o;
                  }

              }

          }

          $at--;
          decode_error(", or } expected while parsing object/hash");
      }


      sub bareKey { # doesn't strictly follow Standard ECMA-262 3rd Edition
          my $key;
          while($ch =~ /[^\x00-\x23\x25-\x2F\x3A-\x40\x5B-\x5E\x60\x7B-\x7F]/){
              $key .= $ch;
              next_chr();
          }
          return $key;
      }


      sub word {
          my $word =  substr($text,$at-1,4);

          if($word eq 'true'){
              $at += 3;
              next_chr;
              return $JSON::PP::true;
          }
          elsif($word eq 'null'){
              $at += 3;
              next_chr;
              return undef;
          }
          elsif($word eq 'fals'){
              $at += 3;
              if(substr($text,$at,1) eq 'e'){
                  $at++;
                  next_chr;
                  return $JSON::PP::false;
              }
          }

          $at--; # for decode_error report

          decode_error("'null' expected")  if ($word =~ /^n/);
          decode_error("'true' expected")  if ($word =~ /^t/);
          decode_error("'false' expected") if ($word =~ /^f/);
          decode_error("malformed JSON string, neither array, object, number, string or atom");
      }


      sub number {
          my $n    = '';
          my $v;

          # According to RFC4627, hex or oct digts are invalid.
          if($ch eq '0'){
              my $peek = substr($text,$at,1);
              my $hex  = $peek =~ /[xX]/; # 0 or 1

              if($hex){
                  decode_error("malformed number (leading zero must not be followed by another digit)");
                  ($n) = ( substr($text, $at+1) =~ /^([0-9a-fA-F]+)/);
              }
              else{ # oct
                  ($n) = ( substr($text, $at) =~ /^([0-7]+)/);
                  if (defined $n and length $n > 1) {
                      decode_error("malformed number (leading zero must not be followed by another digit)");
                  }
              }

              if(defined $n and length($n)){
                  if (!$hex and length($n) == 1) {
                     decode_error("malformed number (leading zero must not be followed by another digit)");
                  }
                  $at += length($n) + $hex;
                  next_chr;
                  return $hex ? hex($n) : oct($n);
              }
          }

          if($ch eq '-'){
              $n = '-';
              next_chr;
              if (!defined $ch or $ch !~ /\d/) {
                  decode_error("malformed number (no digits after initial minus)");
              }
          }

          while(defined $ch and $ch =~ /\d/){
              $n .= $ch;
              next_chr;
          }

          if(defined $ch and $ch eq '.'){
              $n .= '.';

              next_chr;
              if (!defined $ch or $ch !~ /\d/) {
                  decode_error("malformed number (no digits after decimal point)");
              }
              else {
                  $n .= $ch;
              }

              while(defined(next_chr) and $ch =~ /\d/){
                  $n .= $ch;
              }
          }

          if(defined $ch and ($ch eq 'e' or $ch eq 'E')){
              $n .= $ch;
              next_chr;

              if(defined($ch) and ($ch eq '+' or $ch eq '-')){
                  $n .= $ch;
                  next_chr;
                  if (!defined $ch or $ch =~ /\D/) {
                      decode_error("malformed number (no digits after exp sign)");
                  }
                  $n .= $ch;
              }
              elsif(defined($ch) and $ch =~ /\d/){
                  $n .= $ch;
              }
              else {
                  decode_error("malformed number (no digits after exp sign)");
              }

              while(defined(next_chr) and $ch =~ /\d/){
                  $n .= $ch;
              }

          }

          $v .= $n;

          if ($v !~ /[.eE]/ and length $v > $max_intsize) {
              if ($allow_bigint) { # from Adam Sussman
                  require Math::BigInt;
                  return Math::BigInt->new($v);
              }
              else {
                  return "$v";
              }
          }
          elsif ($allow_bigint) {
              require Math::BigFloat;
              return Math::BigFloat->new($v);
          }

          return 0+$v;
      }


      sub is_valid_utf8 {

          $utf8_len = $_[0] =~ /[\x00-\x7F]/  ? 1
                    : $_[0] =~ /[\xC2-\xDF]/  ? 2
                    : $_[0] =~ /[\xE0-\xEF]/  ? 3
                    : $_[0] =~ /[\xF0-\xF4]/  ? 4
                    : 0
                    ;

          return unless $utf8_len;

          my $is_valid_utf8 = substr($text, $at - 1, $utf8_len);

          return ( $is_valid_utf8 =~ /^(?:
               [\x00-\x7F]
              |[\xC2-\xDF][\x80-\xBF]
              |[\xE0][\xA0-\xBF][\x80-\xBF]
              |[\xE1-\xEC][\x80-\xBF][\x80-\xBF]
              |[\xED][\x80-\x9F][\x80-\xBF]
              |[\xEE-\xEF][\x80-\xBF][\x80-\xBF]
              |[\xF0][\x90-\xBF][\x80-\xBF][\x80-\xBF]
              |[\xF1-\xF3][\x80-\xBF][\x80-\xBF][\x80-\xBF]
              |[\xF4][\x80-\x8F][\x80-\xBF][\x80-\xBF]
          )$/x )  ? $is_valid_utf8 : '';
      }


      sub decode_error {
          my $error  = shift;
          my $no_rep = shift;
          my $str    = defined $text ? substr($text, $at) : '';
          my $mess   = '';
          my $type   = $] >= 5.008           ? 'U*'
                     : $] <  5.006           ? 'C*'
                     : utf8::is_utf8( $str ) ? 'U*' # 5.6
                     : 'C*'
                     ;

          for my $c ( unpack( $type, $str ) ) { # emulate pv_uni_display() ?
              $mess .=  $c == 0x07 ? '\a'
                      : $c == 0x09 ? '\t'
                      : $c == 0x0a ? '\n'
                      : $c == 0x0d ? '\r'
                      : $c == 0x0c ? '\f'
                      : $c <  0x20 ? sprintf('\x{%x}', $c)
                      : $c == 0x5c ? '\\\\'
                      : $c <  0x80 ? chr($c)
                      : sprintf('\x{%x}', $c)
                      ;
              if ( length $mess >= 20 ) {
                  $mess .= '...';
                  last;
              }
          }

          unless ( length $mess ) {
              $mess = '(end of string)';
          }

          Carp::croak (
              $no_rep ? "$error" : "$error, at character offset $at (before \"$mess\")"
          );

      }


      sub _json_object_hook {
          my $o    = $_[0];
          my @ks = keys %{$o};

          if ( $cb_sk_object and @ks == 1 and exists $cb_sk_object->{ $ks[0] } and ref $cb_sk_object->{ $ks[0] } ) {
              my @val = $cb_sk_object->{ $ks[0] }->( $o->{$ks[0]} );
              if (@val == 1) {
                  return $val[0];
              }
          }

          my @val = $cb_object->($o) if ($cb_object);
          if (@val == 0 or @val > 1) {
              return $o;
          }
          else {
              return $val[0];
          }
      }


      sub PP_decode_box {
          {
              text    => $text,
              at      => $at,
              ch      => $ch,
              len     => $len,
              depth   => $depth,
              encoding      => $encoding,
              is_valid_utf8 => $is_valid_utf8,
          };
      }

  } # PARSE


  sub _decode_surrogates { # from perlunicode
      my $uni = 0x10000 + (hex($_[0]) - 0xD800) * 0x400 + (hex($_[1]) - 0xDC00);
      my $un  = pack('U*', $uni);
      utf8::encode( $un );
      return $un;
  }


  sub _decode_unicode {
      my $un = pack('U', hex shift);
      utf8::encode( $un );
      return $un;
  }

  #
  # Setup for various Perl versions (the code from JSON::PP58)
  #

  BEGIN {

      unless ( defined &utf8::is_utf8 ) {
         require Encode;
         *utf8::is_utf8 = *Encode::is_utf8;
      }

      if ( $] >= 5.008 ) {
          *JSON::PP::JSON_PP_encode_ascii      = \&_encode_ascii;
          *JSON::PP::JSON_PP_encode_latin1     = \&_encode_latin1;
          *JSON::PP::JSON_PP_decode_surrogates = \&_decode_surrogates;
          *JSON::PP::JSON_PP_decode_unicode    = \&_decode_unicode;
      }

      if ($] >= 5.008 and $] < 5.008003) { # join() in 5.8.0 - 5.8.2 is broken.
          package JSON::PP;
          require subs;
          subs->import('join');
          eval q|
              sub join {
                  return '' if (@_ < 2);
                  my $j   = shift;
                  my $str = shift;
                  for (@_) { $str .= $j . $_; }
                  return $str;
              }
          |;
      }


      sub JSON::PP::incr_parse {
          local $Carp::CarpLevel = 1;
          ( $_[0]->{_incr_parser} ||= JSON::PP::IncrParser->new )->incr_parse( @_ );
      }


      sub JSON::PP::incr_skip {
          ( $_[0]->{_incr_parser} ||= JSON::PP::IncrParser->new )->incr_skip;
      }


      sub JSON::PP::incr_reset {
          ( $_[0]->{_incr_parser} ||= JSON::PP::IncrParser->new )->incr_reset;
      }

      eval q{
          sub JSON::PP::incr_text : lvalue {
              $_[0]->{_incr_parser} ||= JSON::PP::IncrParser->new;

              if ( $_[0]->{_incr_parser}->{incr_parsing} ) {
                  Carp::croak("incr_text can not be called when the incremental parser already started parsing");
              }
              $_[0]->{_incr_parser}->{incr_text};
          }
      } if ( $] >= 5.006 );

  } # Setup for various Perl versions (the code from JSON::PP58)


  ###############################
  # Utilities
  #

  BEGIN {
      eval 'require Scalar::Util';
      unless($@){
          *JSON::PP::blessed = \&Scalar::Util::blessed;
          *JSON::PP::reftype = \&Scalar::Util::reftype;
          *JSON::PP::refaddr = \&Scalar::Util::refaddr;
      }
      else{ # This code is from Sclar::Util.
          # warn $@;
          eval 'sub UNIVERSAL::a_sub_not_likely_to_be_here { ref($_[0]) }';
          *JSON::PP::blessed = sub {
              local($@, $SIG{__DIE__}, $SIG{__WARN__});
              ref($_[0]) ? eval { $_[0]->a_sub_not_likely_to_be_here } : undef;
          };
          my %tmap = qw(
              B::NULL   SCALAR
              B::HV     HASH
              B::AV     ARRAY
              B::CV     CODE
              B::IO     IO
              B::GV     GLOB
              B::REGEXP REGEXP
          );
          *JSON::PP::reftype = sub {
              my $r = shift;

              return undef unless length(ref($r));

              my $t = ref(B::svref_2object($r));

              return
                  exists $tmap{$t} ? $tmap{$t}
                : length(ref($$r)) ? 'REF'
                :                    'SCALAR';
          };
          *JSON::PP::refaddr = sub {
            return undef unless length(ref($_[0]));

            my $addr;
            if(defined(my $pkg = blessed($_[0]))) {
              $addr .= bless $_[0], 'Scalar::Util::Fake';
              bless $_[0], $pkg;
            }
            else {
              $addr .= $_[0]
            }

            $addr =~ /0x(\w+)/;
            local $^W;
            #no warnings 'portable';
            hex($1);
          }
      }
  }


  # shamely copied and modified from JSON::XS code.

  $JSON::PP::true  = do { bless \(my $dummy = 1), "JSON::PP::Boolean" };
  $JSON::PP::false = do { bless \(my $dummy = 0), "JSON::PP::Boolean" };

  sub is_bool { defined $_[0] and UNIVERSAL::isa($_[0], "JSON::PP::Boolean"); }

  sub true  { $JSON::PP::true  }
  sub false { $JSON::PP::false }
  sub null  { undef; }

  ###############################

  package JSON::PP::Boolean;

  use overload (
     "0+"     => sub { ${$_[0]} },
     "++"     => sub { $_[0] = ${$_[0]} + 1 },
     "--"     => sub { $_[0] = ${$_[0]} - 1 },
     fallback => 1,
  );


  ###############################

  package JSON::PP::IncrParser;

  use strict;

  use constant INCR_M_WS   => 0; # initial whitespace skipping
  use constant INCR_M_STR  => 1; # inside string
  use constant INCR_M_BS   => 2; # inside backslash
  use constant INCR_M_JSON => 3; # outside anything, count nesting
  use constant INCR_M_C0   => 4;
  use constant INCR_M_C1   => 5;

  $JSON::PP::IncrParser::VERSION = '1.01';

  my $unpack_format = $] < 5.006 ? 'C*' : 'U*';

  sub new {
      my ( $class ) = @_;

      bless {
          incr_nest    => 0,
          incr_text    => undef,
          incr_parsing => 0,
          incr_p       => 0,
      }, $class;
  }


  sub incr_parse {
      my ( $self, $coder, $text ) = @_;

      $self->{incr_text} = '' unless ( defined $self->{incr_text} );

      if ( defined $text ) {
          if ( utf8::is_utf8( $text ) and !utf8::is_utf8( $self->{incr_text} ) ) {
              utf8::upgrade( $self->{incr_text} ) ;
              utf8::decode( $self->{incr_text} ) ;
          }
          $self->{incr_text} .= $text;
      }


      my $max_size = $coder->get_max_size;

      if ( defined wantarray ) {

          $self->{incr_mode} = INCR_M_WS unless defined $self->{incr_mode};

          if ( wantarray ) {
              my @ret;

              $self->{incr_parsing} = 1;

              do {
                  push @ret, $self->_incr_parse( $coder, $self->{incr_text} );

                  unless ( !$self->{incr_nest} and $self->{incr_mode} == INCR_M_JSON ) {
                      $self->{incr_mode} = INCR_M_WS if $self->{incr_mode} != INCR_M_STR;
                  }

              } until ( length $self->{incr_text} >= $self->{incr_p} );

              $self->{incr_parsing} = 0;

              return @ret;
          }
          else { # in scalar context
              $self->{incr_parsing} = 1;
              my $obj = $self->_incr_parse( $coder, $self->{incr_text} );
              $self->{incr_parsing} = 0 if defined $obj; # pointed by Martin J. Evans
              return $obj ? $obj : undef; # $obj is an empty string, parsing was completed.
          }

      }

  }


  sub _incr_parse {
      my ( $self, $coder, $text, $skip ) = @_;
      my $p = $self->{incr_p};
      my $restore = $p;

      my @obj;
      my $len = length $text;

      if ( $self->{incr_mode} == INCR_M_WS ) {
          while ( $len > $p ) {
              my $s = substr( $text, $p, 1 );
              $p++ and next if ( 0x20 >= unpack($unpack_format, $s) );
              $self->{incr_mode} = INCR_M_JSON;
              last;
         }
      }

      while ( $len > $p ) {
          my $s = substr( $text, $p++, 1 );

          if ( $s eq '"' ) {
              if (substr( $text, $p - 2, 1 ) eq '\\' ) {
                  next;
              }

              if ( $self->{incr_mode} != INCR_M_STR  ) {
                  $self->{incr_mode} = INCR_M_STR;
              }
              else {
                  $self->{incr_mode} = INCR_M_JSON;
                  unless ( $self->{incr_nest} ) {
                      last;
                  }
              }
          }

          if ( $self->{incr_mode} == INCR_M_JSON ) {

              if ( $s eq '[' or $s eq '{' ) {
                  if ( ++$self->{incr_nest} > $coder->get_max_depth ) {
                      Carp::croak('json text or perl structure exceeds maximum nesting level (max_depth set too low?)');
                  }
              }
              elsif ( $s eq ']' or $s eq '}' ) {
                  last if ( --$self->{incr_nest} <= 0 );
              }
              elsif ( $s eq '#' ) {
                  while ( $len > $p ) {
                      last if substr( $text, $p++, 1 ) eq "\n";
                  }
              }

          }

      }

      $self->{incr_p} = $p;

      return if ( $self->{incr_mode} == INCR_M_STR and not $self->{incr_nest} );
      return if ( $self->{incr_mode} == INCR_M_JSON and $self->{incr_nest} > 0 );

      return '' unless ( length substr( $self->{incr_text}, 0, $p ) );

      local $Carp::CarpLevel = 2;

      $self->{incr_p} = $restore;
      $self->{incr_c} = $p;

      my ( $obj, $tail ) = $coder->PP_decode_json( substr( $self->{incr_text}, 0, $p ), 0x10000001 );

      $self->{incr_text} = substr( $self->{incr_text}, $p );
      $self->{incr_p} = 0;

      return $obj or '';
  }


  sub incr_text {
      if ( $_[0]->{incr_parsing} ) {
          Carp::croak("incr_text can not be called when the incremental parser already started parsing");
      }
      $_[0]->{incr_text};
  }


  sub incr_skip {
      my $self  = shift;
      $self->{incr_text} = substr( $self->{incr_text}, $self->{incr_c} );
      $self->{incr_p} = 0;
  }


  sub incr_reset {
      my $self = shift;
      $self->{incr_text}    = undef;
      $self->{incr_p}       = 0;
      $self->{incr_mode}    = 0;
      $self->{incr_nest}    = 0;
      $self->{incr_parsing} = 0;
  }

  ###############################


  1;
  __END__
  =pod

JSON_PP

$fatpacked{"JSON/PP/Boolean.pm"} = <<'JSON_PP_BOOLEAN';
  use JSON::PP ();
  use strict;

  1;

JSON_PP_BOOLEAN

$fatpacked{"Module/CPANfile.pm"} = <<'MODULE_CPANFILE';
  package Module::CPANfile;
  use strict;
  use warnings;
  use Cwd;

  our $VERSION = '0.9007';

  sub new {
      my($class, $file) = @_;
      bless {}, $class;
  }

  sub load {
      my($proto, $file) = @_;
      my $self = ref $proto ? $proto : $proto->new;
      $self->{file} = $file || "cpanfile";
      $self->parse;
      $self;
  }

  sub parse {
      my $self = shift;

      my $file = Cwd::abs_path($self->{file});
      $self->{result} = Module::CPANfile::Environment::parse($file) or die $@;
  }

  sub prereqs { shift->prereq }

  sub prereq {
      my $self = shift;
      require CPAN::Meta::Prereqs;
      CPAN::Meta::Prereqs->new($self->prereq_specs);
  }

  sub prereq_specs {
      my $self = shift;
      $self->{result}{spec};
  }

  package Module::CPANfile::Environment;
  use strict;

  my @bindings = qw(
      on requires recommends suggests conflicts
      osname perl
      configure_requires build_requires test_requires author_requires
  );

  my $file_id = 1;

  sub import {
      my($class, $result_ref) = @_;
      my $pkg = caller;

      $$result_ref = Module::CPANfile::Result->new;
      for my $binding (@bindings) {
          no strict 'refs';
          *{"$pkg\::$binding"} = sub { $$result_ref->$binding(@_) };
      }
  }

  sub parse {
      my $file = shift;

      my $code = do {
          open my $fh, "<", $file or die "$file: $!";
          join '', <$fh>;
      };

      my($res, $err);

      {
          local $@;
          $res = eval sprintf <<EVAL, $file_id++;
  package Module::CPANfile::Sandbox%d;
  no warnings;
  my \$_result;
  BEGIN { import Module::CPANfile::Environment \\\$_result };

  $code;

  \$_result;
  EVAL
          $err = $@;
      }

      if ($err) { die "Parsing $file failed: $err" };

      return $res;
  }

  package Module::CPANfile::Result;
  use strict;

  sub new {
      bless {
          phase => 'runtime', # default phase
          spec  => {},
      }, shift;
  }

  sub on {
      my($self, $phase, $code) = @_;
      local $self->{phase} = $phase;
      $code->()
  }

  sub osname { die "TODO" }
  sub perl { die "TODO" }

  sub requires {
      my($self, $module, $requirement) = @_;
      $self->{spec}{$self->{phase}}{requires}{$module} = $requirement || 0;
  }

  sub recommends {
      my($self, $module, $requirement) = @_;
      $self->{spec}->{$self->{phase}}{recommends}{$module} = $requirement || 0;
  }

  sub suggests {
      my($self, $module, $requirement) = @_;
      $self->{spec}->{$self->{phase}}{suggests}{$module} = $requirement || 0;
  }

  sub conflicts {
      my($self, $module, $requirement) = @_;
      $self->{spec}->{$self->{phase}}{conflicts}{$module} = $requirement || 0;
  }

  # Module::Install compatible shortcuts

  sub configure_requires {
      my($self, @args) = @_;
      $self->on(configure => sub { $self->requires(@args) });
  }

  sub build_requires {
      my($self, @args) = @_;
      $self->on(build => sub { $self->requires(@args) });
  }

  sub test_requires {
      my($self, @args) = @_;
      $self->on(test => sub { $self->requires(@args) });
  }

  sub author_requires {
      my($self, @args) = @_;
      $self->on(develop => sub { $self->requires(@args) });
  }

  package Module::CPANfile;

  1;

  __END__

  =head1 NAME

  Module::CPANfile - Parse cpanfile

  =head1 SYNOPSIS

    use Module::CPANfile;

    my $file = Module::CPANfile->load("cpanfile");
    my $prereqs = $file->prereqs; # CPAN::Meta::Prereqs object

  =head1 DESCRIPTION

  Module::CPANfile is a tool to handle L<cpanfile> format to load application
  specific dependencies, not just for CPAN distributions.

  =head1 AUTHOR

  Tatsuhiko Miyagawa

  =head1 SEE ALSO

  L<cpanfile>, L<CPAN::Meta>, L<CPAN::Meta::Spec>

  =cut


MODULE_CPANFILE

$fatpacked{"Module/Metadata.pm"} = <<'MODULE_METADATA';
  # -*- mode: cperl; tab-width: 8; indent-tabs-mode: nil; basic-offset: 2 -*-
  # vim:ts=8:sw=2:et:sta:sts=2
  package Module::Metadata;

  # Adapted from Perl-licensed code originally distributed with
  # Module-Build by Ken Williams

  # This module provides routines to gather information about
  # perl modules (assuming this may be expanded in the distant
  # parrot future to look at other types of modules).

  use strict;
  use vars qw($VERSION);
  $VERSION = '1.000007';
  $VERSION = eval $VERSION;

  use File::Spec;
  use IO::File;
  use version 0.87;
  BEGIN {
    if ($INC{'Log/Contextual.pm'}) {
      Log::Contextual->import('log_info');
    } else {
      *log_info = sub (&) { warn $_[0]->() };
    }
  }
  use File::Find qw(find);

  my $V_NUM_REGEXP = qr{v?[0-9._]+};  # crudely, a v-string or decimal

  my $PKG_REGEXP  = qr{   # match a package declaration
    ^[\s\{;]*             # intro chars on a line
    package               # the word 'package'
    \s+                   # whitespace
    ([\w:]+)              # a package name
    \s*                   # optional whitespace
    ($V_NUM_REGEXP)?        # optional version number
    \s*                   # optional whitesapce
    [;\{]                 # semicolon line terminator or block start (since 5.16)
  }x;

  my $VARNAME_REGEXP = qr{ # match fully-qualified VERSION name
    ([\$*])         # sigil - $ or *
    (
      (             # optional leading package name
        (?:::|\')?  # possibly starting like just :: (म  la $::VERSION)
        (?:\w+(?:::|\'))*  # Foo::Bar:: ...
      )?
      VERSION
    )\b
  }x;

  my $VERS_REGEXP = qr{ # match a VERSION definition
    (?:
      \(\s*$VARNAME_REGEXP\s*\) # with parens
    |
      $VARNAME_REGEXP           # without parens
    )
    \s*
    =[^=~]  # = but not ==, nor =~
  }x;


  sub new_from_file {
    my $class    = shift;
    my $filename = File::Spec->rel2abs( shift );

    return undef unless defined( $filename ) && -f $filename;
    return $class->_init(undef, $filename, @_);
  }

  sub new_from_handle {
    my $class    = shift;
    my $handle   = shift;
    my $filename = shift;
    return undef unless defined($handle) && defined($filename);
    $filename = File::Spec->rel2abs( $filename );

    return $class->_init(undef, $filename, @_, handle => $handle);

  }


  sub new_from_module {
    my $class   = shift;
    my $module  = shift;
    my %props   = @_;

    $props{inc} ||= \@INC;
    my $filename = $class->find_module_by_name( $module, $props{inc} );
    return undef unless defined( $filename ) && -f $filename;
    return $class->_init($module, $filename, %props);
  }

  {

    my $compare_versions = sub {
      my ($v1, $op, $v2) = @_;
      $v1 = version->new($v1)
        unless UNIVERSAL::isa($v1,'version');

      my $eval_str = "\$v1 $op \$v2";
      my $result   = eval $eval_str;
      log_info { "error comparing versions: '$eval_str' $@" } if $@;

      return $result;
    };

    my $normalize_version = sub {
      my ($version) = @_;
      if ( $version =~ /[=<>!,]/ ) { # logic, not just version
        # take as is without modification
      }
      elsif ( ref $version eq 'version' ) { # version objects
        $version = $version->is_qv ? $version->normal : $version->stringify;
      }
      elsif ( $version =~ /^[^v][^.]*\.[^.]+\./ ) { # no leading v, multiple dots
        # normalize string tuples without "v": "1.2.3" -> "v1.2.3"
        $version = "v$version";
      }
      else {
        # leave alone
      }
      return $version;
    };

    # separate out some of the conflict resolution logic

    my $resolve_module_versions = sub {
      my $packages = shift;

      my( $file, $version );
      my $err = '';
        foreach my $p ( @$packages ) {
          if ( defined( $p->{version} ) ) {
      if ( defined( $version ) ) {
        if ( $compare_versions->( $version, '!=', $p->{version} ) ) {
          $err .= "  $p->{file} ($p->{version})\n";
        } else {
          # same version declared multiple times, ignore
        }
      } else {
        $file    = $p->{file};
        $version = $p->{version};
      }
          }
          $file ||= $p->{file} if defined( $p->{file} );
        }

      if ( $err ) {
        $err = "  $file ($version)\n" . $err;
      }

      my %result = (
        file    => $file,
        version => $version,
        err     => $err
      );

      return \%result;
    };

    sub package_versions_from_directory {
      my ( $class, $dir, $files ) = @_;

      my @files;

      if ( $files ) {
        @files = @$files;
      } else {
        find( {
          wanted => sub {
            push @files, $_ if -f $_ && /\.pm$/;
          },
          no_chdir => 1,
        }, $dir );
      }

      # First, we enumerate all packages & versions,
      # separating into primary & alternative candidates
      my( %prime, %alt );
      foreach my $file (@files) {
        my $mapped_filename = File::Spec->abs2rel( $file, $dir );
        my @path = split( /\//, $mapped_filename );
        (my $prime_package = join( '::', @path )) =~ s/\.pm$//;

        my $pm_info = $class->new_from_file( $file );

        foreach my $package ( $pm_info->packages_inside ) {
          next if $package eq 'main';  # main can appear numerous times, ignore
          next if $package eq 'DB';    # special debugging package, ignore
          next if grep /^_/, split( /::/, $package ); # private package, ignore

          my $version = $pm_info->version( $package );

          if ( $package eq $prime_package ) {
            if ( exists( $prime{$package} ) ) {
              die "Unexpected conflict in '$package'; multiple versions found.\n";
            } else {
              $prime{$package}{file} = $mapped_filename;
              $prime{$package}{version} = $version if defined( $version );
            }
          } else {
            push( @{$alt{$package}}, {
                                      file    => $mapped_filename,
                                      version => $version,
                                     } );
          }
        }
      }

      # Then we iterate over all the packages found above, identifying conflicts
      # and selecting the "best" candidate for recording the file & version
      # for each package.
      foreach my $package ( keys( %alt ) ) {
        my $result = $resolve_module_versions->( $alt{$package} );

        if ( exists( $prime{$package} ) ) { # primary package selected

          if ( $result->{err} ) {
      # Use the selected primary package, but there are conflicting
      # errors among multiple alternative packages that need to be
      # reported
            log_info {
          "Found conflicting versions for package '$package'\n" .
          "  $prime{$package}{file} ($prime{$package}{version})\n" .
          $result->{err}
            };

          } elsif ( defined( $result->{version} ) ) {
      # There is a primary package selected, and exactly one
      # alternative package

      if ( exists( $prime{$package}{version} ) &&
           defined( $prime{$package}{version} ) ) {
        # Unless the version of the primary package agrees with the
        # version of the alternative package, report a conflict
        if ( $compare_versions->(
                   $prime{$package}{version}, '!=', $result->{version}
                 )
               ) {

              log_info {
                "Found conflicting versions for package '$package'\n" .
            "  $prime{$package}{file} ($prime{$package}{version})\n" .
            "  $result->{file} ($result->{version})\n"
              };
        }

      } else {
        # The prime package selected has no version so, we choose to
        # use any alternative package that does have a version
        $prime{$package}{file}    = $result->{file};
        $prime{$package}{version} = $result->{version};
      }

          } else {
      # no alt package found with a version, but we have a prime
      # package so we use it whether it has a version or not
          }

        } else { # No primary package was selected, use the best alternative

          if ( $result->{err} ) {
            log_info {
              "Found conflicting versions for package '$package'\n" .
          $result->{err}
            };
          }

          # Despite possible conflicting versions, we choose to record
          # something rather than nothing
          $prime{$package}{file}    = $result->{file};
          $prime{$package}{version} = $result->{version}
        if defined( $result->{version} );
        }
      }

      # Normalize versions.  Can't use exists() here because of bug in YAML::Node.
      # XXX "bug in YAML::Node" comment seems irrelvant -- dagolden, 2009-05-18
      for (grep defined $_->{version}, values %prime) {
        $_->{version} = $normalize_version->( $_->{version} );
      }

      return \%prime;
    }
  }


  sub _init {
    my $class    = shift;
    my $module   = shift;
    my $filename = shift;
    my %props = @_;

    my $handle = delete $props{handle};
    my( %valid_props, @valid_props );
    @valid_props = qw( collect_pod inc );
    @valid_props{@valid_props} = delete( @props{@valid_props} );
    warn "Unknown properties: @{[keys %props]}\n" if scalar( %props );

    my %data = (
      module       => $module,
      filename     => $filename,
      version      => undef,
      packages     => [],
      versions     => {},
      pod          => {},
      pod_headings => [],
      collect_pod  => 0,

      %valid_props,
    );

    my $self = bless(\%data, $class);

    if ( $handle ) {
      $self->_parse_fh($handle);
    }
    else {
      $self->_parse_file();
    }

    unless($self->{module} and length($self->{module})) {
      my ($v, $d, $f) = File::Spec->splitpath($self->{filename});
      if($f =~ /\.pm$/) {
        $f =~ s/\..+$//;
        my @candidates = grep /$f$/, @{$self->{packages}};
        $self->{module} = shift(@candidates); # punt
      }
      else {
        if(grep /main/, @{$self->{packages}}) {
          $self->{module} = 'main';
        }
        else {
          $self->{module} = $self->{packages}[0] || '';
        }
      }
    }

    $self->{version} = $self->{versions}{$self->{module}}
        if defined( $self->{module} );

    return $self;
  }

  # class method
  sub _do_find_module {
    my $class   = shift;
    my $module  = shift || die 'find_module_by_name() requires a package name';
    my $dirs    = shift || \@INC;

    my $file = File::Spec->catfile(split( /::/, $module));
    foreach my $dir ( @$dirs ) {
      my $testfile = File::Spec->catfile($dir, $file);
      return [ File::Spec->rel2abs( $testfile ), $dir ]
    if -e $testfile and !-d _;  # For stuff like ExtUtils::xsubpp
      return [ File::Spec->rel2abs( "$testfile.pm" ), $dir ]
    if -e "$testfile.pm";
    }
    return;
  }

  # class method
  sub find_module_by_name {
    my $found = shift()->_do_find_module(@_) or return;
    return $found->[0];
  }

  # class method
  sub find_module_dir_by_name {
    my $found = shift()->_do_find_module(@_) or return;
    return $found->[1];
  }


  # given a line of perl code, attempt to parse it if it looks like a
  # $VERSION assignment, returning sigil, full name, & package name
  sub _parse_version_expression {
    my $self = shift;
    my $line = shift;

    my( $sig, $var, $pkg );
    if ( $line =~ $VERS_REGEXP ) {
      ( $sig, $var, $pkg ) = $2 ? ( $1, $2, $3 ) : ( $4, $5, $6 );
      if ( $pkg ) {
        $pkg = ($pkg eq '::') ? 'main' : $pkg;
        $pkg =~ s/::$//;
      }
    }

    return ( $sig, $var, $pkg );
  }

  sub _parse_file {
    my $self = shift;

    my $filename = $self->{filename};
    my $fh = IO::File->new( $filename )
      or die( "Can't open '$filename': $!" );

    $self->_parse_fh($fh);
  }

  sub _parse_fh {
    my ($self, $fh) = @_;

    my( $in_pod, $seen_end, $need_vers ) = ( 0, 0, 0 );
    my( @pkgs, %vers, %pod, @pod );
    my $pkg = 'main';
    my $pod_sect = '';
    my $pod_data = '';

    while (defined( my $line = <$fh> )) {
      my $line_num = $.;

      chomp( $line );
      next if $line =~ /^\s*#/;

      $in_pod = ($line =~ /^=(?!cut)/) ? 1 : ($line =~ /^=cut/) ? 0 : $in_pod;

      # Would be nice if we could also check $in_string or something too
      last if !$in_pod && $line =~ /^__(?:DATA|END)__$/;

      if ( $in_pod || $line =~ /^=cut/ ) {

        if ( $line =~ /^=head\d\s+(.+)\s*$/ ) {
    push( @pod, $1 );
    if ( $self->{collect_pod} && length( $pod_data ) ) {
            $pod{$pod_sect} = $pod_data;
            $pod_data = '';
          }
    $pod_sect = $1;


        } elsif ( $self->{collect_pod} ) {
    $pod_data .= "$line\n";

        }

      } else {

        $pod_sect = '';
        $pod_data = '';

        # parse $line to see if it's a $VERSION declaration
        my( $vers_sig, $vers_fullname, $vers_pkg ) =
      $self->_parse_version_expression( $line );

        if ( $line =~ $PKG_REGEXP ) {
          $pkg = $1;
          push( @pkgs, $pkg ) unless grep( $pkg eq $_, @pkgs );
          $vers{$pkg} = (defined $2 ? $2 : undef)  unless exists( $vers{$pkg} );
          $need_vers = defined $2 ? 0 : 1;

        # VERSION defined with full package spec, i.e. $Module::VERSION
        } elsif ( $vers_fullname && $vers_pkg ) {
    push( @pkgs, $vers_pkg ) unless grep( $vers_pkg eq $_, @pkgs );
    $need_vers = 0 if $vers_pkg eq $pkg;

    unless ( defined $vers{$vers_pkg} && length $vers{$vers_pkg} ) {
      $vers{$vers_pkg} =
        $self->_evaluate_version_line( $vers_sig, $vers_fullname, $line );
    } else {
      # Warn unless the user is using the "$VERSION = eval
      # $VERSION" idiom (though there are probably other idioms
      # that we should watch out for...)
      warn <<"EOM" unless $line =~ /=\s*eval/;
  Package '$vers_pkg' already declared with version '$vers{$vers_pkg}',
  ignoring subsequent declaration on line $line_num.
  EOM
    }

        # first non-comment line in undeclared package main is VERSION
        } elsif ( !exists($vers{main}) && $pkg eq 'main' && $vers_fullname ) {
    $need_vers = 0;
    my $v =
      $self->_evaluate_version_line( $vers_sig, $vers_fullname, $line );
    $vers{$pkg} = $v;
    push( @pkgs, 'main' );

        # first non-comment line in undeclared package defines package main
        } elsif ( !exists($vers{main}) && $pkg eq 'main' && $line =~ /\w+/ ) {
    $need_vers = 1;
    $vers{main} = '';
    push( @pkgs, 'main' );

        # only keep if this is the first $VERSION seen
        } elsif ( $vers_fullname && $need_vers ) {
    $need_vers = 0;
    my $v =
      $self->_evaluate_version_line( $vers_sig, $vers_fullname, $line );


    unless ( defined $vers{$pkg} && length $vers{$pkg} ) {
      $vers{$pkg} = $v;
    } else {
      warn <<"EOM";
  Package '$pkg' already declared with version '$vers{$pkg}'
  ignoring new version '$v' on line $line_num.
  EOM
    }

        }

      }

    }

    if ( $self->{collect_pod} && length($pod_data) ) {
      $pod{$pod_sect} = $pod_data;
    }

    $self->{versions} = \%vers;
    $self->{packages} = \@pkgs;
    $self->{pod} = \%pod;
    $self->{pod_headings} = \@pod;
  }

  {
  my $pn = 0;
  sub _evaluate_version_line {
    my $self = shift;
    my( $sigil, $var, $line ) = @_;

    # Some of this code came from the ExtUtils:: hierarchy.

    # We compile into $vsub because 'use version' would cause
    # compiletime/runtime issues with local()
    my $vsub;
    $pn++; # everybody gets their own package
    my $eval = qq{BEGIN { q#  Hide from _packages_inside()
      #; package Module::Metadata::_version::p$pn;
      use version;
      no strict;

        \$vsub = sub {
          local $sigil$var;
          \$$var=undef;
          $line;
          \$$var
        };
    }};

    local $^W;
    # Try to get the $VERSION
    eval $eval;
    # some modules say $VERSION = $Foo::Bar::VERSION, but Foo::Bar isn't
    # installed, so we need to hunt in ./lib for it
    if ( $@ =~ /Can't locate/ && -d 'lib' ) {
      local @INC = ('lib',@INC);
      eval $eval;
    }
    warn "Error evaling version line '$eval' in $self->{filename}: $@\n"
      if $@;
    (ref($vsub) eq 'CODE') or
      die "failed to build version sub for $self->{filename}";
    my $result = eval { $vsub->() };
    die "Could not get version from $self->{filename} by executing:\n$eval\n\nThe fatal error was: $@\n"
      if $@;

    # Upgrade it into a version object
    my $version = eval { _dwim_version($result) };

    die "Version '$result' from $self->{filename} does not appear to be valid:\n$eval\n\nThe fatal error was: $@\n"
      unless defined $version; # "0" is OK!

    return $version;
  }
  }

  # Try to DWIM when things fail the lax version test in obvious ways
  {
    my @version_prep = (
      # Best case, it just works
      sub { return shift },

      # If we still don't have a version, try stripping any
      # trailing junk that is prohibited by lax rules
      sub {
        my $v = shift;
        $v =~ s{([0-9])[a-z-].*$}{$1}i; # 1.23-alpha or 1.23b
        return $v;
      },

      # Activestate apparently creates custom versions like '1.23_45_01', which
      # cause version.pm to think it's an invalid alpha.  So check for that
      # and strip them
      sub {
        my $v = shift;
        my $num_dots = () = $v =~ m{(\.)}g;
        my $num_unders = () = $v =~ m{(_)}g;
        my $leading_v = substr($v,0,1) eq 'v';
        if ( ! $leading_v && $num_dots < 2 && $num_unders > 1 ) {
          $v =~ s{_}{}g;
          $num_unders = () = $v =~ m{(_)}g;
        }
        return $v;
      },

      # Worst case, try numifying it like we would have before version objects
      sub {
        my $v = shift;
        no warnings 'numeric';
        return 0 + $v;
      },

    );

    sub _dwim_version {
      my ($result) = shift;

      return $result if ref($result) eq 'version';

      my ($version, $error);
      for my $f (@version_prep) {
        $result = $f->($result);
        $version = eval { version->new($result) };
        $error ||= $@ if $@; # capture first failure
        last if defined $version;
      }

      die $error unless defined $version;

      return $version;
    }
  }

  ############################################################

  # accessors
  sub name            { $_[0]->{module}           }

  sub filename        { $_[0]->{filename}         }
  sub packages_inside { @{$_[0]->{packages}}      }
  sub pod_inside      { @{$_[0]->{pod_headings}}  }
  sub contains_pod    { $#{$_[0]->{pod_headings}} }

  sub version {
      my $self = shift;
      my $mod  = shift || $self->{module};
      my $vers;
      if ( defined( $mod ) && length( $mod ) &&
     exists( $self->{versions}{$mod} ) ) {
    return $self->{versions}{$mod};
      } else {
    return undef;
      }
  }

  sub pod {
      my $self = shift;
      my $sect = shift;
      if ( defined( $sect ) && length( $sect ) &&
     exists( $self->{pod}{$sect} ) ) {
    return $self->{pod}{$sect};
      } else {
    return undef;
      }
  }

  1;

MODULE_METADATA

$fatpacked{"Parse/CPAN/Meta.pm"} = <<'PARSE_CPAN_META';
  package Parse::CPAN::Meta;

  use strict;
  use Carp 'croak';

  # UTF Support?
  sub HAVE_UTF8 () { $] >= 5.007003 }
  sub IO_LAYER () { $] >= 5.008001 ? ":utf8" : "" }

  BEGIN {
    if ( HAVE_UTF8 ) {
      # The string eval helps hide this from Test::MinimumVersion
      eval "require utf8;";
      die "Failed to load UTF-8 support" if $@;
    }

    # Class structure
    require 5.004;
    require Exporter;
    $Parse::CPAN::Meta::VERSION   = '1.4401';
    @Parse::CPAN::Meta::ISA       = qw{ Exporter      };
    @Parse::CPAN::Meta::EXPORT_OK = qw{ Load LoadFile };
  }

  sub load_file {
    my ($class, $filename) = @_;

    if ($filename =~ /\.ya?ml$/) {
      return $class->load_yaml_string(_slurp($filename));
    }

    if ($filename =~ /\.json$/) {
      return $class->load_json_string(_slurp($filename));
    }

    croak("file type cannot be determined by filename");
  }

  sub load_yaml_string {
    my ($class, $string) = @_;
    my $backend = $class->yaml_backend();
    my $data = eval { no strict 'refs'; &{"$backend\::Load"}($string) };
    if ( $@ ) {
      croak $backend->can('errstr') ? $backend->errstr : $@
    }
    return $data || {}; # in case document was valid but empty
  }

  sub load_json_string {
    my ($class, $string) = @_;
    return $class->json_backend()->new->decode($string);
  }

  sub yaml_backend {
    local $Module::Load::Conditional::CHECK_INC_HASH = 1;
    if (! defined $ENV{PERL_YAML_BACKEND} ) {
      _can_load( 'CPAN::Meta::YAML', 0.002 )
        or croak "CPAN::Meta::YAML 0.002 is not available\n";
      return "CPAN::Meta::YAML";
    }
    else {
      my $backend = $ENV{PERL_YAML_BACKEND};
      _can_load( $backend )
        or croak "Could not load PERL_YAML_BACKEND '$backend'\n";
      $backend->can("Load")
        or croak "PERL_YAML_BACKEND '$backend' does not implement Load()\n";
      return $backend;
    }
  }

  sub json_backend {
    local $Module::Load::Conditional::CHECK_INC_HASH = 1;
    if (! $ENV{PERL_JSON_BACKEND} or $ENV{PERL_JSON_BACKEND} eq 'JSON::PP') {
      _can_load( 'JSON::PP' => 2.27103 )
        or croak "JSON::PP 2.27103 is not available\n";
      return 'JSON::PP';
    }
    else {
      _can_load( 'JSON' => 2.5 )
        or croak  "JSON 2.5 is required for " .
                  "\$ENV{PERL_JSON_BACKEND} = '$ENV{PERL_JSON_BACKEND}'\n";
      return "JSON";
    }
  }

  sub _slurp {
    open my $fh, "<" . IO_LAYER, "$_[0]"
      or die "can't open $_[0] for reading: $!";
    return do { local $/; <$fh> };
  }

  sub _can_load {
    my ($module, $version) = @_;
    (my $file = $module) =~ s{::}{/}g;
    $file .= ".pm";
    return 1 if $INC{$file};
    return 0 if exists $INC{$file}; # prior load failed
    eval { require $file; 1 }
      or return 0;
    if ( defined $version ) {
      eval { $module->VERSION($version); 1 }
        or return 0;
    }
    return 1;
  }

  # Kept for backwards compatibility only
  # Create an object from a file
  sub LoadFile ($) {
    require CPAN::Meta::YAML;
    return CPAN::Meta::YAML::LoadFile(shift)
      or die CPAN::Meta::YAML->errstr;
  }

  # Parse a document from a string.
  sub Load ($) {
    require CPAN::Meta::YAML;
    return CPAN::Meta::YAML::Load(shift)
      or die CPAN::Meta::YAML->errstr;
  }

  1;

  __END__

PARSE_CPAN_META

$fatpacked{"Try/Tiny.pm"} = <<'TRY_TINY';
  package Try::Tiny;

  use strict;
  #use warnings;

  use vars qw(@EXPORT @EXPORT_OK $VERSION @ISA);

  BEGIN {
    require Exporter;
    @ISA = qw(Exporter);
  }

  $VERSION = "0.09";

  $VERSION = eval $VERSION;

  @EXPORT = @EXPORT_OK = qw(try catch finally);

  $Carp::Internal{+__PACKAGE__}++;

  # Need to prototype as @ not $$ because of the way Perl evaluates the prototype.
  # Keeping it at $$ means you only ever get 1 sub because we need to eval in a list
  # context & not a scalar one

  sub try (&;@) {
    my ( $try, @code_refs ) = @_;

    # we need to save this here, the eval block will be in scalar context due
    # to $failed
    my $wantarray = wantarray;

    my ( $catch, @finally );

    # find labeled blocks in the argument list.
    # catch and finally tag the blocks by blessing a scalar reference to them.
    foreach my $code_ref (@code_refs) {
      next unless $code_ref;

      my $ref = ref($code_ref);

      if ( $ref eq 'Try::Tiny::Catch' ) {
        $catch = ${$code_ref};
      } elsif ( $ref eq 'Try::Tiny::Finally' ) {
        push @finally, ${$code_ref};
      } else {
        use Carp;
        confess("Unknown code ref type given '${ref}'. Check your usage & try again");
      }
    }

    # save the value of $@ so we can set $@ back to it in the beginning of the eval
    my $prev_error = $@;

    my ( @ret, $error, $failed );

    # FIXME consider using local $SIG{__DIE__} to accumulate all errors. It's
    # not perfect, but we could provide a list of additional errors for
    # $catch->();

    {
      # localize $@ to prevent clobbering of previous value by a successful
      # eval.
      local $@;

      # failed will be true if the eval dies, because 1 will not be returned
      # from the eval body
      $failed = not eval {
        $@ = $prev_error;

        # evaluate the try block in the correct context
        if ( $wantarray ) {
          @ret = $try->();
        } elsif ( defined $wantarray ) {
          $ret[0] = $try->();
        } else {
          $try->();
        };

        return 1; # properly set $fail to false
      };

      # copy $@ to $error; when we leave this scope, local $@ will revert $@
      # back to its previous value
      $error = $@;
    }

    # set up a scope guard to invoke the finally block at the end
    my @guards =
      map { Try::Tiny::ScopeGuard->_new($_, $failed ? $error : ()) }
      @finally;

    # at this point $failed contains a true value if the eval died, even if some
    # destructor overwrote $@ as the eval was unwinding.
    if ( $failed ) {
      # if we got an error, invoke the catch block.
      if ( $catch ) {
        # This works like given($error), but is backwards compatible and
        # sets $_ in the dynamic scope for the body of C<$catch>
        for ($error) {
          return $catch->($error);
        }

        # in case when() was used without an explicit return, the C<for>
        # loop will be aborted and there's no useful return value
      }

      return;
    } else {
      # no failure, $@ is back to what it was, everything is fine
      return $wantarray ? @ret : $ret[0];
    }
  }

  sub catch (&;@) {
    my ( $block, @rest ) = @_;

    return (
      bless(\$block, 'Try::Tiny::Catch'),
      @rest,
    );
  }

  sub finally (&;@) {
    my ( $block, @rest ) = @_;

    return (
      bless(\$block, 'Try::Tiny::Finally'),
      @rest,
    );
  }

  {
    package # hide from PAUSE
      Try::Tiny::ScopeGuard;

    sub _new {
      shift;
      bless [ @_ ];
    }

    sub DESTROY {
      my @guts = @{ shift() };
      my $code = shift @guts;
      $code->(@guts);
    }
  }

  __PACKAGE__

  __END__

TRY_TINY

$fatpacked{"lib/core/only.pm"} = <<'LIB_CORE_ONLY';
  package lib::core::only;

  use strict;
  use warnings FATAL => 'all';
  use Config;

  sub import {
    @INC = @Config{qw(privlibexp archlibexp)};
    return
  }

  1;
LIB_CORE_ONLY

$fatpacked{"local/lib.pm"} = <<'LOCAL_LIB';
  use strict;
  use warnings;

  package local::lib;

  use 5.008001; # probably works with earlier versions but I'm not supporting them
                # (patches would, of course, be welcome)

  use File::Spec ();
  use File::Path ();
  use Carp ();
  use Config;

  our $VERSION = '1.008001'; # 1.8.1

  our @KNOWN_FLAGS = qw(--self-contained);

  sub import {
    my ($class, @args) = @_;

    # Remember what PERL5LIB was when we started
    my $perl5lib = $ENV{PERL5LIB} || '';

    my %arg_store;
    for my $arg (@args) {
      # check for lethal dash first to stop processing before causing problems
      if ($arg =~ /—/) {
        die <<'DEATH';
  WHOA THERE! It looks like you've got some fancy dashes in your commandline!
  These are *not* the traditional -- dashes that software recognizes. You
  probably got these by copy-pasting from the perldoc for this module as
  rendered by a UTF8-capable formatter. This most typically happens on an OS X
  terminal, but can happen elsewhere too. Please try again after replacing the
  dashes with normal minus signs.
  DEATH
      }
      elsif(grep { $arg eq $_ } @KNOWN_FLAGS) {
        (my $flag = $arg) =~ s/--//;
        $arg_store{$flag} = 1;
      }
      elsif($arg =~ /^--/) {
        die "Unknown import argument: $arg";
      }
      else {
        # assume that what's left is a path
        $arg_store{path} = $arg;
      }
    }

    if($arg_store{'self-contained'}) {
      die "FATAL: The local::lib --self-contained flag has never worked reliably and the original author, Mark Stosberg, was unable or unwilling to maintain it. As such, this flag has been removed from the local::lib codebase in order to prevent misunderstandings and potentially broken builds. The local::lib authors recommend that you look at the lib::core::only module shipped with this distribution in order to create a more robust environment that is equivalent to what --self-contained provided (although quite possibly not what you originally thought it provided due to the poor quality of the documentation, for which we apologise).\n";
    }

    $arg_store{path} = $class->resolve_path($arg_store{path});
    $class->setup_local_lib_for($arg_store{path});

    for (@INC) { # Untaint @INC
      next if ref; # Skip entry if it is an ARRAY, CODE, blessed, etc.
      m/(.*)/ and $_ = $1;
    }
  }

  sub pipeline;

  sub pipeline {
    my @methods = @_;
    my $last = pop(@methods);
    if (@methods) {
      \sub {
        my ($obj, @args) = @_;
        $obj->${pipeline @methods}(
          $obj->$last(@args)
        );
      };
    } else {
      \sub {
        shift->$last(@_);
      };
    }
  }

  sub _uniq {
      my %seen;
      grep { ! $seen{$_}++ } @_;
  }

  sub resolve_path {
    my ($class, $path) = @_;
    $class->${pipeline qw(
      resolve_relative_path
      resolve_home_path
      resolve_empty_path
    )}($path);
  }

  sub resolve_empty_path {
    my ($class, $path) = @_;
    if (defined $path) {
      $path;
    } else {
      '~/perl5';
    }
  }

  sub resolve_home_path {
    my ($class, $path) = @_;
    return $path unless ($path =~ /^~/);
    my ($user) = ($path =~ /^~([^\/]+)/); # can assume ^~ so undef for 'us'
    my $tried_file_homedir;
    my $homedir = do {
      if (eval { require File::HomeDir } && $File::HomeDir::VERSION >= 0.65) {
        $tried_file_homedir = 1;
        if (defined $user) {
          File::HomeDir->users_home($user);
        } else {
          File::HomeDir->my_home;
        }
      } else {
        if (defined $user) {
          (getpwnam $user)[7];
        } else {
          if (defined $ENV{HOME}) {
            $ENV{HOME};
          } else {
            (getpwuid $<)[7];
          }
        }
      }
    };
    unless (defined $homedir) {
      Carp::croak(
        "Couldn't resolve homedir for "
        .(defined $user ? $user : 'current user')
        .($tried_file_homedir ? '' : ' - consider installing File::HomeDir')
      );
    }
    $path =~ s/^~[^\/]*/$homedir/;
    $path;
  }

  sub resolve_relative_path {
    my ($class, $path) = @_;
    $path = File::Spec->rel2abs($path);
  }

  sub setup_local_lib_for {
    my ($class, $path) = @_;
    $path = $class->ensure_dir_structure_for($path);
    if ($0 eq '-') {
      $class->print_environment_vars_for($path);
      exit 0;
    } else {
      $class->setup_env_hash_for($path);
      @INC = _uniq(split($Config{path_sep}, $ENV{PERL5LIB}), @INC);
    }
  }

  sub install_base_bin_path {
    my ($class, $path) = @_;
    File::Spec->catdir($path, 'bin');
  }

  sub install_base_perl_path {
    my ($class, $path) = @_;
    File::Spec->catdir($path, 'lib', 'perl5');
  }

  sub install_base_arch_path {
    my ($class, $path) = @_;
    File::Spec->catdir($class->install_base_perl_path($path), $Config{archname});
  }

  sub ensure_dir_structure_for {
    my ($class, $path) = @_;
    unless (-d $path) {
      warn "Attempting to create directory ${path}\n";
    }
    File::Path::mkpath($path);
    # Need to have the path exist to make a short name for it, so
    # converting to a short name here.
    $path = Win32::GetShortPathName($path) if $^O eq 'MSWin32';

    return $path;
  }

  sub INTERPOLATE_ENV () { 1 }
  sub LITERAL_ENV     () { 0 }

  sub guess_shelltype {
    my $shellbin = 'sh';
    if(defined $ENV{'SHELL'}) {
        my @shell_bin_path_parts = File::Spec->splitpath($ENV{'SHELL'});
        $shellbin = $shell_bin_path_parts[-1];
    }
    my $shelltype = do {
        local $_ = $shellbin;
        if(/csh/) {
            'csh'
        } else {
            'bourne'
        }
    };

    # Both Win32 and Cygwin have $ENV{COMSPEC} set.
    if (defined $ENV{'COMSPEC'} && $^O ne 'cygwin') {
        my @shell_bin_path_parts = File::Spec->splitpath($ENV{'COMSPEC'});
        $shellbin = $shell_bin_path_parts[-1];
           $shelltype = do {
                   local $_ = $shellbin;
                   if(/command\.com/) {
                           'win32'
                   } elsif(/cmd\.exe/) {
                           'win32'
                   } elsif(/4nt\.exe/) {
                           'win32'
                   } else {
                           $shelltype
                   }
           };
    }
    return $shelltype;
  }

  sub print_environment_vars_for {
    my ($class, $path) = @_;
    print $class->environment_vars_string_for($path);
  }

  sub environment_vars_string_for {
    my ($class, $path) = @_;
    my @envs = $class->build_environment_vars_for($path, LITERAL_ENV);
    my $out = '';

    # rather basic csh detection, goes on the assumption that something won't
    # call itself csh unless it really is. also, default to bourne in the
    # pathological situation where a user doesn't have $ENV{SHELL} defined.
    # note also that shells with funny names, like zoid, are assumed to be
    # bourne.

    my $shelltype = $class->guess_shelltype;

    while (@envs) {
      my ($name, $value) = (shift(@envs), shift(@envs));
      $value =~ s/(\\")/\\$1/g;
      $out .= $class->${\"build_${shelltype}_env_declaration"}($name, $value);
    }
    return $out;
  }

  # simple routines that take two arguments: an %ENV key and a value. return
  # strings that are suitable for passing directly to the relevant shell to set
  # said key to said value.
  sub build_bourne_env_declaration {
    my $class = shift;
    my($name, $value) = @_;
    return qq{export ${name}="${value}"\n};
  }

  sub build_csh_env_declaration {
    my $class = shift;
    my($name, $value) = @_;
    return qq{setenv ${name} "${value}"\n};
  }

  sub build_win32_env_declaration {
    my $class = shift;
    my($name, $value) = @_;
    return qq{set ${name}=${value}\n};
  }

  sub setup_env_hash_for {
    my ($class, $path) = @_;
    my %envs = $class->build_environment_vars_for($path, INTERPOLATE_ENV);
    @ENV{keys %envs} = values %envs;
  }

  sub build_environment_vars_for {
    my ($class, $path, $interpolate) = @_;
    return (
      PERL_LOCAL_LIB_ROOT => $path,
      PERL_MB_OPT => "--install_base ${path}",
      PERL_MM_OPT => "INSTALL_BASE=${path}",
      PERL5LIB => join($Config{path_sep},
                    $class->install_base_arch_path($path),
                    $class->install_base_perl_path($path),
                    (($ENV{PERL5LIB}||()) ?
                      ($interpolate == INTERPOLATE_ENV
                        ? ($ENV{PERL5LIB})
                        : (($^O ne 'MSWin32') ? '$PERL5LIB' : '%PERL5LIB%' ))
                      : ())
                  ),
      PATH => join($Config{path_sep},
                $class->install_base_bin_path($path),
                ($interpolate == INTERPOLATE_ENV
                  ? ($ENV{PATH}||())
                  : (($^O ne 'MSWin32') ? '$PATH' : '%PATH%' ))
               ),
    )
  }

  1;
LOCAL_LIB

$fatpacked{"parent.pm"} = <<'PARENT';
  package parent;
  use strict;
  use vars qw($VERSION);
  $VERSION = '0.225';

  sub import {
      my $class = shift;

      my $inheritor = caller(0);

      if ( @_ and $_[0] eq '-norequire' ) {
          shift @_;
      } else {
          for ( my @filename = @_ ) {
              if ( $_ eq $inheritor ) {
                  warn "Class '$inheritor' tried to inherit from itself\n";
              };

              s{::|'}{/}g;
              require "$_.pm"; # dies if the file is not found
          }
      }

      {
          no strict 'refs';
          push @{"$inheritor\::ISA"}, @_;
      };
  };

  "All your base are belong to us"

  __END__

PARENT

$fatpacked{"version.pm"} = <<'VERSION';
  #!perl -w
  package version;

  use 5.005_04;
  use strict;

  use vars qw(@ISA $VERSION $CLASS $STRICT $LAX *declare *qv);

  $VERSION = 0.88;

  $CLASS = 'version';

  #--------------------------------------------------------------------------#
  # Version regexp components
  #--------------------------------------------------------------------------#

  # Fraction part of a decimal version number.  This is a common part of
  # both strict and lax decimal versions

  my $FRACTION_PART = qr/\.[0-9]+/;

  # First part of either decimal or dotted-decimal strict version number.
  # Unsigned integer with no leading zeroes (except for zero itself) to
  # avoid confusion with octal.

  my $STRICT_INTEGER_PART = qr/0|[1-9][0-9]*/;

  # First part of either decimal or dotted-decimal lax version number.
  # Unsigned integer, but allowing leading zeros.  Always interpreted
  # as decimal.  However, some forms of the resulting syntax give odd
  # results if used as ordinary Perl expressions, due to how perl treats
  # octals.  E.g.
  #   version->new("010" ) == 10
  #   version->new( 010  ) == 8
  #   version->new( 010.2) == 82  # "8" . "2"

  my $LAX_INTEGER_PART = qr/[0-9]+/;

  # Second and subsequent part of a strict dotted-decimal version number.
  # Leading zeroes are permitted, and the number is always decimal.
  # Limited to three digits to avoid overflow when converting to decimal
  # form and also avoid problematic style with excessive leading zeroes.

  my $STRICT_DOTTED_DECIMAL_PART = qr/\.[0-9]{1,3}/;

  # Second and subsequent part of a lax dotted-decimal version number.
  # Leading zeroes are permitted, and the number is always decimal.  No
  # limit on the numerical value or number of digits, so there is the
  # possibility of overflow when converting to decimal form.

  my $LAX_DOTTED_DECIMAL_PART = qr/\.[0-9]+/;

  # Alpha suffix part of lax version number syntax.  Acts like a
  # dotted-decimal part.

  my $LAX_ALPHA_PART = qr/_[0-9]+/;

  #--------------------------------------------------------------------------#
  # Strict version regexp definitions
  #--------------------------------------------------------------------------#

  # Strict decimal version number.

  my $STRICT_DECIMAL_VERSION =
      qr/ $STRICT_INTEGER_PART $FRACTION_PART? /x;

  # Strict dotted-decimal version number.  Must have both leading "v" and
  # at least three parts, to avoid confusion with decimal syntax.

  my $STRICT_DOTTED_DECIMAL_VERSION =
      qr/ v $STRICT_INTEGER_PART $STRICT_DOTTED_DECIMAL_PART{2,} /x;

  # Complete strict version number syntax -- should generally be used
  # anchored: qr/ \A $STRICT \z /x

  $STRICT =
      qr/ $STRICT_DECIMAL_VERSION | $STRICT_DOTTED_DECIMAL_VERSION /x;

  #--------------------------------------------------------------------------#
  # Lax version regexp definitions
  #--------------------------------------------------------------------------#

  # Lax decimal version number.  Just like the strict one except for
  # allowing an alpha suffix or allowing a leading or trailing
  # decimal-point

  my $LAX_DECIMAL_VERSION =
      qr/ $LAX_INTEGER_PART (?: \. | $FRACTION_PART $LAX_ALPHA_PART? )?
    |
    $FRACTION_PART $LAX_ALPHA_PART?
      /x;

  # Lax dotted-decimal version number.  Distinguished by having either
  # leading "v" or at least three non-alpha parts.  Alpha part is only
  # permitted if there are at least two non-alpha parts. Strangely
  # enough, without the leading "v", Perl takes .1.2 to mean v0.1.2,
  # so when there is no "v", the leading part is optional

  my $LAX_DOTTED_DECIMAL_VERSION =
      qr/
    v $LAX_INTEGER_PART (?: $LAX_DOTTED_DECIMAL_PART+ $LAX_ALPHA_PART? )?
    |
    $LAX_INTEGER_PART? $LAX_DOTTED_DECIMAL_PART{2,} $LAX_ALPHA_PART?
      /x;

  # Complete lax version number syntax -- should generally be used
  # anchored: qr/ \A $LAX \z /x
  #
  # The string 'undef' is a special case to make for easier handling
  # of return values from ExtUtils::MM->parse_version

  $LAX =
      qr/ undef | $LAX_DECIMAL_VERSION | $LAX_DOTTED_DECIMAL_VERSION /x;

  #--------------------------------------------------------------------------#

  eval "use version::vxs $VERSION";
  if ( $@ ) { # don't have the XS version installed
      eval "use version::vpp $VERSION"; # don't tempt fate
      die "$@" if ( $@ );
      push @ISA, "version::vpp";
      local $^W;
      *version::qv = \&version::vpp::qv;
      *version::declare = \&version::vpp::declare;
      *version::_VERSION = \&version::vpp::_VERSION;
      if ($] >= 5.009000 && $] < 5.011004) {
    no strict 'refs';
    *version::stringify = \&version::vpp::stringify;
    *{'version::(""'} = \&version::vpp::stringify;
    *version::new = \&version::vpp::new;
    *version::parse = \&version::vpp::parse;
      }
  }
  else { # use XS module
      push @ISA, "version::vxs";
      local $^W;
      *version::declare = \&version::vxs::declare;
      *version::qv = \&version::vxs::qv;
      *version::_VERSION = \&version::vxs::_VERSION;
      *version::vcmp = \&version::vxs::VCMP;
      if ($] >= 5.009000 && $] < 5.011004) {
    no strict 'refs';
    *version::stringify = \&version::vxs::stringify;
    *{'version::(""'} = \&version::vxs::stringify;
    *version::new = \&version::vxs::new;
    *version::parse = \&version::vxs::parse;
      }

  }

  # Preloaded methods go here.
  sub import {
      no strict 'refs';
      my ($class) = shift;

      # Set up any derived class
      unless ($class eq 'version') {
    local $^W;
    *{$class.'::declare'} =  \&version::declare;
    *{$class.'::qv'} = \&version::qv;
      }

      my %args;
      if (@_) { # any remaining terms are arguments
    map { $args{$_} = 1 } @_
      }
      else { # no parameters at all on use line
        %args =
    (
        qv => 1,
        'UNIVERSAL::VERSION' => 1,
    );
      }

      my $callpkg = caller();

      if (exists($args{declare})) {
    *{$callpkg.'::declare'} =
        sub {return $class->declare(shift) }
      unless defined(&{$callpkg.'::declare'});
      }

      if (exists($args{qv})) {
    *{$callpkg.'::qv'} =
        sub {return $class->qv(shift) }
      unless defined(&{$callpkg.'::qv'});
      }

      if (exists($args{'UNIVERSAL::VERSION'})) {
    local $^W;
    *UNIVERSAL::VERSION
      = \&version::_VERSION;
      }

      if (exists($args{'VERSION'})) {
    *{$callpkg.'::VERSION'} = \&version::_VERSION;
      }

      if (exists($args{'is_strict'})) {
    *{$callpkg.'::is_strict'} = \&version::is_strict
      unless defined(&{$callpkg.'::is_strict'});
      }

      if (exists($args{'is_lax'})) {
    *{$callpkg.'::is_lax'} = \&version::is_lax
      unless defined(&{$callpkg.'::is_lax'});
      }
  }

  sub is_strict { defined $_[0] && $_[0] =~ qr/ \A $STRICT \z /x }
  sub is_lax  { defined $_[0] && $_[0] =~ qr/ \A $LAX \z /x }

  1;
VERSION

$fatpacked{"Version/Requirements.pm"} = <<'VERSION_REQUIREMENTS';
  use strict;
  use warnings;
  package Version::Requirements;
  BEGIN {
    $Version::Requirements::VERSION = '0.101020';
  }
  # ABSTRACT: a set of version requirements for a CPAN dist


  use Carp ();
  use Scalar::Util ();
  use version 0.77 (); # the ->parse method


  sub new {
    my ($class) = @_;
    return bless {} => $class;
  }

  sub _version_object {
    my ($self, $version) = @_;

    $version = (! defined $version)                ? version->parse(0)
             : (! Scalar::Util::blessed($version)) ? version->parse($version)
             :                                       $version;

    return $version;
  }


  BEGIN {
    for my $type (qw(minimum maximum exclusion exact_version)) {
      my $method = "with_$type";
      my $to_add = $type eq 'exact_version' ? $type : "add_$type";

      my $code = sub {
        my ($self, $name, $version) = @_;

        $version = $self->_version_object( $version );

        $self->__modify_entry_for($name, $method, $version);

        return $self;
      };

      no strict 'refs';
      *$to_add = $code;
    }
  }


  sub add_requirements {
    my ($self, $req) = @_;

    for my $module ($req->required_modules) {
      my $modifiers = $req->__entry_for($module)->as_modifiers;
      for my $modifier (@$modifiers) {
        my ($method, @args) = @$modifier;
        $self->$method($module => @args);
      };
    }

    return $self;
  }


  sub accepts_module {
    my ($self, $module, $version) = @_;

    $version = $self->_version_object( $version );

    return 1 unless my $range = $self->__entry_for($module);
    return $range->_accepts($version);
  }


  sub clear_requirement {
    my ($self, $module) = @_;

    return $self unless $self->__entry_for($module);

    Carp::confess("can't clear requirements on finalized requirements")
      if $self->is_finalized;

    delete $self->{requirements}{ $module };

    return $self;
  }


  sub required_modules { keys %{ $_[0]{requirements} } }


  sub clone {
    my ($self) = @_;
    my $new = (ref $self)->new;

    return $new->add_requirements($self);
  }

  sub __entry_for     { $_[0]{requirements}{ $_[1] } }

  sub __modify_entry_for {
    my ($self, $name, $method, $version) = @_;

    my $fin = $self->is_finalized;
    my $old = $self->__entry_for($name);

    Carp::confess("can't add new requirements to finalized requirements")
      if $fin and not $old;

    my $new = ($old || 'Version::Requirements::_Range::Range')
            ->$method($version);

    Carp::confess("can't modify finalized requirements")
      if $fin and $old->as_string ne $new->as_string;

    $self->{requirements}{ $name } = $new;
  }


  sub is_simple {
    my ($self) = @_;
    for my $module ($self->required_modules) {
      # XXX: This is a complete hack, but also entirely correct.
      return if $self->__entry_for($module)->as_string =~ /\s/;
    }

    return 1;
  }


  sub is_finalized { $_[0]{finalized} }


  sub finalize { $_[0]{finalized} = 1 }


  sub as_string_hash {
    my ($self) = @_;

    my %hash = map {; $_ => $self->{requirements}{$_}->as_string }
               $self->required_modules;

    return \%hash;
  }


  my %methods_for_op = (
    '==' => [ qw(exact_version) ],
    '!=' => [ qw(add_exclusion) ],
    '>=' => [ qw(add_minimum)   ],
    '<=' => [ qw(add_maximum)   ],
    '>'  => [ qw(add_minimum add_exclusion) ],
    '<'  => [ qw(add_maximum add_exclusion) ],
  );

  sub from_string_hash {
    my ($class, $hash) = @_;

    my $self = $class->new;

    for my $module (keys %$hash) {
      my @parts = split qr{\s*,\s*}, $hash->{ $module };
      for my $part (@parts) {
        my ($op, $ver) = split /\s+/, $part, 2;

        if (! defined $ver) {
          $self->add_minimum($module => $op);
        } else {
          Carp::confess("illegal requirement string: $hash->{ $module }")
            unless my $methods = $methods_for_op{ $op };

          $self->$_($module => $ver) for @$methods;
        }
      }
    }

    return $self;
  }

  ##############################################################

  {
    package
      Version::Requirements::_Range::Exact;
  BEGIN {
    $Version::Requirements::_Range::Exact::VERSION = '0.101020';
  }
    sub _new     { bless { version => $_[1] } => $_[0] }

    sub _accepts { return $_[0]{version} == $_[1] }

    sub as_string { return "== $_[0]{version}" }

    sub as_modifiers { return [ [ exact_version => $_[0]{version} ] ] }

    sub _clone {
      (ref $_[0])->_new( version->new( $_[0]{version} ) )
    }

    sub with_exact_version {
      my ($self, $version) = @_;

      return $self->_clone if $self->_accepts($version);

      Carp::confess("illegal requirements: unequal exact version specified");
    }

    sub with_minimum {
      my ($self, $minimum) = @_;
      return $self->_clone if $self->{version} >= $minimum;
      Carp::confess("illegal requirements: minimum above exact specification");
    }

    sub with_maximum {
      my ($self, $maximum) = @_;
      return $self->_clone if $self->{version} <= $maximum;
      Carp::confess("illegal requirements: maximum below exact specification");
    }

    sub with_exclusion {
      my ($self, $exclusion) = @_;
      return $self->_clone unless $exclusion == $self->{version};
      Carp::confess("illegal requirements: excluded exact specification");
    }
  }

  ##############################################################

  {
    package
      Version::Requirements::_Range::Range;
  BEGIN {
    $Version::Requirements::_Range::Range::VERSION = '0.101020';
  }

    sub _self { ref($_[0]) ? $_[0] : (bless { } => $_[0]) }

    sub _clone {
      return (bless { } => $_[0]) unless ref $_[0];

      my ($s) = @_;
      my %guts = (
        (exists $s->{minimum} ? (minimum => version->new($s->{minimum})) : ()),
        (exists $s->{maximum} ? (maximum => version->new($s->{maximum})) : ()),

        (exists $s->{exclusions}
          ? (exclusions => [ map { version->new($_) } @{ $s->{exclusions} } ])
          : ()),
      );

      bless \%guts => ref($s);
    }

    sub as_modifiers {
      my ($self) = @_;
      my @mods;
      push @mods, [ add_minimum => $self->{minimum} ] if exists $self->{minimum};
      push @mods, [ add_maximum => $self->{maximum} ] if exists $self->{maximum};
      push @mods, map {; [ add_exclusion => $_ ] } @{$self->{exclusions} || []};
      return \@mods;
    }

    sub as_string {
      my ($self) = @_;

      return 0 if ! keys %$self;

      return "$self->{minimum}" if (keys %$self) == 1 and exists $self->{minimum};

      my @exclusions = @{ $self->{exclusions} || [] };

      my @parts;

      for my $pair (
        [ qw( >= > minimum ) ],
        [ qw( <= < maximum ) ],
      ) {
        my ($op, $e_op, $k) = @$pair;
        if (exists $self->{$k}) {
          my @new_exclusions = grep { $_ != $self->{ $k } } @exclusions;
          if (@new_exclusions == @exclusions) {
            push @parts, "$op $self->{ $k }";
          } else {
            push @parts, "$e_op $self->{ $k }";
            @exclusions = @new_exclusions;
          }
        }
      }

      push @parts, map {; "!= $_" } @exclusions;

      return join q{, }, @parts;
    }

    sub with_exact_version {
      my ($self, $version) = @_;
      $self = $self->_clone;

      Carp::confess("illegal requirements: exact specification outside of range")
        unless $self->_accepts($version);

      return Version::Requirements::_Range::Exact->_new($version);
    }

    sub _simplify {
      my ($self) = @_;

      if (defined $self->{minimum} and defined $self->{maximum}) {
        if ($self->{minimum} == $self->{maximum}) {
          Carp::confess("illegal requirements: excluded all values")
            if grep { $_ == $self->{minimum} } @{ $self->{exclusions} || [] };

          return Version::Requirements::_Range::Exact->_new($self->{minimum})
        }

        Carp::confess("illegal requirements: minimum exceeds maximum")
          if $self->{minimum} > $self->{maximum};
      }

      # eliminate irrelevant exclusions
      if ($self->{exclusions}) {
        my %seen;
        @{ $self->{exclusions} } = grep {
          (! defined $self->{minimum} or $_ >= $self->{minimum})
          and
          (! defined $self->{maximum} or $_ <= $self->{maximum})
          and
          ! $seen{$_}++
        } @{ $self->{exclusions} };
      }

      return $self;
    }

    sub with_minimum {
      my ($self, $minimum) = @_;
      $self = $self->_clone;

      if (defined (my $old_min = $self->{minimum})) {
        $self->{minimum} = (sort { $b cmp $a } ($minimum, $old_min))[0];
      } else {
        $self->{minimum} = $minimum;
      }

      return $self->_simplify;
    }

    sub with_maximum {
      my ($self, $maximum) = @_;
      $self = $self->_clone;

      if (defined (my $old_max = $self->{maximum})) {
        $self->{maximum} = (sort { $a cmp $b } ($maximum, $old_max))[0];
      } else {
        $self->{maximum} = $maximum;
      }

      return $self->_simplify;
    }

    sub with_exclusion {
      my ($self, $exclusion) = @_;
      $self = $self->_clone;

      push @{ $self->{exclusions} ||= [] }, $exclusion;

      return $self->_simplify;
    }

    sub _accepts {
      my ($self, $version) = @_;

      return if defined $self->{minimum} and $version < $self->{minimum};
      return if defined $self->{maximum} and $version > $self->{maximum};
      return if defined $self->{exclusions}
            and grep { $version == $_ } @{ $self->{exclusions} };

      return 1;
    }
  }

  1;

  __END__
  =pod

VERSION_REQUIREMENTS

$fatpacked{"version/vpp.pm"} = <<'VERSION_VPP';
  package charstar;
  # a little helper class to emulate C char* semantics in Perl
  # so that prescan_version can use the same code as in C

  use overload (
      '""'  => \&thischar,
      '0+'  => \&thischar,
      '++'  => \&increment,
      '--'  => \&decrement,
      '+'   => \&plus,
      '-'   => \&minus,
      '*'   => \&multiply,
      'cmp' => \&cmp,
      '<=>' => \&spaceship,
      'bool'  => \&thischar,
      '='   => \&clone,
  );

  sub new {
      my ($self, $string) = @_;
      my $class = ref($self) || $self;

      my $obj = {
    string  => [split(//,$string)],
    current => 0,
      };
      return bless $obj, $class;
  }

  sub thischar {
      my ($self) = @_;
      my $last = $#{$self->{string}};
      my $curr = $self->{current};
      if ($curr >= 0 && $curr <= $last) {
    return $self->{string}->[$curr];
      }
      else {
    return '';
      }
  }

  sub increment {
      my ($self) = @_;
      $self->{current}++;
  }

  sub decrement {
      my ($self) = @_;
      $self->{current}--;
  }

  sub plus {
      my ($self, $offset) = @_;
      my $rself = $self->clone;
      $rself->{current} += $offset;
      return $rself;
  }

  sub minus {
      my ($self, $offset) = @_;
      my $rself = $self->clone;
      $rself->{current} -= $offset;
      return $rself;
  }

  sub multiply {
      my ($left, $right, $swapped) = @_;
      my $char = $left->thischar();
      return $char * $right;
  }

  sub spaceship {
      my ($left, $right, $swapped) = @_;
      unless (ref($right)) { # not an object already
    $right = $left->new($right);
      }
      return $left->{current} <=> $right->{current};
  }

  sub cmp {
      my ($left, $right, $swapped) = @_;
      unless (ref($right)) { # not an object already
    if (length($right) == 1) { # comparing single character only
        return $left->thischar cmp $right;
    }
    $right = $left->new($right);
      }
      return $left->currstr cmp $right->currstr;
  }

  sub bool {
      my ($self) = @_;
      my $char = $self->thischar;
      return ($char ne '');
  }

  sub clone {
      my ($left, $right, $swapped) = @_;
      $right = {
    string  => [@{$left->{string}}],
    current => $left->{current},
      };
      return bless $right, ref($left);
  }

  sub currstr {
      my ($self, $s) = @_;
      my $curr = $self->{current};
      my $last = $#{$self->{string}};
      if (defined($s) && $s->{current} < $last) {
    $last = $s->{current};
      }

      my $string = join('', @{$self->{string}}[$curr..$last]);
      return $string;
  }

  package version::vpp;
  use strict;

  use POSIX qw/locale_h/;
  use locale;
  use vars qw ($VERSION @ISA @REGEXS);
  $VERSION = 0.88;

  use overload (
      '""'       => \&stringify,
      '0+'       => \&numify,
      'cmp'      => \&vcmp,
      '<=>'      => \&vcmp,
      'bool'     => \&vbool,
      'nomethod' => \&vnoop,
  );

  eval "use warnings";
  if ($@) {
      eval '
    package warnings;
    sub enabled {return $^W;}
    1;
      ';
  }

  my $VERSION_MAX = 0x7FFFFFFF;

  # implement prescan_version as closely to the C version as possible
  use constant TRUE  => 1;
  use constant FALSE => 0;

  sub isDIGIT {
      my ($char) = shift->thischar();
      return ($char =~ /\d/);
  }

  sub isALPHA {
      my ($char) = shift->thischar();
      return ($char =~ /[a-zA-Z]/);
  }

  sub isSPACE {
      my ($char) = shift->thischar();
      return ($char =~ /\s/);
  }

  sub BADVERSION {
      my ($s, $errstr, $error) = @_;
      if ($errstr) {
    $$errstr = $error;
      }
      return $s;
  }

  sub prescan_version {
      my ($s, $strict, $errstr, $sqv, $ssaw_decimal, $swidth, $salpha) = @_;
      my $qv          = defined $sqv          ? $$sqv          : FALSE;
      my $saw_decimal = defined $ssaw_decimal ? $$ssaw_decimal : 0;
      my $width       = defined $swidth       ? $$swidth       : 3;
      my $alpha       = defined $salpha       ? $$salpha       : FALSE;

      my $d = $s;

      if ($qv && isDIGIT($d)) {
    goto dotted_decimal_version;
      }

      if ($d eq 'v') { # explicit v-string
    $d++;
    if (isDIGIT($d)) {
        $qv = TRUE;
    }
    else { # degenerate v-string
        # requires v1.2.3
        return BADVERSION($s,$errstr,"Invalid version format (dotted-decimal versions require at least three parts)");
    }

  dotted_decimal_version:
    if ($strict && $d eq '0' && isDIGIT($d+1)) {
        # no leading zeros allowed
        return BADVERSION($s,$errstr,"Invalid version format (no leading zeros)");
    }

    while (isDIGIT($d)) {   # integer part
        $d++;
    }

    if ($d eq '.')
    {
        $saw_decimal++;
        $d++;     # decimal point
    }
    else
    {
        if ($strict) {
      # require v1.2.3
      return BADVERSION($s,$errstr,"Invalid version format (dotted-decimal versions require at least three parts)");
        }
        else {
      goto version_prescan_finish;
        }
    }

    {
        my $i = 0;
        my $j = 0;
        while (isDIGIT($d)) { # just keep reading
      $i++;
      while (isDIGIT($d)) {
          $d++; $j++;
          # maximum 3 digits between decimal
          if ($strict && $j > 3) {
        return BADVERSION($s,$errstr,"Invalid version format (maximum 3 digits between decimals)");
          }
      }
      if ($d eq '_') {
          if ($strict) {
        return BADVERSION($s,$errstr,"Invalid version format (no underscores)");
          }
          if ( $alpha ) {
        return BADVERSION($s,$errstr,"Invalid version format (multiple underscores)");
          }
          $d++;
          $alpha = TRUE;
      }
      elsif ($d eq '.') {
          if ($alpha) {
        return BADVERSION($s,$errstr,"Invalid version format (underscores before decimal)");
          }
          $saw_decimal++;
          $d++;
      }
      elsif (!isDIGIT($d)) {
          last;
      }
      $j = 0;
        }

        if ($strict && $i < 2) {
      # requires v1.2.3
      return BADVERSION($s,$errstr,"Invalid version format (dotted-decimal versions require at least three parts)");
        }
    }
      }           # end if dotted-decimal
      else
      {         # decimal versions
    # special $strict case for leading '.' or '0'
    if ($strict) {
        if ($d eq '.') {
      return BADVERSION($s,$errstr,"Invalid version format (0 before decimal required)");
        }
        if ($d eq '0' && isDIGIT($d+1)) {
      return BADVERSION($s,$errstr,"Invalid version format (no leading zeros)");
        }
    }

    # consume all of the integer part
    while (isDIGIT($d)) {
        $d++;
    }

    # look for a fractional part
    if ($d eq '.') {
        # we found it, so consume it
        $saw_decimal++;
        $d++;
    }
    elsif (!$d || $d eq ';' || isSPACE($d) || $d eq '}') {
        if ( $d == $s ) {
      # found nothing
      return BADVERSION($s,$errstr,"Invalid version format (version required)");
        }
        # found just an integer
        goto version_prescan_finish;
    }
    elsif ( $d == $s ) {
        # didn't find either integer or period
        return BADVERSION($s,$errstr,"Invalid version format (non-numeric data)");
    }
    elsif ($d eq '_') {
        # underscore can't come after integer part
        if ($strict) {
      return BADVERSION($s,$errstr,"Invalid version format (no underscores)");
        }
        elsif (isDIGIT($d+1)) {
      return BADVERSION($s,$errstr,"Invalid version format (alpha without decimal)");
        }
        else {
      return BADVERSION($s,$errstr,"Invalid version format (misplaced underscore)");
        }
    }
    elsif ($d) {
        # anything else after integer part is just invalid data
        return BADVERSION($s,$errstr,"Invalid version format (non-numeric data)");
    }

    # scan the fractional part after the decimal point
    if ($d && !isDIGIT($d) && ($strict || ! ($d eq ';' || isSPACE($d) || $d eq '}') )) {
      # $strict or lax-but-not-the-end
      return BADVERSION($s,$errstr,"Invalid version format (fractional part required)");
    }

    while (isDIGIT($d)) {
        $d++;
        if ($d eq '.' && isDIGIT($d-1)) {
      if ($alpha) {
          return BADVERSION($s,$errstr,"Invalid version format (underscores before decimal)");
      }
      if ($strict) {
          return BADVERSION($s,$errstr,"Invalid version format (dotted-decimal versions must begin with 'v')");
      }
      $d = $s; # start all over again
      $qv = TRUE;
      goto dotted_decimal_version;
        }
        if ($d eq '_') {
      if ($strict) {
          return BADVERSION($s,$errstr,"Invalid version format (no underscores)");
      }
      if ( $alpha ) {
          return BADVERSION($s,$errstr,"Invalid version format (multiple underscores)");
      }
      if ( ! isDIGIT($d+1) ) {
          return BADVERSION($s,$errstr,"Invalid version format (misplaced underscore)");
      }
      $d++;
      $alpha = TRUE;
        }
    }
      }

  version_prescan_finish:
      while (isSPACE($d)) {
    $d++;
      }

      if ($d && !isDIGIT($d) && (! ($d eq ';' || $d eq '}') )) {
    # trailing non-numeric data
    return BADVERSION($s,$errstr,"Invalid version format (non-numeric data)");
      }

      if (defined $sqv) {
    $$sqv = $qv;
      }
      if (defined $swidth) {
    $$swidth = $width;
      }
      if (defined $ssaw_decimal) {
    $$ssaw_decimal = $saw_decimal;
      }
      if (defined $salpha) {
    $$salpha = $alpha;
      }
      return $d;
  }

  sub scan_version {
      my ($s, $rv, $qv) = @_;
      my $start;
      my $pos;
      my $last;
      my $errstr;
      my $saw_decimal = 0;
      my $width = 3;
      my $alpha = FALSE;
      my $vinf = FALSE;
      my @av;

      $s = new charstar $s;

      while (isSPACE($s)) { # leading whitespace is OK
    $s++;
      }

      $last = prescan_version($s, FALSE, \$errstr, \$qv, \$saw_decimal,
    \$width, \$alpha);

      if ($errstr) {
    # 'undef' is a special case and not an error
    if ( $s ne 'undef') {
        use Carp;
        Carp::croak($errstr);
    }
      }

      $start = $s;
      if ($s eq 'v') {
    $s++;
      }
      $pos = $s;

      if ( $qv ) {
    $$rv->{qv} = $qv;
      }
      if ( $alpha ) {
    $$rv->{alpha} = $alpha;
      }
      if ( !$qv && $width < 3 ) {
    $$rv->{width} = $width;
      }

      while (isDIGIT($pos)) {
    $pos++;
      }
      if (!isALPHA($pos)) {
    my $rev;

    for (;;) {
        $rev = 0;
        {
        # this is atoi() that delimits on underscores
        my $end = $pos;
        my $mult = 1;
      my $orev;

      #  the following if() will only be true after the decimal
      #  point of a version originally created with a bare
      #  floating point number, i.e. not quoted in any way
      #
      if ( !$qv && $s > $start && $saw_decimal == 1 ) {
          $mult *= 100;
          while ( $s < $end ) {
        $orev = $rev;
        $rev += $s * $mult;
        $mult /= 10;
        if (   (abs($orev) > abs($rev))
            || (abs($rev) > $VERSION_MAX )) {
            warn("Integer overflow in version %d",
               $VERSION_MAX);
            $s = $end - 1;
            $rev = $VERSION_MAX;
            $vinf = 1;
        }
        $s++;
        if ( $s eq '_' ) {
            $s++;
        }
          }
        }
      else {
          while (--$end >= $s) {
        $orev = $rev;
        $rev += $end * $mult;
        $mult *= 10;
        if (   (abs($orev) > abs($rev))
            || (abs($rev) > $VERSION_MAX )) {
            warn("Integer overflow in version");
            $end = $s - 1;
            $rev = $VERSION_MAX;
            $vinf = 1;
        }
          }
      }
          }

          # Append revision
        push @av, $rev;
        if ( $vinf ) {
      $s = $last;
      last;
        }
        elsif ( $pos eq '.' ) {
      $s = ++$pos;
        }
        elsif ( $pos eq '_' && isDIGIT($pos+1) ) {
      $s = ++$pos;
        }
        elsif ( $pos eq ',' && isDIGIT($pos+1) ) {
      $s = ++$pos;
        }
        elsif ( isDIGIT($pos) ) {
      $s = $pos;
        }
        else {
      $s = $pos;
      last;
        }
        if ( $qv ) {
      while ( isDIGIT($pos) ) {
          $pos++;
      }
        }
        else {
      my $digits = 0;
      while ( ( isDIGIT($pos) || $pos eq '_' ) && $digits < 3 ) {
          if ( $pos ne '_' ) {
        $digits++;
          }
          $pos++;
      }
        }
    }
      }
      if ( $qv ) { # quoted versions always get at least three terms
    my $len = $#av;
    #  This for loop appears to trigger a compiler bug on OS X, as it
    #  loops infinitely. Yes, len is negative. No, it makes no sense.
    #  Compiler in question is:
    #  gcc version 3.3 20030304 (Apple Computer, Inc. build 1640)
    #  for ( len = 2 - len; len > 0; len-- )
    #  av_push(MUTABLE_AV(sv), newSViv(0));
    #
    $len = 2 - $len;
    while ($len-- > 0) {
        push @av, 0;
    }
      }

      # need to save off the current version string for later
      if ( $vinf ) {
    $$rv->{original} = "v.Inf";
    $$rv->{vinf} = 1;
      }
      elsif ( $s > $start ) {
    $$rv->{original} = $start->currstr($s);
    if ( $qv && $saw_decimal == 1 && $start ne 'v' ) {
        # need to insert a v to be consistent
        $$rv->{original} = 'v' . $$rv->{original};
    }
      }
      else {
    $$rv->{original} = '0';
    push(@av, 0);
      }

      # And finally, store the AV in the hash
      $$rv->{version} = \@av;

      # fix RT#19517 - special case 'undef' as string
      if ($s eq 'undef') {
    $s += 5;
      }

      return $s;
  }

  sub new
  {
    my ($class, $value) = @_;
    my $self = bless ({}, ref ($class) || $class);
    my $qv = FALSE;

    if ( ref($value) && eval('$value->isa("version")') ) {
        # Can copy the elements directly
        $self->{version} = [ @{$value->{version} } ];
        $self->{qv} = 1 if $value->{qv};
        $self->{alpha} = 1 if $value->{alpha};
        $self->{original} = ''.$value->{original};
        return $self;
    }

    my $currlocale = setlocale(LC_ALL);

    # if the current locale uses commas for decimal points, we
    # just replace commas with decimal places, rather than changing
    # locales
    if ( localeconv()->{decimal_point} eq ',' ) {
        $value =~ tr/,/./;
    }

    if ( not defined $value or $value =~ /^undef$/ ) {
        # RT #19517 - special case for undef comparison
        # or someone forgot to pass a value
        push @{$self->{version}}, 0;
        $self->{original} = "0";
        return ($self);
    }

    if ( $#_ == 2 ) { # must be CVS-style
        $value = $_[2];
        $qv = TRUE;
    }

    $value = _un_vstring($value);

    # exponential notation
    if ( $value =~ /\d+.?\d*e[-+]?\d+/ ) {
        $value = sprintf("%.9f",$value);
        $value =~ s/(0+)$//; # trim trailing zeros
    }

    my $s = scan_version($value, \$self, $qv);

    if ($s) { # must be something left over
        warn("Version string '%s' contains invalid data; "
                         ."ignoring: '%s'", $value, $s);
    }

    return ($self);
  }

  *parse = \&new;

  sub numify
  {
      my ($self) = @_;
      unless (_verify($self)) {
    require Carp;
    Carp::croak("Invalid version object");
      }
      my $width = $self->{width} || 3;
      my $alpha = $self->{alpha} || "";
      my $len = $#{$self->{version}};
      my $digit = $self->{version}[0];
      my $string = sprintf("%d.", $digit );

      for ( my $i = 1 ; $i < $len ; $i++ ) {
    $digit = $self->{version}[$i];
    if ( $width < 3 ) {
        my $denom = 10**(3-$width);
        my $quot = int($digit/$denom);
        my $rem = $digit - ($quot * $denom);
        $string .= sprintf("%0".$width."d_%d", $quot, $rem);
    }
    else {
        $string .= sprintf("%03d", $digit);
    }
      }

      if ( $len > 0 ) {
    $digit = $self->{version}[$len];
    if ( $alpha && $width == 3 ) {
        $string .= "_";
    }
    $string .= sprintf("%0".$width."d", $digit);
      }
      else # $len = 0
      {
    $string .= sprintf("000");
      }

      return $string;
  }

  sub normal
  {
      my ($self) = @_;
      unless (_verify($self)) {
    require Carp;
    Carp::croak("Invalid version object");
      }
      my $alpha = $self->{alpha} || "";
      my $len = $#{$self->{version}};
      my $digit = $self->{version}[0];
      my $string = sprintf("v%d", $digit );

      for ( my $i = 1 ; $i < $len ; $i++ ) {
    $digit = $self->{version}[$i];
    $string .= sprintf(".%d", $digit);
      }

      if ( $len > 0 ) {
    $digit = $self->{version}[$len];
    if ( $alpha ) {
        $string .= sprintf("_%0d", $digit);
    }
    else {
        $string .= sprintf(".%0d", $digit);
    }
      }

      if ( $len <= 2 ) {
    for ( $len = 2 - $len; $len != 0; $len-- ) {
        $string .= sprintf(".%0d", 0);
    }
      }

      return $string;
  }

  sub stringify
  {
      my ($self) = @_;
      unless (_verify($self)) {
    require Carp;
    Carp::croak("Invalid version object");
      }
      return exists $self->{original}
        ? $self->{original}
    : exists $self->{qv}
        ? $self->normal
        : $self->numify;
  }

  sub vcmp
  {
      require UNIVERSAL;
      my ($left,$right,$swap) = @_;
      my $class = ref($left);
      unless ( UNIVERSAL::isa($right, $class) ) {
    $right = $class->new($right);
      }

      if ( $swap ) {
    ($left, $right) = ($right, $left);
      }
      unless (_verify($left)) {
    require Carp;
    Carp::croak("Invalid version object");
      }
      unless (_verify($right)) {
    require Carp;
    Carp::croak("Invalid version object");
      }
      my $l = $#{$left->{version}};
      my $r = $#{$right->{version}};
      my $m = $l < $r ? $l : $r;
      my $lalpha = $left->is_alpha;
      my $ralpha = $right->is_alpha;
      my $retval = 0;
      my $i = 0;
      while ( $i <= $m && $retval == 0 ) {
    $retval = $left->{version}[$i] <=> $right->{version}[$i];
    $i++;
      }

      # tiebreaker for alpha with identical terms
      if ( $retval == 0
    && $l == $r
    && $left->{version}[$m] == $right->{version}[$m]
    && ( $lalpha || $ralpha ) ) {

    if ( $lalpha && !$ralpha ) {
        $retval = -1;
    }
    elsif ( $ralpha && !$lalpha) {
        $retval = +1;
    }
      }

      # possible match except for trailing 0's
      if ( $retval == 0 && $l != $r ) {
    if ( $l < $r ) {
        while ( $i <= $r && $retval == 0 ) {
      if ( $right->{version}[$i] != 0 ) {
          $retval = -1; # not a match after all
      }
      $i++;
        }
    }
    else {
        while ( $i <= $l && $retval == 0 ) {
      if ( $left->{version}[$i] != 0 ) {
          $retval = +1; # not a match after all
      }
      $i++;
        }
    }
      }

      return $retval;
  }

  sub vbool {
      my ($self) = @_;
      return vcmp($self,$self->new("0"),1);
  }

  sub vnoop {
      require Carp;
      Carp::croak("operation not supported with version object");
  }

  sub is_alpha {
      my ($self) = @_;
      return (exists $self->{alpha});
  }

  sub qv {
      my $value = shift;
      my $class = 'version';
      if (@_) {
    $class = ref($value) || $value;
    $value = shift;
      }

      $value = _un_vstring($value);
      $value = 'v'.$value unless $value =~ /(^v|\d+\.\d+\.\d)/;
      my $version = $class->new($value);
      return $version;
  }

  *declare = \&qv;

  sub is_qv {
      my ($self) = @_;
      return (exists $self->{qv});
  }


  sub _verify {
      my ($self) = @_;
      if ( ref($self)
    && eval { exists $self->{version} }
    && ref($self->{version}) eq 'ARRAY'
    ) {
    return 1;
      }
      else {
    return 0;
      }
  }

  sub _is_non_alphanumeric {
      my $s = shift;
      $s = new charstar $s;
      while ($s) {
    return 0 if isSPACE($s); # early out
    return 1 unless (isALPHA($s) || isDIGIT($s) || $s =~ /[.-]/);
    $s++;
      }
      return 0;
  }

  sub _un_vstring {
      my $value = shift;
      # may be a v-string
      if ( length($value) >= 3 && $value !~ /[._]/
    && _is_non_alphanumeric($value)) {
    my $tvalue;
    if ( $] ge 5.008_001 ) {
        $tvalue = _find_magic_vstring($value);
        $value = $tvalue if length $tvalue;
    }
    elsif ( $] ge 5.006_000 ) {
        $tvalue = sprintf("v%vd",$value);
        if ( $tvalue =~ /^v\d+(\.\d+){2,}$/ ) {
      # must be a v-string
      $value = $tvalue;
        }
    }
      }
      return $value;
  }

  sub _find_magic_vstring {
      my $value = shift;
      my $tvalue = '';
      require B;
      my $sv = B::svref_2object(\$value);
      my $magic = ref($sv) eq 'B::PVMG' ? $sv->MAGIC : undef;
      while ( $magic ) {
    if ( $magic->TYPE eq 'V' ) {
        $tvalue = $magic->PTR;
        $tvalue =~ s/^v?(.+)$/v$1/;
        last;
    }
    else {
        $magic = $magic->MOREMAGIC;
    }
      }
      return $tvalue;
  }

  sub _VERSION {
      my ($obj, $req) = @_;
      my $class = ref($obj) || $obj;

      no strict 'refs';
      if ( exists $INC{"$class.pm"} and not %{"$class\::"} and $] >= 5.008) {
     # file but no package
    require Carp;
    Carp::croak( "$class defines neither package nor VERSION"
        ."--version check failed");
      }

      my $version = eval "\$$class\::VERSION";
      if ( defined $version ) {
    local $^W if $] <= 5.008;
    $version = version::vpp->new($version);
      }

      if ( defined $req ) {
    unless ( defined $version ) {
        require Carp;
        my $msg =  $] < 5.006
        ? "$class version $req required--this is only version "
        : "$class does not define \$$class\::VERSION"
          ."--version check failed";

        if ( $ENV{VERSION_DEBUG} ) {
      Carp::confess($msg);
        }
        else {
      Carp::croak($msg);
        }
    }

    $req = version::vpp->new($req);

    if ( $req > $version ) {
        require Carp;
        if ( $req->is_qv ) {
      Carp::croak(
          sprintf ("%s version %s required--".
        "this is only version %s", $class,
        $req->normal, $version->normal)
      );
        }
        else {
      Carp::croak(
          sprintf ("%s version %s required--".
        "this is only version %s", $class,
        $req->stringify, $version->stringify)
      );
        }
    }
      }

      return defined $version ? $version->stringify : undef;
  }

  1; #this line is important and will help the module return a true value
VERSION_VPP

s/^  //mg for values %fatpacked;

unshift @INC, sub {
  if (my $fat = $fatpacked{$_[1]}) {
    open my $fh, '<', \$fat
      or die "FatPacker error loading $_[1] (could be a perl installation issue?)";
    return $fh;
  }
  return
};

} # END OF FATPACK CODE

use strict;
use App::cpanminus::script;

unless (caller) {
    my $app = App::cpanminus::script->new;
    $app->parse_options(@ARGV);
    $app->doit or exit(1);
}

__END__

=head1 NAME

cpanm - get, unpack build and install modules from CPAN

=head1 SYNOPSIS

  cpanm Test::More                                 # install Test::More
  cpanm MIYAGAWA/Plack-0.99_05.tar.gz              # full distribution path
  cpanm http://example.org/LDS/CGI.pm-3.20.tar.gz  # install from URL
  cpanm ~/dists/MyCompany-Enterprise-1.00.tar.gz   # install from a local file
  cpanm --interactive Task::Kensho                 # Configure interactively
  cpanm .                                          # install from local directory
  cpanm --installdeps .                            # install all the deps for the current directory
  cpanm -L extlib Plack                            # install Plack and all non-core deps into extlib
  cpanm --mirror http://cpan.cpantesters.org/ DBI  # use the fast-syncing mirror
  cpanm --scandeps Moose                           # See what modules will be installed for Moose

=head1 COMMANDS

=over 4

=item -i, --install

Installs the modules. This is a default behavior and this is just a
compatibility option to make it work like L<cpan> or L<cpanp>.

=item --self-upgrade

Upgrades itself. It's just an alias for:

  cpanm App::cpanminus

=item --info

Displays the distribution information in
C<AUTHOR/Dist-Name-ver.tar.gz> format in the standard out.

=item --installdeps

Installs the dependencies of the target distribution but won't build
itself. Handy if you want to try the application from a version
controlled repository such as git.

  cpanm --installdeps .

=item --look

Download and unpack the distribution and then open the directory with
your shell. Handy to poke around the source code or do manual
testing.

=item -h, --help

Displays the help message.

=item -V, --version

Displays the version number.

=back

=head1 OPTIONS

You can specify the default options in C<PERL_CPANM_OPT> environment variable.

=over 4

=item -f, --force

Force install modules even when testing failed.

=item -n, --notest

Skip the testing of modules. Use this only when you just want to save
time for installing hundreds of distributions to the same perl and
architecture you've already tested to make sure it builds fine.

Defaults to false, and you can say C<--no-notest> to override when it
is set in the default options in C<PERL_CPANM_OPT>.

=item --test-only

Run the tests only, and do not install the specified module or
distributions. Handy if you want to verify the new (or even old)
releases pass its unit tests without installing the module.

Note that if you specify this option with a module or distribution
that has dependencies, these dependencies will be installed if you
don't currently have them.

=item -S, --sudo

Switch to the root user with C<sudo> when installing modules. Use this
if you want to install modules to the system perl include path.

Defaults to false, and you can say C<--no-sudo> to override when it is
set in the default options in C<PERL_CPANM_OPT>.

=item -v, --verbose

Makes the output verbose. It also enables the interactive
configuration. (See --interactive)

=item -q, --quiet

Makes the output even more quiet than the default. It doesn't print
anything to the STDERR.

=item -l, --local-lib

Sets the L<local::lib> compatible path to install modules to. You
don't need to set this if you already configure the shell environment
variables using L<local::lib>, but this can be used to override that
as well.

=item -L, --local-lib-contained

Same with C<--local-lib> but when examining the dependencies, it
assumes no non-core modules are installed on the system. It's handy if
you want to bundle application dependencies in one directory so you
can distribute to other machines.

For instance,

  cpanm -L extlib Plack

would install Plack and all of its non-core dependencies into the
directory C<extlib>, which can be loaded from your application with:

  use local::lib '/path/to/extlib';

=item --mirror

Specifies the base URL for the CPAN mirror to use, such as
C<http://cpan.cpantesters.org/> (you can omit the trailing slash). You
can specify multiple mirror URLs by repeating the command line option.

Defaults to C<http://search.cpan.org/CPAN> which is a geo location
aware redirector.

=item --mirror-only

Download the mirror's 02packages.details.txt.gz index file instead of
querying the CPAN Meta DB.

Select this option if you are using a local mirror of CPAN, such as
minicpan when you're offline, or your own CPAN index (a.k.a darkpan).

B<Tip:> It might be useful if you name these mirror options with your
shell aliases, like:

  alias minicpanm='cpanm --mirror ~/minicpan --mirror-only'
  alias darkpan='cpanm --mirror http://mycompany.example.com/DPAN --mirror-only'

=item --mirror-index

B<EXPERIMENTAL>: Specifies the file path to C<02packages.details.txt>
for module search index.

=item --metacpan

B<EXPERIMENTAL>: Use L<http://api.metacpan.org/> API for module lookup instead of
L<http://cpanmetadb.plackperl.org/>.

=item --prompt

Prompts when a test fails so that you can skip, force install, retry
or look in the shell to see what's going wrong. It also prompts when
one of the dependency failed if you want to proceed the installation.

Defaults to false, and you can say C<--no-prompt> to override if it's
set in the default options in C<PERL_CPANM_OPT>.

=item --reinstall

cpanm, when given a module name in the command line (i.e. C<cpanm
Plack>), checks the locally installed version first and skips if it is
already installed. This option makes it skip the check, so:

  cpanm --reinstall Plack

would reinstall L<Plack> even if your locally installed version is
latest, or even newer (which would happen if you install a developer
release from version control repositories).

Defaults to false.

=item --interactive

Makes the configuration (such as C<Makefile.PL> and C<Build.PL>)
interactive, so you can answer questions in the distribution that
requires custom configuration or Task:: distributions.

Defaults to false, and you can say C<--no-interactive> to override
when it's set in the default options in C<PERL_CPANM_OPT>.

=item --scandeps

Scans the depencencies of given modules and output the tree in a text
format. (See C<--format> below for more options)

Because this command doesn't actually install any distributions, it
will be useful that by typing:

  cpanm --scandeps Catalyst::Runtime

you can make sure what modules will be installed.

This command takes into account which modules you already have
installed in your system. If you want to see what modules will be
installed against a vanilla perl installation, you might want to
combine it with C<-L> option.

=item --format

Determines what format to display the scanned dependency
tree. Available options are C<tree>, C<json>, C<yaml> and C<dists>.

=over 8

=item tree

Displays the tree in a plain text format. This is the default value.

=item json, yaml

Outputs the tree in a JSON or YAML format. L<JSON> and L<YAML> modules
need to be installed respectively. The output tree is represented as a
recursive tuple of:

  [ distribution, dependencies ]

and the container is an array containing the root elements. Note that
there may be multiple root nodes, since you can give multiple modules
to the C<--scandeps> command.

=item dists

C<dists> is a special output format, where it prints the distribution
filename in the I<depth first order> after the dependency resolution,
like:

  GAAS/MIME-Base64-3.13.tar.gz
  GAAS/URI-1.58.tar.gz
  PETDANCE/HTML-Tagset-3.20.tar.gz
  GAAS/HTML-Parser-3.68.tar.gz
  GAAS/libwww-perl-5.837.tar.gz

which means you can install these distributions in this order without
extra dependencies. When combined with C<-L> option, it will be useful
to replay installations on other machines.

=back

=item --save-dists

Specifies the optional directory path to copy downloaded tarballs in
the CPAN mirror compatible directory structure
i.e. I<authors/id/A/AU/AUTHORS/Foo-Bar-version.tar.gz>

=item --uninst-shadows

Uninstalls the shadow files of the distribution that you're
installing. This eliminates the confusion if you're trying to install
core (dual-life) modules from CPAN against perl 5.10 or older, or
modules that used to be XS-based but switched to pure perl at some
version.

If you run cpanm as root and use C<INSTALL_BASE> or equivalent to
specify custom installation path, you SHOULD disable this option so
you won't accidentally uninstall dual-life modules from the core
include path.

Defaults to true if your perl version is smaller than 5.12, and you
can disable that with C<--no-uninst-shadows>.

B<NOTE>: Since version 1.3000 this flag is turned off by default for
perl newer than 5.12, since with 5.12 @INC contains site_perl directory
I<before> the perl core library path, and uninstalling shadows is not
necessary anymore and does more harm by deleting files from the core
library path.

=item --cascade-search

B<EXPERIMENTAL>: Specifies whether to cascade search when you specify
multiple mirrors and a mirror doesn't have a module or has a lower
version of the module than requested. Defaults to false.

=item --skip-installed

Specifies whether a module given in the command line is skipped if its latest
version is already installed. Defaults to true.

B<NOTE>: The C<PERL5LIB> environment variable have to be correctly set for this
to work with modules installed using L<local::lib>.

=item --skip-satisfied

B<EXPERIMENTAL>: Specifies whether a module (and version) given in the
command line is skipped if it's already installed.

If you run:

  cpanm --skip-satisfied CGI DBI~1.2

cpanm won't install them if you already have CGI (for whatever
versions) or have DBI with version higher than 1.2. It is similar to
C<--skip-installed> but while C<--skip-installed> checks if the
I<latest> version of CPAN is installed, C<--skip-satisfied> checks if
a requested version (or not, which means any version) is installed.

Defaults to false for bare module names, but if you specify versions
with C<~>, it will always skip satisfied requirements.

=item --auto-cleanup

Specifies the number of days in which cpanm's work directories
expire. Defaults to 7, which means old work directories will be
cleaned up in one week.

You can set the value to C<0> to make cpan never cleanup those
directories.

=item --man-pages

Generates man pages for executables (man1) and libraries (man3).

Defaults to false (no man pages generated) if
C<-L|--local-lib-contained> option is supplied. Otherwise, defaults to
true, and you can disable it with C<--no-man-pages>.

=item --lwp

Uses L<LWP> module to download stuff over HTTP. Defaults to true, and
you can say C<--no-lwp> to disable using LWP, when you want to upgrade
LWP from CPAN on some broken perl systems.

=item --wget

Uses GNU Wget (if available) to download stuff. Defaults to true, and
you can say C<--no-wget> to disable using Wget (versions of Wget older
than 1.9 don't support the C<--retry-connrefused> option used by cpanm).

=item --curl

Uses cURL (if available) to download stuff. Defaults to true, and
you can say C<--no-curl> to disable using cURL.

Normally with C<--lwp>, C<--wget> and C<--curl> options set to true
(which is the default) cpanm tries L<LWP>, Wget, cURL and L<HTTP::Tiny>
(in that order) and uses the first one available.

=back

=head1 SEE ALSO

L<App::cpanminus>

=head1 COPYRIGHT

Copyright 2010 Tatsuhiko Miyagawa.

=head1 AUTHOR

Tatsuhiko Miyagawa

=cut
