package Mist::PackageManager;
use 5.014;
use utf8;

use Path::Class ();

use Moo;
use MooX::late;

use Types::Standard qw( Str Int );
use Type::Utils qw( declare as coerce from );

my $tc_directory = declare as => 'Path::Class::Dir';
coerce $tc_directory, from Str, q{ Path::Class::dir( $_ ) };

has project_root => (
  is       => 'ro',
  isa      => $tc_directory,
  coerce   => 1,
  required => 1,
);

has local_lib => (
  is       => 'ro',
  isa      => $tc_directory,
  coerce   => 1,
  required => 1,
);

has workspace => (
  is         => 'ro',
  isa        => $tc_directory,
  coerce   => 1,
  lazy_build => 1,
);

sub _build_workspace {
  my $self = shift;
  return $self->local_lib;
}

sub begin_work {}
sub install {}
sub commit {}

1;
