package Minilla::CLI::Prerelease;

use strict;
use warnings;
use utf8;

use Cwd ();
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

  _report_outcome( $project, $opts );
  return;
}

# The run otherwise ends on an echoed `git tag` and stops, leaving its most
# important property - that it committed and tagged LOCALLY and pushed nothing -
# to be taken on faith by whoever has to decide it is safe to run unattended.
#
# Shaped after `mist merge`, which closes with the commands to run next, and
# after `mist release --dry-run`, which prints a scrapeable line for the step
# that follows it.
sub _report_outcome {
  my ( $project, $opts ) = @_;

  # Deliberately not clear_metadata: rebuilding it prints another
  # Name/Abstract/Version banner, and the commit step has already refreshed it.
  # The run prints enough of those without this one adding a fourth.
  my $version = eval { $project->version };
  return unless defined $version;

  if ( $opts->{dry_run} ) {
    infof("DRY-RUN.  Would prerelease %s. Nothing was written, committed or tagged.\n",
          $opts->{dry_run_version} // $version);
    return;
  }

  my $commit = `git rev-parse --short HEAD 2>/dev/null` // '';
  chomp $commit;

  infof("\nPrereleased %s: local commit %s, local tag %s. Nothing pushed.\n",
        $version, ( length $commit ? $commit : '(unknown)' ),
        $project->format_tag( $version ));
  infof("Consume it from the consuming project with:\n  mist merge %s\n",
        Cwd::getcwd());
  return;
}

1;
__END__
