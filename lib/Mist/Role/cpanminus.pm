package Mist::Role::cpanminus;

use 5.010;
use Moo::Role;

use Carp ();
use File::Share ();

my $VERBOSE = 1;
my $DEBUG   = 0;

sub run_bundled_cpanm_script {
  my ( $this, @cmd_opts ) = @_;

  my %opts;
  %opts = %{ shift @cmd_opts } if ref $cmd_opts[0] eq 'HASH';

  my $cpanm = File::Share::dist_file( 'App-Mist', 'cpanm' );

  Carp::carp( sprintf qq{$cpanm '%s'\n}, join( q{', '}, @cmd_opts ))
      if $DEBUG;

  # use Data::Dumper;
  # printf STDERR "[Dumper] at Mist::Role::cpanminus line 26: %s\n",
  #   Dumper([ local::lib->active_paths ]);

  local $ENV{TAR_OPTIONS} = '--warning=no-unknown-keyword';

  my $exit = system( $cpanm, @cmd_opts );
  Carp::croak( "cpanm @cmd_opts failed [$exit] : $?" )
    if $exit != 0;

  if ( $exit != 0 ) {
    $? = $exit;
    die "FATAL: Error while running cpanm\n";
  }
}


1;
