package App::Mist::Command::corelibs;

use strict;
use warnings;

use base 'App::Cmd::Command';

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/dir/;
use Cwd;

use File::Temp qw/ tempfile tempdir /;


sub execute {
  my ( $self, $opt, $args ) = @_;

  die "No module to install" unless $args and ref $args eq 'ARRAY';

  my @cpanm_args;
  push @cpanm_args, shift @$args while $args->[0] and $args->[0] =~ /^-/;

  die "No module to install" unless @$args;

  my $cpanm = which( 'cpanm' )
    or die "cpanm not found";

  do $cpanm;
  require App::cpanminus::script;

  my $home = find_containing_dir_upwards( 'dist.ini' )
    or die "Can't find project root";

  my $workspace = '/tmp/scan/'; # tempdir( CLEANUP => 1 );
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

  use Data::Dumper::Concise;
  require Module::CoreList;
  # $Module::CoreList::version{$]+0} =
  #  $Module::CoreList::version{5.008001};

  {
    my $app = App::cpanminus::script->new;
    $app->parse_options( @options, '--notest', 'Module::Build' );
    $app->doit or exit(1);
  }

  {
    no warnings 'redefine';
    local *App::cpanminus::script::dump_scandeps = sub {
      my $self = shift;

      my %deps;
      my $visit;
      $visit = sub {
        my $this = shift;
        return unless ref $this;
        if ( ref $this eq 'ARRAY' ) {
          $visit->( $_ ) for @$this;
          return;
        }
        if ( ref $this eq 'HASH' ) {
          my @reqs = map{ "${_}requires" } '', 'build_', 'config_';
          @reqs = grep{ exists $this->{$_} } @reqs;
          if ( not @reqs ) { $visit->( $_ ) for values %$this; }
          for ( map{ $this->{$_} } @reqs ) {
            while ( my ( $pkg, $ver ) = each %$_ ) {
              next if exists $deps{$pkg} and $deps{$pkg} >= $ver;
              $deps{$pkg} = $ver;
            }
          }
        }
      };
      $visit->( $self->{scandeps_tree} );
      undef( $visit );

      my %core_deps = map{
        printf STDERR "%s v%s is core in %s\n",
          $_, $deps{$_}, Module::CoreList->first_release( $_, $deps{$_} );
        $_ => $deps{$_}
      } grep{
        my $v = Module::CoreList->first_release($_);
        $v;
      } keys %deps;

      printf STDERR 'Core deps: %s%s', Dumper( \%core_deps ), "\n";
    };
    my $app = App::cpanminus::script->new;
    $app->parse_options(
      @options, @cpanm_args, '--scandeps', '--format=yaml', @$args
    );
    $app->doit or exit(1);
  }

}



1;
