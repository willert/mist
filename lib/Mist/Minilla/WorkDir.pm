package Mist::Minilla::WorkDir;
use strict;
use warnings;
use utf8;

use Minilla::Util qw/ slurp_raw spew_raw /;
use Mist::TranslatedChanges qw/
  translated_changelogs consume_head_marker drop_spent_head_marker
/;

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
#
# Translated changelogs beside it take whichever decision Changes took, so the
# dist never ships one file stamped and its translation still carrying a
# template marker.
sub _rewrite_changes {
  my $self = shift;

  my $changes = slurp_raw('Changes');

  if ( $changes =~ /^\{\{\$NEXT\}\}\h*\R+\h+\S/m ) {
    $self->SUPER::_rewrite_changes();

    my $stamp = $self->project->version . ' '
              . $self->changes_time->strftime('%Y-%m-%dT%H:%M:%SZ');
    consume_head_marker( $_, $stamp ) for translated_changelogs();
    return;
  }

  $changes =~ s/^\{\{\$NEXT\}\}\h*\R*//m;
  spew_raw( 'Changes', $changes );

  drop_spent_head_marker( $_ ) for translated_changelogs();
  return;
}

1;
