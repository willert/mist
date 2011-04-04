package App::Mist::Command::inject;

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

  die "$0: No module to install"
    unless $args and ref $args eq 'ARRAY' and @$args;

  my $mpan      = $self->app->mpan_dist;
  my $local_lib = $self->app->local_lib;
  my $workspace = $self->app->workspace_lib;

  my @options   = (
    "--quiet",
    "--local-lib-contained=${workspace}",
    "--mirror-only",
    "--mirror=file://${mpan}",
    "--mirror=http://search.cpan.org/CPAN",
    "--save-dists=${mpan}",
  );

  $self->app->run_cpanm( @options, @$args );
}



1;
