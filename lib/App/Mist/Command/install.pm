package App::Mist::Command::install;

use strict;
use warnings;

use App::Mist -command;

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/dir/;
use Cwd;

use File::Temp qw/ tempfile tempdir /;


sub execute {
  my ( $self, $opt, $args ) = @_;

  die "No module to install" unless $args and ref $args eq 'ARRAY' and @$args;

  my $cpanm = which( 'cpanm' )
    or die "cpanm not found";

  do $cpanm;
  require App::cpanminus::script;

  my $home = find_containing_dir_upwards( 'dist.ini' )
    or die "Can't find project root";

  my $workspace = tempdir( CLEANUP => 1 );
  my $mpan      = $home->subdir( $ENV{MIST_DIST_DIR}  || 'mpan-dist' );
  my $mpan_conf = $mpan->subdir( 'mist' );
  my $local_lib = $home->subdir( $ENV{MIST_LOCAL_LIB} || 'perl5' );

  my @options   = (
    "--quiet",
    "--local-lib-contained=${workspace}",
    "--mirror=file://${mpan}",
    "--mirror=http://search.cpan.org/CPAN",
    "--save-dists=${mpan}",
  );

  my $app1 = App::cpanminus::script->new;
  $app1->parse_options( @options, '--installdeps', @$args );
  $app1->doit or exit(1);

  my $app2 = App::cpanminus::script->new;
  $app2->parse_options( @options, '--reinstall', @$args );
  $app2->doit or exit(1);

}



1;
