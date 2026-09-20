package Minilla::Release::RewriteTranslatedChanges;

# Mirrors the version line RewriteChanges just stamped into Changes onto every
# translated changelog beside it, and runs immediately after that step.
#
# App::Mist::Command::release has already refused the release if a translation
# was owed, and it did so before anything mutated. So a problem here is an
# inconsistency - the file changed underneath us - rather than a human having
# forgotten to translate, and it says so instead of repeating that advice.

use strict;
use warnings;
use utf8;

use Minilla::Logger;
use Mist::TranslatedChanges qw/
  translated_changelogs head_block_state released_version_line stamp_head_block
/;

sub run {
  my ( $self, $project, $opts ) = @_;
  return if $opts->{dry_run};

  my @pending = grep { head_block_state( $_ ) eq 'filled' }
                translated_changelogs();
  return unless @pending;

  my $version_line = released_version_line();
  errorf( "Changes has no stamped version line under {{\$NEXT}} to mirror into %s.\n",
          join ', ', @pending )
    unless defined $version_line;

  for my $file ( @pending ) {
    stamp_head_block( $file, $version_line )
      or errorf( "%s lost its {{\$HEAD}} marker between the release gate and now.\n",
                 $file );
    infof( "Filed %s under %s\n", $file, $version_line );
  }
}

1;
