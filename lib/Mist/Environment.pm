package Mist::Environment;
use strict;
use warnings;

use Carp ();

our @bindings;
BEGIN { @bindings = qw( perl assert prepend notest ) };

my $file_id = 1;

sub new {
  my ( $class, $file ) = @_;
  bless { file => $file }, $class;
}

sub bind {
  my $class = shift;
  my $pkg = caller;

  my $result = Mist::Distribution->new;
  for my $binding ( @bindings ) {
    no strict 'refs';
    my $proto = prototype( "Mist::Distribution::${binding}" ) || '';
    $proto = sprintf( '(%s)', $proto ) if $proto;
    *{"$pkg\::${binding}"} = eval " sub $proto { \$result->$binding(\@_); return }; ";
  }

  return $result;
}

sub as_code {
  my ( $self, %args ) = @_;

  my $code = $args{ source } || do {
    local $/ = undef;
    my $file = $self->{file};
    defined $file ? do {
      open my $fh, "<", $file
        or die "could not open $file: $!";
      <$fh>;
    } : '';
  };

  Carp::croak( "Nothing to parse" ) unless defined $code;

  my $package_name = $args{ package };
  $package_name ||= 'Mist::Environment::Sandbox' . $file_id++;

  my $line_pos = $args{ package } ? '' :
    defined( $self->{file} ) ? qq{\n# line 1 "$self->{file}"\n} : '';

  return <<"PERL";
{
  package $package_name;
  no warnings;
  my \$_result;

  BEGIN { \$_result = Mist::Environment->bind }

  $line_pos; $code;

  sub distinfo { \$_result }
  \$_result;
}
PERL

}

sub parse {
  my $self = shift;

  my ( $res, $err );

  {
    local $@;
    $res = eval $self->as_code( @_ );
    $err = $@;
  }

  if ( $err ) {
    die "Parsing $self->{file} failed: $err";
  }

  return $res;
}

1;
