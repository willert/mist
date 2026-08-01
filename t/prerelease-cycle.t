#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use Capture::Tiny qw/ capture /;   # compile time: `capture {}` needs the prototype
use Cwd ();
use File::Path qw/ mkpath /;
use File::Spec;
use File::Temp ();

# The prerelease cycle end to end, against a real git repository.
#
# The unit tests cover the version arithmetic; this covers the pipeline, which
# is where the interesting failures were. Everything asserted here was first
# observed by running `mist prerelease` by hand against a throwaway project -
# including the two wrinkles at the bottom, which no amount of reasoning about
# the step list would have produced.

eval { require Minilla::CLI::Prerelease; 1 }
  or plan skip_all => "cannot load Minilla::CLI::Prerelease: $@";
my $git = `git --version 2>/dev/null`;
plan skip_all => 'git unavailable' unless $git =~ /git version/;

my $cwd = Cwd::getcwd();
END { chdir $cwd if defined $cwd }

# Minilla insists on an origin with a URL scheme (a bare path fails META
# validation), on author and license POD, and on a {{$NEXT}} entry.
sub fixture {
  my $tmp  = File::Temp->newdir( CLEANUP => 1 );
  my $root = "$tmp";
  my $proj = File::Spec->catdir( $root, 'proj' );
  mkpath( File::Spec->catdir( $proj, 'lib', 'Foo' ) );

  system( qw/git init -q --bare/, File::Spec->catdir( $root, 'origin.git' ) ) == 0
    or return;

  my %file = (
    'minil.toml' => qq{name = "Foo-Bar"\nmodule_maker = "ExtUtilsMakeMaker"\n}
                  . qq{[release]\ndo_not_upload_to_cpan = true\n},
    'cpanfile'   => "requires 'perl' => '5.020003';\n",
    'mistfile'   => "perl '5.20.3';\n",
    'Changes'    => "Revision history for Foo-Bar\n\n{{\$NEXT}}\n\n"
                  . "  - something worth releasing\n\n0.10 2026-01-01T00:00:00Z\n\n  - first\n",
    'lib/Foo/Bar.pm' => join( "\n",
      'package Foo::Bar;',
      q{our $VERSION = '0.10';},
      '',
      '=head1 NAME',
      '',
      'Foo::Bar - a fixture',
      '',
      '=head1 AUTHOR',
      '',
      'Test Person',
      '',
      '=head1 LICENSE',
      '',
      'Same terms as Perl itself.',
      '',
      '=cut',
      '',
      '1;',
      '' ),
  );
  for my $rel ( sort keys %file ) {
    my $path = File::Spec->catfile( $proj, split m{/}, $rel );
    open my $fh, '>', $path or die "$path: $!";
    print $fh $file{ $rel };
    close $fh;
  }

  chdir $proj or die;
  system( qw/git init -q/ ) == 0                                  or return;
  system( qw/git config user.email t@example.com/ ) == 0          or return;
  system( qw/git config user.name Test/ ) == 0                    or return;
  system( 'git', 'remote', 'add', 'origin',
          'file://' . File::Spec->catdir( $root, 'origin.git' ) ) == 0 or return;
  commit_all( 'fixture' ) or return;
  chdir $cwd or die;

  return ( $proj, $tmp );   # $tmp held so CLEANUP does not fire early
}

sub commit_all {
  my ( $message ) = @_;
  system( qw/git add -A/ ) == 0 or return;
  my ( undef, undef, $rc ) = capture { system( 'git', 'commit', '-q', '-m', $message ) };
  return 1;
}

sub prerelease {
  my ( $proj ) = @_;
  chdir $proj or die;
  my ( $out, $err, $ok ) = capture {
    eval { Minilla::CLI::Prerelease->run('--no-test'); 1 } ? 1 : 0;
  };
  chdir $cwd or die;
  return { output => "$out$err", ok => $ok };
}

sub version_in {
  my ( $proj ) = @_;
  open my $fh, '<', File::Spec->catfile( $proj, 'lib', 'Foo', 'Bar.pm' ) or return;
  local $/;
  my $src = <$fh>;
  return $src =~ m{\$VERSION \s* = \s* (\S+?) \s* ;}x ? $1 : undef;
}

sub tags_in {
  my ( $proj ) = @_;
  chdir $proj or die;
  my @tags = sort map { chomp; $_ } `git tag --list`;
  chdir $cwd or die;
  return @tags;
}

sub changes_in {
  my ( $proj ) = @_;
  open my $fh, '<', File::Spec->catfile( $proj, 'Changes' ) or return '';
  local $/;
  return scalar <$fh>;
}

my ( $proj, $keep ) = fixture();
plan skip_all => 'could not build a git fixture here' unless defined $proj;

FIRST_ITERATION: {
  my $run = prerelease( $proj );
  ok $run->{ok}, 'a prerelease runs to completion'
    or diag $run->{output};

  is version_in( $proj ), q{'0.10_01'},
    'the version gains a trial component - and is written QUOTED, without '
      . 'which Perl would discard the underscore';
  like $run->{output}, qr/Prerelease 0\.10_01/, '...and says so';
  is_deeply [ tags_in( $proj ) ], ['0.10_01'], 'the iteration is tagged';
  like changes_in( $proj ), qr/\Q{{\E\$NEXT\Q}}\E/,
    'Changes keeps its placeholder, so one entry covers the whole cycle';
}

# RegenerateFiles writes META.json/Makefile.PL/README.md, and CommitLocal runs
# `git commit -a`, which never picks up untracked files. So the first prerelease
# in a project that does not yet track them leaves them behind and the next run
# is refused by CheckUntrackedFiles. Observed, not predicted.
GENERATED_FILES_MUST_BE_TRACKED: {
  my $run = prerelease( $proj );
  ok !$run->{ok}, 'a second run is refused while generated files are untracked';
  like $run->{output}, qr/Unknown local files/, '...naming the reason';
  like $run->{output}, qr/META\.json/,          '...and the files';
  is version_in( $proj ), q{'0.10_01'},
    'and nothing is bumped when the run is refused up front';
}

SECOND_ITERATION: {
  chdir $proj or die;
  commit_all( 'track generated files' );
  chdir $cwd or die;

  my $run = prerelease( $proj );
  ok $run->{ok}, 'once they are tracked, the cycle continues'
    or diag $run->{output};

  is version_in( $proj ), q{'0.10_02'}, 'the trial component advances';
  is_deeply [ tags_in( $proj ) ], [ '0.10_01', '0.10_02' ],
    'every iteration keeps its own tag - nothing is force-moved onto another';
  like changes_in( $proj ), qr/\Q{{\E\$NEXT\Q}}\E/,
    '...and Changes still has the placeholder';
}

ITERATIONS_ARE_DISTINCT_AND_ORDERED: {
  # The property the whole scheme exists for: a consumer's mirror can hold
  # several iterations and resolve the newest, and none of them satisfies a
  # requirement for the release that ends the cycle.
  require version;
  my @tags = tags_in( $proj );
  # Parenthesised: `ok version->parse(...)` parses as `version->ok(...)`.
  ok( version->parse( $tags[1] ) > version->parse( $tags[0] ),
      "$tags[1] sorts above $tags[0]" );
  ok( version->parse( $tags[1] ) < version->parse( '0.11' ),
      "...and below 0.11, the release they lead to" );
}

chdir $cwd;   # before File::Temp tears the fixture down under us
done_testing;
