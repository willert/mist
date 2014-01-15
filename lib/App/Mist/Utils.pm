package App::Mist::Utils;

use strict;
use warnings;
use base 'Exporter';

our @EXPORT_OK;
BEGIN { @EXPORT_OK = qw/ append_module_source append_text_file / }

use Data::Dumper;
use Carp;

use Module::Path qw/ module_path /;
use Scalar::Util qw/ blessed looks_like_number /;
use Digest::MD5  qw/ md5_hex /;

sub append_text_file {
  my ( $textfile, $fh, %p ) = @_;
  my $pkg = $p{as} || $p{package}
    or croak "append_text_file needs a package name";

  croak "Invalid package name ${pkg}"
    unless $pkg =~ m/ ^ [a-z] (?:\w+::)* \w+ $ /ix;

  my $document = do {
    local $/ = undef;
    open my $fh, "<", $textfile
      or croak "Can't open ${textfile}: $!";
    <$fh>;
  };

  my $delimiter = join( q{_}, 'TEXTFILE', uc( md5_hex( $document )));

  print $fh sprintf( <<'PERL', $pkg, $delimiter, $document, $delimiter );
;{
  package %s;

  sub get_content {
    my $content = <<'%s';
%s
%s
    chomp $content;
    return $content;
  }
  1;
};
PERL

  return;
}

sub append_module_source {
  my ( $module, $fh, %p ) = @_;

  my $path = module_path( $module )
    or croak "Can't find module ${module}";

  open my $module_source, "<", $path
    or croak "Can't open ${module}: $!";

  print $fh ";{\n";

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
