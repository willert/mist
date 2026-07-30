package App::Mist::Context;
use 5.014;
use utf8;

use Moo;
use MooX::late;

use Carp;
use Config;

use Path::Class qw/dir file/;
use File::HomeDir;
use File::Which;
use File::Find ();
use File::Find::Upwards;
use File::Path ();
use File::Share qw/ dist_file /;
use File::Temp qw/ tempdir /;

BEGIN {
  local $SIG{__WARN__} = sub { };
  require CPAN::PackageDetails;
}

use Module::CPANfile;
use CPAN::Meta::Prereqs 2.132830;

use Mist::Distribution;
use Mist::Environment;
use Mist::Generation ();

use Sort::Key qw/keysort/;

has project_root => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

sub _build_project_root {
  my $self = shift;
  my $root = eval{
    local $SIG{__WARN__} = sub{};
    find_containing_dir_upwards( 'mistfile', 'cpanfile' )
  } or die "$0: Can't find project root\n";

  return dir( $root )->absolute->resolve;
}


has cpanfile => (
  is         => 'ro',
  isa        => 'Path::Class::File',
  lazy_build => 1,
);

sub _build_cpanfile {
  my $self = shift;
  my $file = $self->project_root->file( 'cpanfile' );

  die "$0: Can't find cpanfile for project\n"
    unless -f "$file";

  return $file;
};


has workspace => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

sub _build_workspace {
  my $self = shift;
  my $home = File::HomeDir->my_home
    or die "Can't find user home";

  ( my $project_base = lc $self->project_root )=~ s/\W/_/g;
  $project_base =~ s/^_+//;
  $project_base =~ s/_+$//;

  my $ws = dir( $home )->subdir( '.mist', $project_base );
  $ws->mkpath;

  return $ws;
}


has workspace_lib => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

sub _build_workspace_lib {
  my $self = shift;
  my $ll = $self->workspace->subdir('perl5');
  $ll->mkpath;
  return $ll;
}



has mist_environment => (
  is         => 'ro',
  isa        => 'Mist::Environment',
  lazy_build => 1,
);

sub _build_mist_environment {
  my $self = shift;
  my $mistfile = $self->project_root->file( 'mistfile' )->stringify;
  return Mist::Environment->new unless -f $mistfile;
  return Mist::Environment->new( $mistfile );
}


has dist => (
  is         => 'ro',
  isa        => 'Mist::Distribution',
  lazy_build => 1,
);

sub _build_dist {
  my $self = shift;
  return $self->mist_environment->parse;
}


has mpan_dist => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

sub _build_mpan_dist {
  my $self = shift;
  $self->project_root->subdir( $ENV{MIST_DIST_DIR}  || 'mpan-dist' );
}


has perlbrew_root => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

sub _build_perlbrew_root {
  my $self = shift;
  $ENV{PERLBREW_ROOT} ? dir( $ENV{PERLBREW_ROOT} ) :
    -d dir( '', 'opt', 'perl5' )->stringify ? dir( '', 'opt', 'perl5' ) :
    dir( '', 'opt', 'perlbrew' );
}

has perl5_base_lib => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

sub _build_perl5_base_lib {
  my $self = shift;
  $self->project_root->subdir( 'perl5' );
}


has local_lib => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

sub _build_local_lib {
  my $self = shift;

  # The same per-perl identity ./mpan-install builds its generation names from,
  # so the selector this resolves is the one the installer activates.
  my $lib_dir = $self->perl5_base_lib->subdir( Mist::Generation::arch_path() );
  $lib_dir = $lib_dir->resolve if -l $lib_dir;   # follow a branch/generation link
  return $lib_dir;
}


has staging_lib => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

# The install target for the commands that resolve dependencies in order to
# vendor them - `mist inject`, `mist merge`. What they produce is the set of
# tarballs --save-dists writes into mpan-dist; where cpanm installs along the way
# is incidental, and a throwaway serves. It must not be the live environment:
# a promoted generation is immutable, and perl5/ belongs to ./mpan-install, which
# is the only thing that may create one or move the selector symlink onto it.
#
# Seeded copy-on-write from the live generation rather than left empty, because
# --local-lib-contained resolves against the target lib plus the core and nothing
# else: an empty one reports every non-core module as missing, so it rebuilds the
# whole dependency tree and raises dependencies the live environment already
# satisfies at an older version - the opposite of what a plain inject promises.
# Seeded, cpanm sees what the live environment has and builds only the delta.
# Before a first install there is nothing to seed from, and an empty lib is then
# an accurate picture rather than a distorted one.
#
# One per mist run, not one per command: `mist init` chains four injects in a
# single process, and they have to resolve against each other's results the way
# they did when the live lib was their shared target.
sub _build_staging_lib {
  my $self = shift;

  my $container = $self->workspace->subdir( 'staging' );
  $container->mkpath;

  # tempdir gives the container; the staging lib is the not-yet-existing child
  # that cp creates, since `cp SRC DEST` copies *into* an existing DEST.
  my $staging = dir(
    tempdir( 'lib-XXXXXX', DIR => "$container", CLEANUP => 1 )
  )->subdir( 'perl5' );

  my $seed = $self->local_lib;
  unless ( -d "$seed" ) {
    $staging->mkpath;
    return $staging;
  }

  # Hard-link the seed so unchanged files share inodes - the same copy-on-write
  # seeding a new generation uses, and safe for the same reason: ExtUtils::Install
  # unlinks or renames a file before writing it, so an installed file is replaced
  # rather than written through the link into the live environment. Hard links
  # need a single filesystem, so a workspace on another one falls back to a real
  # copy: slower, and worth saying so, but still correct.
  if ( system( cp => '--link', '--archive', "$seed", "$staging" ) != 0 ) {
    File::Path::rmtree( "$staging" );
    printf STDERR "Can't hard-link a staging lib from %s, copying it instead\n", $seed;
    system( cp => '--archive', "$seed", "$staging" ) == 0
      or die "$0: can't seed a staging lib from $seed\n";
  }

  _shed_seeded_bookkeeping( $staging );

  return $staging;
}

# Whatever the seed shares that gets written *in place* would reach the live
# environment through its hard link. Two things do: perllocal.pod, which the
# install step appends to, and cpanm's .meta receipts, which it rewrites with a
# truncating open. Neither holds anything the staging lib needs - cpanm writes
# both itself - so drop them and leave the staging lib owning what it writes.
sub _shed_seeded_bookkeeping {
  my ( $lib ) = @_;

  my @receipts;
  File::Find::find( sub {
    if ( -d $_ and $_ eq '.meta' ) {
      push @receipts, $File::Find::name;
      $File::Find::prune = 1;
      return;
    }
    unlink $_ if $_ eq 'perllocal.pod';
  }, "$lib" );

  File::Path::rmtree( \@receipts ) if @receipts;

  return;
}


# Deprecated state, not a supported mode. Unpinned is the one configuration that
# silently reinterprets an environment: the build follows whatever perl is on
# PATH at that moment, and the switch guard that would refuse an implicit
# interpreter change short-circuits when no perl is managed, so a later run from
# a different shell re-activates onto that perl without asking. Being unmanaged
# is legitimate - that is what --system-perl is for - but it should be stated,
# and stated per machine, rather than fallen into by leaving a line out.
sub _unpinned_warning {
  return <<'WARNING';

mist: this project pins no perl version.

Builds follow whatever perl is on PATH, and the guard that refuses an implicit
interpreter switch does not apply, so a later run from a different shell
re-activates the environment onto that perl without asking.

Add `perl '<version>'` to the mistfile, or - on a host that deliberately tracks
its own perl - run ./mpan-install --system-perl, which is guarded and remembered.

Unpinned projects are deprecated and will be refused in a future release.

WARNING
}


has cpanm_executable => (
  is         => 'ro',
  isa        => 'Path::Class::File',
  lazy_build => 1,
);

sub _build_cpanm_executable {
  my $self = shift;
  my $cpanm = which( 'cpanm' )
    or die "$0: cpanm not found\n";
  return file( $cpanm );
}


has perl_version => (
  is         => 'ro',
  isa        => 'Str',
  lazy_build => 1,
);

sub _build_perl_version {
  my $self = shift;
  my $pb_version = $self->dist->get_default_perl_version;

  unless ( $pb_version ) {
    warn _unpinned_warning();
    return '';
  }

  # Opting out of perl management is a per-machine decision, so it is not
  # expressible here. A mistfile is committed and speaks for every machine that
  # builds the project, including development boxes; "use whatever perl this box
  # ships" is one host's statement about itself, and belongs in that host's
  # ./mpan-install --system-perl instead.
  #
  # Refused rather than ignored: the host installer does honour a 'system'
  # sentinel (it is what --system-perl resolves to), so silently dropping the pin
  # here would leave the two halves disagreeing about what the mistfile means.
  die <<'REFUSED' if $pb_version eq 'system';
mistfile: `perl 'system'` is not a valid pin.

Opting out of perl management is a decision for one machine, not for the
project: a committed pin applies to every checkout, development boxes
included. Run ./mpan-install --system-perl on the host that needs it - the
choice is recorded there and survives later installs.
REFUSED

  return "perl-${pb_version}";
}


sub BUILD {
  my $self = shift;
  chdir $self->project_root->stringify;
}

sub ensure_correct_perlbrew_context {
  my $self = shift;
  my $pb_version_override = shift;

  my $pb_root    = $self->perlbrew_root;
  my $pb_version = ( defined $pb_version_override and length $pb_version_override )
    ? $pb_version_override
    : ( $self->perl_version || return );

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

  my @pb_versions = qx# bash -c '
      export PERLBREW_ROOT=${pb_root}

      echo Root: \${PERLBREW_ROOT}

      if ( ! . \${PERLBREW_ROOT}/etc/bashrc ) ; then
        perlbrew init 2>/dev/null
        if ( ! . \${PERLBREW_ROOT}/etc/bashrc ) ; then
          echo "Cannot create perlbrew environment in \${PERLBREW_ROOT}"
          exit 127
        fi
      fi

      $pb_exec list
    '#;

  my ( $pb_installed ) = grep{ / \b $pb_version \b /x } @pb_versions;
  die join(
    qq{\n},
    "FATAL: $pb_version not found $pb_root",
    "Try",
    "  sudo -E perlbrew install -Dusethreads -Duseshrplib -n $pb_version",
    "to install it as root"
  ) unless $pb_installed or -w $pb_root;

  # my @pb_call = ( $pb_exec, 'install', $pb_version );
  # system( @pb_call ) == 0 or die "`@pb_call` failed" unless $pb_installed;


  if ( ( $ENV{PERLBREW_PERL} || '' ) ne $pb_version or not $ENV{MIST_PERLBREW_VERSION}) {

    my $pb_cmd = qq{ $pb_exec exec --quiet --with '$pb_version' };
    my $pb_archname =  qx{ $pb_cmd perl -MConfig -E "say \\\$Config{archname}" };
    chomp $pb_archname;

    ( my $cmd_name = $0 ) =~ s/[\n\r\s]+$//;
    printf STDERR "Restarting $cmd_name under %s [%s]\n", $pb_version, $pb_archname;
    # share/perlbrew-wrapper.bash requires MIST_APP_ROOT; the sourced mist env
    # normally exports it, but a re-execing command run in a shell that has not
    # sourced the env would otherwise die in the wrapper. Default it to the
    # project root - the value that env would export anyway.
    my $app_root = $self->project_root->stringify;

    $ENV{PERLBREW_ROOT} = $pb_root;
    $ENV{MIST_PERLBREW_VERSION} = $pb_version;
    $ENV{MIST_APP_ROOT} //= $app_root;

    { local $SIG{__WARN__} = sub{}; local::lib->import('--deactivate-all') }

    # Unlike mpan-install's installer re-exec (Mist::Script::perlbrew), do NOT
    # sever STDIN here: this re-exec also backs `mist run`, which must pass the
    # caller's STDIN through to the executed command.
    exec $pb_exec, 'exec', '--quiet', '--with', $pb_version,
      dist_file( 'App-Mist', 'perlbrew-wrapper.bash' ), $0, @ARGV;
  } else {
    local $SIG{__WARN__} = sub{};
    eval 'require local::lib;' or die join(
      qq{\n},
      "FATAL: missing local::lib ",
      "Please install local::lib for this perl. Try",
      "  source ${pb_root}/etc/bashrc ; " .
        "sudo -E perlbrew exec --with ${pb_version} cpanm local::lib",
      "to install it as root"
    );
    # local::lib->import('--deactivate-all');
    # local::lib->import( $self->local_lib );
  }
}

sub with_project_libs {
  my $self = shift;
  my $fnct = pop;
  my %args = @_;
  local::lib->import('--deactivate-all');
  local::lib->import( $self->local_lib );
  $fnct->();
}

sub slurp_file {
  my ( $self, $file ) = @_;

  my @lines;
  if ( -f -r $file->stringify ) {
    my $fh = $file->openr;
    @lines = readline $fh;
    chomp for @lines;
    @lines = grep{ $_ } @lines;
    s/^\s+// for @lines;
    s/\s+$// for @lines;
  }

  return wantarray ? @lines : join( "\n", @lines, '' );
}


sub fetch_prereqs {
  my $self = shift;

  my $cpanfile = Module::CPANfile->load( $self->cpanfile->stringify );
  my $prereqs  = $cpanfile->prereqs->merged_requirements;

  my @required = $prereqs->required_modules;

  # `perl` is CPAN::Meta's pseudo-prereq for the interpreter version, not a
  # distribution: passed through to cpanm it fails the whole install with
  # "Couldn't find module or a distribution perl". Check it against the perl the
  # mistfile pins - the project's own declared answer, and unlike $] the same
  # whichever perl happens to be running this command - and keep it out of the
  # list cpanm gets. accepts_module does the comparing, so a decimal floor
  # ('5.020') and a dotted pin ('5.20.3') line up and ranges keep working.
  if ( grep { $_ eq 'perl' } @required ) {
    my $pinned = $self->dist->get_default_perl_version;

    # No mistfile pin means nothing authoritative to compare against, so the
    # floor stays unverified rather than checked against a guess.
    if ( defined $pinned and not $prereqs->accepts_module( 'perl', $pinned )) {
      die sprintf "%s requires perl %s, but the mistfile pins perl %s.\n"
        . "Raise the mistfile's perl version or relax the cpanfile requirement.\n",
        $self->cpanfile, $prereqs->requirements_for_module( 'perl' ), $pinned;
    }
  }

  my @reqs;
  foreach my $module ( grep { $_ ne 'perl' } @required ) {
    my $req_str = $module;
    if ( my $meta = $prereqs->requirements_for_module( $module )) {
      $req_str .= '~' . $meta;
    }
    push @reqs, $req_str;
  }

  # sort by module name without version requirements
  return keysort { s/~.*//r } @reqs;
}


__PACKAGE__->meta->make_immutable;

1;
