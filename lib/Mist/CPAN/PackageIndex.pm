package Mist::CPAN::PackageIndex;
use 5.014;
use utf8;

use Moo;

has cpan_dist_root => (
  is       => 'ro',
  required => 1,
);

with 'Mist::Role::CPAN::PackageIndex';

__PACKAGE__->meta->make_immutable;

1;
