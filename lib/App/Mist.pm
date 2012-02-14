package App::Mist;

use strict;
use warnings;
use 5.010;

use mro;
use version 0.74;

use Carp;
use Scalar::Util qw/looks_like_number blessed/;

use App::Cmd::Setup -app;
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
    return @_ ? $conf_dir->file( @_ ) : $conf_dir;
  }

}

{
  my $local_lib;
  sub local_lib {
    my $self = shift;
    $local_lib ||= $self->project_root->subdir(
      $ENV{MIST_LOCAL_LIB} || 'perl5'
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

      CPAN::PackageDetails->read( $packages->stringify );
    };
  }
}

sub parse_distribution {
  my ( $self, $dist ) = @_;

  my $base_path = $self->mpan_dist->subdir( 'authors' )->subdir('id');

  my $file = $base_path->file(
    $dist->{pathname} ? split( '/', $dist->{pathname} ) :
      file( $dist->{local_path} )->basename
  );

  return unless -r -f $file;

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

  while ( my ( $pkg, $version ) = each %$modules ) {

    eval{
      version->parse( $version );
      $self->mpan_package_details->add_entry(
        package_name => $pkg,
        version      => $version,
        path         => $dist_info->{pathname},
      );
      printf STDERR "  Added module %s %s\n", $pkg, $version // 'N/A';
    };

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
