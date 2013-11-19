package App::Mist;
# ABSTRACT: MPAN distribution manager

use strict;
use warnings;
use 5.010;

use mro;
use version 0.74;

use Carp;
use Scalar::Util qw/looks_like_number blessed/;

use base 'App::Cmd';
use Module::Pluggable search_path => [ 'App::Mist::Command' ];

use Path::Class qw/dir file/;
use File::HomeDir;
use File::Which;
use File::Find::Upwards;

use CPAN::ParseDistribution;
use CPAN::DistnameInfo;
use CPAN::PackageDetails;

use Data::Dumper;
use Capture::Tiny qw/capture/;

use Try::Tiny;

my $verbose = 0;

sub new {
  my $class = shift;
  my $self  = $class->next::method( @_ );
  chdir $self->project_root->stringify;
  return $self;
}

{
  my $project_root;
  sub project_root {
    my $self = shift;
    $project_root ||= do{
      my $root = eval{
        local $SIG{__WARN__} = sub{};
        find_containing_dir_upwards( 'dist.ini' )
      } or die "$0: Can't find project root\n";
      dir( $root )->absolute->resolve;
    };
  }
}

{
  my $workspace;
  sub workspace {
    my $self = shift;
    $workspace ||= do{
      my $home = File::HomeDir->my_home
        or die "Can't find user home";
      ( my $project_base = lc $self->project_root )=~ s/\W/_/g;
      $project_base =~ s/^_+//;
      $project_base =~ s/_+$//;

      my $ws = dir( $home )->subdir( '.mist', $project_base );
      $ws->mkpath;

      $ws;
    };
  }
}

{
  my $ws_lib;
  sub workspace_lib {
    my $self = shift;
    $ws_lib ||= do{
      my $ll = $self->workspace->subdir('perl5');
      $ll->mkpath;
      $ll;
    };
  }
}

{
  my $mpan;
  sub mpan_dist {
    my $self = shift;
    $mpan ||= $self->project_root->subdir(
      $ENV{MIST_DIST_DIR}  || 'mpan-dist'
    );
  }

  sub mpan_conf {
    my $self = shift;
    my $conf_dir = $self->mpan_dist->subdir('mist');
    $conf_dir->mkpath;
    if ( my @path = @_ ) {
      my $conf = $conf_dir->file( @_ );
      $conf->dir->mkpath if @path > 1;
      $conf->touch unless -f $conf->stringify;
      return $conf;
    } else {
      return $conf_dir;
    }
  }
}

{
  my $perlbrew_root;
  sub perlbrew_root {
    my $self = shift;
    $perlbrew_root ||= do{
      $ENV{PERLBREW_ROOT} ? dir( $ENV{PERLBREW_ROOT} ) :
        dir( '', 'opt', 'perl5' );
    };
  }


  sub perlbrew_home {
    my $self = shift;
    $self->mpan_dist->subdir('perlbrew');
  }

}

{
  my $perlbrew_version;

  sub perlbrew_version {
    my $self = shift;
    return $perlbrew_version ||= do{
      my $mpan_conf = $self->mpan_conf;
      my $dist_perlbrew = $mpan_conf->file(qw/ 00.perlbrew.txt /);
      my $pb_version = $self->slurp_file( $dist_perlbrew );
      $pb_version =~ s/[\s\n\r]//g;
      $pb_version;
    };
  }

  sub ensure_correct_perlbrew_context {
    my $self = shift;

    my $pb_root    = $self->perlbrew_root;
    my $pb_home    = $self->perlbrew_home;
    my $pb_version = $self->perlbrew_version || return;

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

    if ( not $ENV{PERLBREW_PERL} || '' eq $pb_version ) {
      print "Restarting $0 under ${pb_version}\n\n";
      $ENV{PERLBREW_ROOT} = $pb_root;
      printf STDERR "Deactivating local lib\n", ;

      local::lib->import('--deactivate-all');
      exec $pb_exec, 'exec', '--with', $pb_version, $0, @ARGV;
    } else {
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
}


{
  my $perl5_base_lib;
  sub perl5_base_lib {
    my $self = shift;
    $perl5_base_lib ||= $self->project_root->subdir(
      $ENV{MIST_LOCAL_LIB} || 'perl5'
    )
  }
}

{
  my $local_lib;
  sub local_lib {
    my $self = shift;
    $local_lib ||= $self->perl5_base_lib->subdir(
      $self->perlbrew_version ? $self->perlbrew_version : 'system'
    );
  }
}


{
  my $dzil;
  sub dzil_executable {
    my $self = shift;
    $dzil ||= which( 'dzil' ) or die "$0: dzil not found\n";
  }

}

{
  my $cpanm_executable;
  sub cpanm_executable {
    my $self = shift;
    $cpanm_executable ||= which( 'cpanm' )
      or die "$0: cpanm not found\n";
  }
}

{
  my $cpanm_loaded;
  sub load_cpanm {
    my $self = shift;
    my $pkg = $self->cpanm_executable;

    $cpanm_loaded = do $pkg;
    require App::cpanminus;

    die "$0: cpanm v$App::cpanminus::VERSION is too old, v1.5 needed\n"
      if $App::cpanminus::VERSION < 1.5;

    return;
  }
}

{
  my $package_file;
  sub mpan_package_index {
    my $self = shift;
    if ( not $package_file ) {
      $package_file = $self->mpan_dist->file(
        'modules', '02packages.details.txt.gz'
      );
      $package_file->parent->mkpath;
    }
    return $package_file;
  }
}

{
  my $package_details;
  sub mpan_package_details {
    my $self = shift;
    $package_details ||= do{
      my $packages = $self->mpan_package_index;

      if ( not -f $packages->stringify ) {
        my $empty_package_file = CPAN::PackageDetails->new(
          file        => "02packages.details.txt",
          description => "Package names for my private CPAN",
          columns     => "package name, version, path",
          line_count  => 0,

          allow_packages_only_once => 0,

          intended_for =>
            "My private CPAN",
          url          =>
            "http://example.com/MyCPAN/modules/02packages.details.txt",
          written_by   =>
            "$0 using CPAN::PackageDetails $CPAN::PackageDetails::VERSION",
        );
        $empty_package_file->write_file( $packages->stringify );
      }

      {
        no strict 'refs';
        no warnings 'redefine';

        my $org = \&CPAN::PackageDetails::init;
        local *{"CPAN::PackageDetails::init"} = sub{
          push @_, allow_packages_only_once => 0;
          goto &$org;
        };

        CPAN::PackageDetails->read( $packages->stringify );
      }

    };
  }
}

sub slurp_file {
  my ( $self, $file ) = @_;

  my @lines;
  # printf STDERR "Reading: %s\n", $file;

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

sub parse_distribution {
  my ( $self, $dist ) = @_;

  my $base_path = $self->mpan_dist->subdir( 'authors' )->subdir('id');

  my $file = $base_path->file(
    $dist->{pathname} ? split( '/', $dist->{pathname} ) :
      file( $dist->{local_path} )->basename
  );

  return unless -r -f "$file";

  my $d = CPAN::DistnameInfo->new( $file );

  warn "$0: skipping $_\n" and return
    unless $d->distvname;

  my $dist_info = CPAN::ParseDistribution->new( $d->pathname );
  $dist_info->modules; # force vivification of module hash

  $dist_info->{pathname} = do{
    my $mpath = file( $d->pathname )->relative(
      $self->mpan_dist->subdir( 'authors' )->subdir('id')
    );

    $mpath = "./${mpath}"       # qualify path to module if
      if $mpath->parent eq dir(); # it's parent directory is unspecified

    $mpath;
  };

  # printf STDERR "Dist info: %s\n", Dumper( $dist_info );

  return $dist_info;
}

sub add_distribution_to_index {
  my ( $self, $dist ) = @_;

  my $dist_info = $self->parse_distribution( $dist );

  printf "Indexing %s ...\n", $dist_info->{pathname};

  my $modules = $dist_info->modules;

  $modules->{ $dist->{module} } = $dist->{module_version}
    if exists $dist->{module_version};

  while ( my ( $pkg, $version ) = each %$modules ) {

    my $do_index = sub {
      version->parse( $version );
      $self->mpan_package_details->add_entry(
        package_name => $pkg,
        version      => $version,
        path         => $dist_info->{pathname},
      );
      printf STDERR "  Added module %s %s\n", $pkg, $version // 'N/A';
    };

    $verbose ? &$do_index() : try{ &$do_index() };

    if ( my $err = $@ ) {
      $err =~ s/(.*) at .*/$1/s;
      print STDERR "  [WARNING] ${err}\n" if $verbose;
    }
  }

  return;
}

sub commit_mpan_package_index {
  my ( $self, $dist ) = @_;

  # CPAN::PackageDetails seems to pick up empty header lines somehow
  # force-delete them to avoid warnings and unsightly index files
  delete $self->mpan_package_details->header->{''};

  my $packages = $self->mpan_package_index;
  $self->mpan_package_details->write_file( $packages->stringify );

  return;
}

sub run_cpanm {
  my ( $self, @cmd_opts ) = @_;
  $self->load_cpanm;

  my $app = App::cpanminus::script->new;

  carp( "  cpanm @cmd_opts\n" ) if $verbose;


  $app->parse_options( @cmd_opts );
  $app->doit or exit(1);
}


sub run_dzil {
  my ( $self, @opts ) = @_;

  my $dzil   = $self->dzil_executable;
  my @output = qx{ $dzil @opts };
  chomp for @output;

  return grep{ $_ } @output;
}

sub fetch_prereqs {
  my $self = shift;

  require Dist::Zilla::App;
  my $dzil = Dist::Zilla::App->new;
  capture {
    # force Dist::Zilla to load everything we need
    $dzil->execute_command( $dzil->prepare_command('listdeps'));
  };

  my $prereqs = $dzil->zilla->prereqs->requirements_for(
    runtime => 'requires'
  );

  my @reqs;
  while ( my ( $module, $req ) = each %{ $prereqs->{requirements} }) {
    my $version = $req->{minimum} ? '~'.$req->{minimum} : '';
    push @reqs, $module . $version ;
  }

  return @reqs;
}

1;
