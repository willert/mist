package Mist::Role::cpanminus;

use 5.010;
use Moo::Role;

use Carp ();
use File::Share ();

my $VERBOSE = 1;
my $DEBUG   = 0;

sub run_cpanm {
  my ( $this, @cmd_opts ) = @_;

  my %opts;
  %opts = %{ shift @cmd_opts } if ref $cmd_opts[0] eq 'HASH';

  my $cpanm = File::Share::dist_file( 'App-Mist', 'cpanm' );

  Carp::carp( sprintf qq{$cpanm '%s'\n}, join( q{', '}, @cmd_opts ))
      if $DEBUG;

  my $exit = system( $cpanm, @cmd_opts );
  Carp::croak( "cpanm @cmd_opts failed [$exit] : $?" )
    if $exit != 0 and $DEBUG;

  exit $exit if $exit != 0;
}


1;
