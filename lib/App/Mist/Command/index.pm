package App::Mist::Command::index;
# ABSTRACT: Re-index local mpan-dist

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

__END__

=pod

=head1 NAME

App::Mist::Command::index - rebuild the mpan-dist package index

=head1 SYNOPSIS

  mist index

=head1 DESCRIPTION

Rebuilds F<mpan-dist/modules/02packages.details> (and its C<.txt.gz>
companion) by scanning every distribution tarball physically present under
F<mpan-dist/>.

C<inject>, C<merge> and C<upgrade> re-index automatically, so you normally
do not need C<index>; reach for it after adding or removing a tarball under
F<mpan-dist/> by hand.

=head1 SEE ALSO

L<App::Mist::Command::inject>, L<App::Mist::Command::clean>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
