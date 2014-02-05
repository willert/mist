package Mist::PackageManager;
use 5.014;
use utf8;

use Moose;
use Moose::Util::TypeConstraints ();
use Path::Class ();

my $tc_directory = Moose::Util::TypeConstraints::subtype({
  as => 'Path::Class::Dir',
});

Moose::Util::TypeConstraints::coerce(
  $tc_directory, 'Str', sub { Path::Class::dir( $0 ) }
);

has project_root => (
  is       => 'ro',
  isa      => $tc_directory,
  required => 1,
);

has local_lib => (
  is       => 'ro',
  isa      => $tc_directory,
  required => 1,
);

has workspace => (
  is         => 'ro',
  isa        => $tc_directory,
  lazy_build => 1,
);

sub _build_workspace {
  my $self = shift;
  return $self->local_lib;
}


has mirror_list => (
  is         => 'bare',
  isa        => 'ArrayRef',
  traits     => [qw/ Array /],
  lazy_build => 1,
  handles    => {
    mirror_list  => 'elements',
    add_mirror   => 'push',
  },
);

sub _build_mirror_list {[ 'http://www.cpan.org/']}

sub begin_work {}
sub install {}
sub commit {}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
