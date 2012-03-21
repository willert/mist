package App::Mist::Command::clean;

use strict;
use warnings;

use App::Mist -command;

use CPAN::PackageDetails;

use File::Find;
use File::Find::Upwards;
use Path::Class qw/dir file/;
use Cwd;

use version 0.74;

use Data::Dumper::Concise;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $home      = $self->app->project_root;
  my $mpan      = $self->app->mpan_dist;
  my $local_lib = $self->app->local_lib;

  my $mpan_modules = $mpan->subdir( 'modules' );
  my $mpan_authors = $mpan->subdir( 'authors' );

  my $package_details = CPAN::PackageDetails->read(
    $mpan_modules->file( '02packages.details.txt.gz' )->stringify
  );

  my $records = $package_details->entries;

  my %dist_package;

  print "Scanning package details\n";

  while ( my ( $pkg, $versions ) = each %{ $records->entries } ) {
    for ( values %$versions ) {
      ( my $rel_path = $_->path ) =~ s{ ^ \. [/\\] }{}x;
      $dist_package{ $rel_path } = 1;
    }
  }

  my $rm_count = 0;

  chdir $mpan->stringify;
  find({ wanted => sub{
    return unless -f $_;
    my $from = dir( cwd() )->subdir( 'authors', 'id', '__PLACEHOLDER__' );
    $from =~ s/__PLACEHOLDER__//;
    ( my $path = $_ ) =~ s|${from}||;
    if ( not $dist_package{ $path } ) {
      printf "Removing %s ...\n", $path;
      unlink $_;
      $rm_count += 1;
    }
  }, no_chdir => 1 }, $mpan_authors->stringify );

  print "No stale distributions found\n"
    unless $rm_count;

}

1;
