package App::Mist::Command::clean;
# ABSTRACT: Remove superseded dists from mpan-dist

use 5.010;

use App::Mist -command;

use CPAN::PackageDetails;

use File::Find;
use File::Find::Upwards;
use Path::Class qw/dir file/;
use Cwd;

use version 0.74;

use Data::Dumper;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $ctx       = $self->app->ctx;
  my $home      = $ctx->project_root;
  my $mpan      = $ctx->mpan_dist;
  my $local_lib = $ctx->local_lib;

  my $mpan_modules = $mpan->subdir( 'modules' );
  my $mpan_authors = $mpan->subdir( 'authors' );
  my $mpan_vendor  = $mpan->subdir( 'vendor'  );

  my $package_details = CPAN::PackageDetails->read(
    $mpan_modules->file( '02packages.details.txt.gz' )->stringify
  );

  my $records = $package_details->entries;

  my %dist_package;

  print "Scanning package details\n";

  my %entries = do {
    local $SIG{__WARN__} = sub{
      print STDERR "@_\n" unless $_[0] =~ m{ entries \s+ is \s+ deprecated }x;
    };
    %{ $records->entries };
  };

  while ( my ( $pkg, $versions ) = each %entries ) {
    for ( values %$versions ) {
      ( my $rel_path = $_->path ) =~ s{ ^ \. [/\\] }{}x;
      $dist_package{ $rel_path } = 1;
    }
  }

  my $rm_count = 0;

  chdir $mpan->stringify;

  my $files_to_clean = sub{
    return unless -f $_;

    my $cwd = dir( cwd() );
    my $authors = $cwd->subdir( 'authors', 'id' );

    my $from = $authors->subdir( '__PLACEHOLDER__' );
    $from =~ s/__PLACEHOLDER__//;
    ( my $path = $_ ) =~ s|${from}||;

    my $vendor_path = file( $_ )->relative( $authors );

    if ( not $dist_package{ $path } and not $dist_package{ $vendor_path } ) {
      printf "Removing %s ...\n", file( $path )->basename;
      unlink $_;
      $rm_count += 1;
    }
  };

  find({ wanted => $files_to_clean, no_chdir => 1 }, $mpan_authors->stringify );

  find({ wanted => $files_to_clean, no_chdir => 1 }, $mpan_vendor->stringify )
    if -d $mpan_vendor->stringify;

  print "No stale distributions found\n"
    unless $rm_count;

}

1;
