package App::Mist;
# ABSTRACT: MPAN distribution manager
use 5.010;
use FindBin qw/$RealBin/;
use File::Spec;
use Config;
use Cwd qw/realpath/;

BEGIN {
  my $basedir = realpath( File::Spec->catdir( $RealBin => '..' ));
  if ( not eval "require local::lib" ) {
    my $extlib = File::Spec->catdir( $basedir => qw/ extlib / );
    if ( -d $extlib ) {
      $extlib = realpath( $extlib );
      print STDERR "Using local::lib from extlib $extlib\n";
      push @INC, $extlib;
      require local::lib;
    } else {
      die "Please install local::lib in the current environment\n";
    }
  }

  my $version_dir = join( q{-}, 'perl', $Config{version}, $Config{archname} );
  my $mist_lib    = File::Spec->catdir( $basedir => 'perl5', $version_dir );

  if ( not -d $mist_lib and not $ENV{MIST_REBUILD_IN_PROGRESS} ) {
    die <<"ERROR_MSG";
Mist is not yet installed for perl $Config{version}-$Config{archname}.
Please run:
  cd $basedir; ./mpan-install --perl=$Config{version}
ERROR_MSG
  }

  require local::lib;
  local::lib->import( $mist_lib );
}

use App::Cmd::Setup -app;

our $VERSION = '0.34';

# preload all commands
# use Module::Pluggable search_path => [ 'App::Mist::Command' ];

use App::Mist::Context;

sub ctx {
  my $self = shift;
  $self->{ctx} //= App::Mist::Context->new;
}

1;

__END__

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
