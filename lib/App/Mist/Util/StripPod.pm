package App::Mist::Util::StripPod;
# shamelessly stolen from POD::Strip by domm

use warnings;
use strict;

use base ('Pod::Simple');

our $VERSION = "0.32";

sub new {
  my $new = shift->SUPER::new(@_);
  $new->{_code_line}=0;
  $new->code_handler( sub {
    print {$_[2]{output_fh}} $_[0],"\n";
    return;
  });
  return $new;
}



1;
