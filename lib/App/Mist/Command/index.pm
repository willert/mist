package App::Mist::Command::index;
use 5.010;

use App::Mist -command;

use Mist::CPAN::PackageIndex;

use CPAN::ParseDistribution;
use CPAN::DistnameInfo;
use CPAN::PackageDetails;

use File::Find;
use Path::Class qw/dir file/;

use version 0.74;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx  = $self->app->ctx;
  my $mpan = Mist::CPAN::PackageIndex->new({
    cpan_dist_root => $ctx->project_root->subdir('mpan-dist')
  });
  $mpan->reindex_distributions;
}

1;
