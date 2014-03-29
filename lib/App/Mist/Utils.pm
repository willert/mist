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

use App::Mist::Util::StripPod;

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


my %header_appended;
sub append_module_source {
  my ( $module, $fh, %p ) = @_;

  print $fh <<'NO_THANKS' unless $header_appended{ $fh };
  sub __mist::no_thanks {
    my $file = __FILE__;
    for my $mod ( @_ ) {
      ( my $basename = $mod ) =~ s!(::|')!/!g;
      $INC{ "${basename}.pm" } = $file;
    }
  }
NO_THANKS

  $header_appended{ $fh } = 1;

  my $path = module_path( $module )
    or croak "Can't find module ${module}";

  open my $module_source, "<", $path
    or croak "Can't open ${module}: $!";

  printf $fh "\n;%s{\n", $p{begin_lift} ? 'BEGIN' : '';

  my $module_code;
  while ( <$module_source> ) {
    last if /^__END__$/ and not $p{verbatim};

    $module_code .= $_;

    if ( exists $p{until} ) {
      last if ref $p{until} eq 'Regexp' and $_ =~ $p{until};
    }
  }

  unless ( $p{verbatim} ) {
    my $p = App::Mist::Util::StripPod->new;
    $p->output_string( \ my $podless_code );
    $p->parse_string_document( $module_code );
    $module_code = $podless_code;
  }

  print $fh $module_code;

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

    print $fh "}; ";
  }

  unless ( $p{verbatim} ) {
    print $fh " BEGIN{ __mist::no_thanks( '${module}' ) }";
  }

  print $fh " };";
}

1;
