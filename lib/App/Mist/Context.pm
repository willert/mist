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
use File::Find::Upwards;
use File::Share qw/ dist_file /;

use Module::CPANfile;
use CPAN::Meta::Prereqs;

use Mist::Distribution;
use Mist::Environment;

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
  $ENV{PERLBREW_ROOT} ? dir( $ENV{PERLBREW_ROOT} ) : dir( '', 'opt', 'perl5' );
}


has perlbrew_home => (
  is         => 'ro',
  isa        => 'Path::Class::Dir',
  lazy_build => 1,
);

sub _build_perlbrew_home {
  my $self = shift;
  $self->mpan_dist->subdir('perlbrew');
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

  my $version = join( q{-}, 'perl', $Config{version}, $Config{archname} );

  return $self->perl5_base_lib->subdir( $version );
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

  return '' unless $pb_version;
  return "perl-${pb_version}";
}


sub BUILD {
  my $self = shift;
  chdir $self->project_root->stringify;
}


sub ensure_correct_perlbrew_context {
  my $self = shift;

  my $pb_root    = $self->perlbrew_root;
  my $pb_home    = $self->perlbrew_home;
  my $pb_version = $self->perl_version || return;

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
      export PERLBREW_HOME=${pb_home}

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

    printf "Restarting $0 under %s [%s]\n", $pb_version, $pb_archname;
    $ENV{PERLBREW_ROOT} = $pb_root;
    $ENV{MIST_PERLBREW_VERSION} = $pb_version;

    { local $SIG{__WARN__} = sub{}; local::lib->import('--deactivate-all') }

    exec $pb_exec, 'exec', '--quiet', '--with', $pb_version,
      dist_file( 'App-Mist', 'perlbrew-wrapper.bash' ), $0, @ARGV;
  } else {
    { local $SIG{__WARN__} = sub{}; local::lib->import('--deactivate-all') }
    eval 'require local::lib;' or die join(
      qq{\n},
      "FATAL: missing local::lib ",
      "Please install local::lib for this perl. Try",
      "  source ${pb_root}/etc/bashrc ; " .
        "sudo -E perlbrew exec --with ${pb_version} cpanm local::lib",
      "to install it as root"
    );
    local::lib->import( $self->local_lib );
  }
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

  CPAN::Meta::Prereqs->VERSION( '2.132830' );

  my $cpanfile = Module::CPANfile->load( $self->cpanfile->stringify );
  my $prereqs  = $cpanfile->prereqs->merged_requirements;

  my @reqs;
  foreach my $module ( $prereqs->required_modules ) {
    my $req_str = $module;
    if ( my $meta = $prereqs->requirements_for_module( $module )) {
      $req_str .= '~' . $meta;
    }
    push @reqs, $req_str;
  }

  return @reqs;
}


__PACKAGE__->meta->make_immutable;

1;
