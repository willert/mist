package App::Mist::Command::index;

use strict;
use warnings;

use base 'App::Cmd::Command';

use CPAN::ParseDistribution;
use CPAN::DistnameInfo;
use CPAN::PackageDetails;

use File::Find;
use Path::Class qw/dir file/;

use version 0.74;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $home      = $self->app->project_root;
  my $mpan      = $self->app->mpan_dist;
  my $local_lib = $self->app->local_lib;

  my $mpan_modules = $mpan->subdir( 'modules' );
  my $mpan_authors = $mpan->subdir( 'authors' );

  my $package_details;

  my $index_local_lib = sub {
    return unless -r -f;

    my $d = CPAN::DistnameInfo->new( $_ );

    warn "$0: skipping $_\n" and return
      unless $d->distvname;

    my $mpath = file( $d->pathname )->relative( $mpan_authors->subdir('id'));

    printf "Indexing %s ...\n", $mpath;

    $mpath = "./${mpath}"       # qualify path to module if
      if $mpath->parent eq dir(); # it's parent directory is unspecified

    my $dist    = CPAN::ParseDistribution->new( $d->pathname );
    my $modules = $dist->modules;

    {
      ( my $dist_pkg = $dist->dist ) =~ s/-/::/g;
      eval{
        version->parse( $dist->distversion );
        $package_details->add_entry(
          package_name => $dist_pkg,
          version      => $dist->distversion,
          path         => $mpath,
        );
      } or warn sprintf(
        "[WARNING] %s %s: %s\n", $dist_pkg, $dist->distversion, $@
      );
    }

    while ( my ( $pkg, $version ) = each %$modules ) {
      eval{
        version->parse( $version );
        $package_details->add_entry(
          package_name => $pkg,
          version      => $version,
          path         => $mpath,
        );
      } or warn "[WARNING] $@\n";
    }

  };

  $package_details = CPAN::PackageDetails->new(
    file         => "02packages.details.txt",
    url          => "http://example.com/MyCPAN/modules/02packages.details.txt",
    description  => "Package names for my private CPAN",
    columns      => "package name, version, path",
    intended_for => "My private CPAN",
    written_by   => "$0 using CPAN::PackageDetails $CPAN::PackageDetails::VERSION",
    allow_packages_only_once => 0,
  );

  chdir $mpan->stringify;
  find(
    { wanted => $index_local_lib, no_chdir => 1 },
    $mpan_authors->stringify
  );

  $mpan_modules->mkpath;
  $package_details->write_file(
    $mpan_modules->file( '02packages.details.txt.gz' )->stringify
  );

}

1;
