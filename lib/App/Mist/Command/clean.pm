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

  print "Scanning package details ..\n", ;

  while ( my ( $pkg, $versions ) = each %{ $records->entries } ) {
    # printf qq{%s:\n  %s\n\n}, $pkg, join( q{, }, keys %$versions );
    $dist_package{ $_->path } = 1 for values %$versions;
  }

  print "Removing obsolete distributions ..\n", ;

  chdir $mpan->stringify;
  find({ wanted => sub{
    return unless -f $_;
    my $from = dir( cwd() )->subdir( 'authors', 'id', '__PLACEHOLDER__' );
    $from =~ s/__PLACEHOLDER__//;
    ( my $path = $_ ) =~ s|${from}||;
    unlink $_ unless $dist_package{ $path };
  }, no_chdir => 1 }, $mpan_authors->stringify );


}

1;
