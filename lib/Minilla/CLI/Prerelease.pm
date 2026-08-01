package Minilla::CLI::Prerelease;

use strict;
use warnings;
use utf8;

use Minilla::Util qw(parse_options);
use Minilla::Logger;
use Minilla::Project;

# The step list is deliberately shorter than a release's, and every omission is
# a decision rather than an accident:
#
#   no DistTest    - the artifact a consumer receives is built later by
#                    `mist merge` from this checkout, so a clean-room test here
#                    would validate something nobody installs. LocalTest runs
#                    the suite in-tree, which is the fast gate a dev loop wants.
#   no MakeDist    - same reason; there is no tarball to build here.
#   no UploadToCPAN- a prerelease is never published.
#   no RewriteChanges - {{$NEXT}} stays intact so the command is re-runnable and
#                    one Changes entry covers a whole prerelease cycle.
#   CommitLocal / TagPrerelease rather than Commit / TagPublish - nothing is
#                    pushed; the deliverable is a versioned commit in this
#                    repository for `mist merge` to build from.
sub run {
  my ( $self, @args ) = @_;

  my $opts = { test => 1, dry_run => 0 };
  parse_options(
    \@args,
    'test!'    => \$opts->{test},
    'dry-run!' => \$opts->{dry_run},
  );

  my $project = Minilla::Project->new();
  return unless $project->validate();

  my @steps = qw(
    CheckUntrackedFiles
    CheckOrigin
    BumpPrerelease
    CheckChangesNoEdit
    RegenerateFiles
    RunHooks
    LocalTest
    CommitLocal
    TagPrerelease
  );

  my @klasses;
  for ( @steps ) {
    my $klass = "Minilla::Release::$_";
    if ( eval "require ${klass}; 1" ) {
      push @klasses, $klass;
      $klass->init() if $klass->can('init');
    } else {
      errorf("Error while loading %s: %s\n", $_, $@);
    }
  }

  $_->run( $project, $opts ) for @klasses;
  return;
}

1;
__END__
