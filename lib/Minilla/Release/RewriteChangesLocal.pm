package Minilla::Release::RewriteChangesLocal;
use strict;
use warnings;
use utf8;
use Minilla::Util qw(slurp_raw spew_raw);
use Time::Piece qw(gmtime);

sub run {
  my ($self, $project, $opts) = @_;
  return if $opts->{dry_run};

  my $content = slurp_raw('Changes');
  $content =~ s!\{\{\$NEXT\}\}!
    "{{\$NEXT}}\n\n" . $project->version . " " . scalar(gmtime())->strftime('%Y-%m-%d %H:%M')
    !e;

  spew_raw('Changes' => $content);
}

1;
