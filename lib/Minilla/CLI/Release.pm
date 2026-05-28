package Minilla::CLI::Release;

use strict;
use warnings;
use utf8;
use ExtUtils::MakeMaker qw(prompt);

use Minilla::Util qw(edit_file require_optional parse_options);
use Minilla::WorkDir;
use Minilla::Logger;
use Minilla::Project;

sub run {
  my ($self, @args) = @_;

  my $opts = {
    test    => 1,
    trial   => 0,
    dry_run => 0,
  };
  parse_options(
    \@args,
    'test!'           => \$opts->{test},
    'trial!'          => \$opts->{trial},
    'dry-run!'        => \$opts->{dry_run},
    'pause-config=s'  => \$opts->{pause_config},
  );

  my $project = Minilla::Project->new();
  unless ($project->validate()) {
    return;
  }

  my @steps = qw(
                  CheckUntrackedFiles
                  CheckOrigin
                  CheckReleaseBranch
                  BumpVersionSmart
                  CheckChanges
                  RegenerateFiles
                  RunHooks
                  DistTest
                  MakeDist

                  UploadToCPAN

                  RewriteChanges
                  Commit
                  TagPublish
              );

  my @klasses;
  for (@steps) {
    my $klass = "Minilla::Release::$_";
    if (eval "require ${klass}; 1") {
      push @klasses, $klass;
      $klass->init() if $klass->can('init');
    } else {
      errorf("Error while loading %s: %s\n", $_, $@);
    }
  }

  for my $klass (@klasses) {
    $klass->run($project, $opts);
  }
}

1;
__END__
