package App::Mist::Utils;

use strict;
use warnings;
use base 'Exporter';

our @EXPORT_OK;
BEGIN { @EXPORT_OK = qw/ append_module_source / }

use Data::Dumper;
use Carp;

use Module::Path qw/ module_path /;
use Scalar::Util qw/ blessed looks_like_number /;

sub append_module_source {
  my ( $module, $fh, %p ) = @_;

  print $fh ";{\n";

  my $path = module_path( $module )
    or croak "Can't find module ${module}";

  open my $module_source, "<", $path or die $!;
  while ( <$module_source> ) {
    next if $_ eq "\n";
    last if /^__END__$/;

    print $fh $_;

    if ( exists $p{until} ) {
      last if ref $p{until} eq 'Regexp' and $_ =~ $p{until};
    }
  }

  if ( exists $p{VARS} and my $vars = $p{VARS} ) {
    $vars = [ %$vars ] if ref $vars eq 'HASH';

    print $fh "; BEGIN {";

    for my $i ( 0 .. ( @{$vars} / 2 - 1 )) {
      my ( $key, $value ) = @{$vars}[ 2*$i, 2*$i + 1 ];
      # carp "Undefined VAR $key" unless defined $value;

      # stringify e.g. Path::Class values
      $value = $value->stringify
        if blessed $value and $value->can('stringify');

      printf $fh "%s;\n",  Data::Dumper->Dump([ $value ], [ $key ]);
    }

    print $fh "};";
  }

  print $fh "};";
}

1;
