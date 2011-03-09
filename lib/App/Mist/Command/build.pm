package App::Mist::Command::build;

use strict;
use warnings;

use App::Mist -command;

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/dir/;
use Cwd;

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $cpanm = which( 'cpanm' )
    or die "cpanm not found";

  do $cpanm;
  require App::cpanminus;

  die "cpanm v$App::cpanminus::VERSION is too old, v1.4 needed"
    if $App::cpanminus::VERSION < 1.4;

  my $home = find_containing_dir_upwards( 'dist.ini' )
    or die "Can't find project root";

  my $mpan      = $home->subdir( $ENV{MIST_DIST_DIR}  || 'mpan-dist' );
  my $mpan_conf = $mpan->subdir( 'mist' );
  my $local_lib = $home->subdir( $ENV{MIST_LOCAL_LIB} || 'perl5' );

  my $dist_prepend = $mpan_conf->file(qw/ 01.prepend.txt /);
  my $dist_notest  = $mpan_conf->file(qw/ 02.notest.txt /);

  chdir $home->stringify;
  $mpan_conf->mkpath;
  $_->touch for grep{ not -r $_->stringify } $dist_prepend, $dist_notest;

  try {

    open my $in,  "<", "$cpanm" or die $!;
    open my $out, ">", "mist-install.tmp" or die $!;

    print STDERR "Generating mist-installer\n";

    while (<$in>) {
        print $out $_;
        last if /# END OF FATPACK CODE\s*$/;
    }

    my $slurp_file = sub{
      my $file = shift;
      my @lines;
      printf STDERR "Reading: %s\n", $file;

      return () unless -f -r $file->stringify;
      my $fh = $file->openr;
      @lines = readline $fh;
      chomp for @lines;
      @lines = grep{ $_ } @lines;
      return @lines;
    };

    my @prepend = $slurp_file->( $dist_prepend );
    my @notest  = $slurp_file->( $dist_notest );

    my @prereqs = qx{ dzil listdeps };
    chomp for @prereqs;
    @prereqs = grep{ $_ } @prereqs;

    my @args = (
      $mpan->relative( $home ),
      $local_lib->relative( $home ),
      @prepend ? sprintf( qq{'%s'}, join qq{',\n    '}, @prepend ) : '',
      @notest  ? sprintf( qq{'%s'}, join qq{',\n    '}, @notest  ) : '',
      @prereqs ? sprintf( qq{'%s'}, join qq{',\n    '}, @prereqs ) : '',
    );

    printf $out <<'INSTALLER', @args;

use App::cpanminus::script;
use FindBin qw/$RealBin/;
use Path::Class qw/file dir/;

my $mpan      = dir( $RealBin, '%s' );
my $local_lib = dir( $RealBin, '%s' );

sub run_cpanm {
  my $app       = App::cpanminus::script->new;
  my @options   = (
    "--quiet",
    "--local-lib-contained=${local_lib}",
    "--mirror=file://${mpan}",
    '--mirror-only',
  );

  # use Data::Dumper::Concise;
  # printf STDERR '@Options: %%s%%s', Dumper( \@options ), "\n";

  $app->parse_options( @options, @_ );
  $app->doit or exit(1);
}

unless (caller) {
  my @prepend = (
    %s
  );
  my @notest  = (
    %s
  );
  my @prereqs = (
    %s
  );

  run_cpanm( @ARGV, @prepend ) if @prepend;
  run_cpanm( @ARGV, '--installdeps', @notest ) if @notest;
  run_cpanm( @ARGV, '--notest', @notest ) if @notest;
  run_cpanm( @ARGV, @prereqs ) if @prereqs;
}

INSTALLER

    close $out;

    unlink "mist-install";
    rename "mist-install.tmp", "mist-install";
    chmod 0755, "mist-install";

  } catch {
    warn "$_\n";
  } finally {

    unlink "mist-install.tmp"

  };

}



1;
