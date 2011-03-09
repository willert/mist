package App::mist::Command::index;

use strict;
use warnings;

use App::mist -command;

use CPAN::ParseDistribution;
use CPAN::DistnameInfo;
use CPAN::PackageDetails;

use File::Find;
use File::Find::Upwards;
use Path::Class qw/dir file/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $home = find_containing_dir_upwards( 'dist.ini' )
    or die "Can't find project root";

  my $mpan      = $home->subdir( $ENV{MIST_DIST_DIR}  || 'mpan-dist' );
  my $local_lib = $home->subdir( $ENV{MIST_LOCAL_LIB} || 'perl5' );

  chdir $home->stringify;

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

    my $dist    = CPAN::ParseDistribution->new( $d->pathname );
    my $modules = $dist->modules;

    while ( my ( $pkg, $version ) = each %$modules ) {
      $package_details->add_entry(
        package_name => $pkg,
        version      => $version,
        path         => $mpath,
      );
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
