package Mist::Role::cpanminus;

use 5.010;
use Moose::Role;
use namespace::clean -except => 'meta';

use Carp;
use File::Share qw/ dist_file /;

my $VERBOSE = 1;
my $DEBUG   = 0;

sub run_cpanm {
  my ( $self, @cmd_opts ) = @_;

  my %opts;
  %opts = %{ shift @cmd_opts } if ref $cmd_opts[0] eq 'HASH';

  my $cpanm = dist_file( 'App-Mist', 'cpanm' );

  carp sprintf qq{$cpanm '%s'\n}, join( q{', '}, @cmd_opts ) if $DEBUG;

  my $exit = system( $cpanm, @cmd_opts );
  croak "cpanm @cmd_opts failed [$exit] : $?"
    if $exit != 0 and $DEBUG;

  exit $exit if $exit != 0;
}


no Moose::Role;

1;
