package App::mist::Command::build;

use strict;
use warnings;

use App::mist -command;

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
  my $local_lib = $home->subdir( $ENV{MIST_LOCAL_LIB} || 'perl5' );

  chdir $home->stringify;

  try {

    open my $in,  "<", "$cpanm" or die $!;
    open my $out, ">", "mist-install.tmp" or die $!;

    print STDERR "Generating mist-installer\n";

    while (<$in>) {
        print $out $_;
        last if /# END OF FATPACK CODE\s*$/;
    }

    my @prereqs = qx{ dzil listdeps };
    chomp for @prereqs;

    my @args = (
      $local_lib->relative( $home ),
      $mpan->relative( $home ),
      sprintf( qq{'%s'}, join qq{',\n    '}, @prereqs ),
    );

    printf $out <<'INSTALLER', @args;

    use App::cpanminus::script;
    use FindBin qw/$RealBin/;

    unless (caller) {
      my $app = App::cpanminus::script->new;
      $app->parse_options(
        "--local-lib-contained=${RealBin}/%s",
        "--mirror=file://${RealBin}/%s",
        '--mirror-only',
        %s
      );
      $app->doit or exit(1);
    }
INSTALLER

    close $out;

    unlink "mist-install";
    rename "mist-install.tmp", "mist-install";
    chmod 0755, "mist-install";

  } finally {

    unlink "mist-install.tmp"

  };

}



1;
