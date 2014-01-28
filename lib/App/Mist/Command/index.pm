package App::Mist::Command::index;
use 5.014;

use Moose;
extends 'MooseX::App::Cmd::Command';
with 'Mist::Role::CPAN::PackageIndex';

sub use_cpan_dist_root { my $self = shift; $self->app->project_root->subdir('mpan-dist') }

use CPAN::ParseDistribution;
use CPAN::DistnameInfo;
use CPAN::PackageDetails;

use File::Find;
use Path::Class qw/dir file/;

use version 0.74;

sub execute {
  my ( $self, $opt, $args ) = @_;
  $self->reindex_distributions;
}

1;
