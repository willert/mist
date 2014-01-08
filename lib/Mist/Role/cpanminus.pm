package Mist::Role::cpanminus;

use 5.010;
use Moose::Role;
use namespace::clean -except => 'meta';

use Carp;
use Capture::Tiny qw/capture/;
use File::Share qw/ dist_file /;

my $VERBOSE = 1;
my $DEBUG   = 0;

sub run_cpanm {
  my ( $self, @cmd_opts ) = @_;

  my %opts;
  %opts = %{ shift @cmd_opts } if ref $cmd_opts[0] eq 'HASH';

  my $cpanm = dist_file( 'App-Mist', 'cpanm' );

  carp sprintf qq{$cpanm '%s'\n}, join( q{', '}, @cmd_opts ) if $DEBUG;

  my ( $stdout, $stderr, $exit ) = capture {
    system( $cpanm, @cmd_opts )
  };

  $stdout =~ s/^\d+ distributions? installed\n//m;

  my $skip_stdout = exists $opts{-stdout} && ! defined $opts{-stdout};
  my $skip_stderr = exists $opts{-stderr} && ! defined $opts{-stderr};

  chomp( $stdout, $stderr );
  printf "%s\n", $stdout if $VERBOSE and $stdout and not $skip_stdout;
  printf STDERR "%s\n", $stderr if $stderr and not $skip_stderr;

  croak "cpanm @cmd_opts failed [$exit] : $?"
    if $exit != 0 and $VERBOSE;
}


no Moose::Role;

1;
