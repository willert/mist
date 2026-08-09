package Mist::Minilla::WorkDir;
use strict;
use warnings;
use utf8;

use Minilla::Util qw/ slurp_raw spew_raw /;

use Moo;
extends 'Minilla::WorkDir';

# At a tagged release {{$NEXT}} is empty - the release already rewrote the
# line below it - and stock Minilla still stamps the placeholder with
# <version> <build time>, fabricating a duplicate release line that varies
# per build: rebuilding the same tag then yields a different tarball. An
# empty placeholder is dropped instead, so the dist's Changes matches the
# source verbatim. A placeholder with pending entries keeps the stock stamp:
# that is a snapshot build (mist merge --dev mid-cycle), where a build-time
# release line is the honest reading.
sub _rewrite_changes {
  my $self = shift;

  my $changes = slurp_raw('Changes');

  return $self->SUPER::_rewrite_changes()
    if $changes =~ /^\{\{\$NEXT\}\}\h*\R+\h+\S/m;

  $changes =~ s/^\{\{\$NEXT\}\}\h*\R*//m;
  spew_raw( 'Changes', $changes );
  return;
}

1;
