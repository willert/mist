#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use Cwd ();
use File::Path ();
use File::Spec ();
use File::Temp qw/ tempdir /;
use FindBin ();
use Path::Class qw/ dir /;

# `mist inject` and `mist merge` vendor into mpan-dist; they must not install
# into the live environment, which is an immutable generation owned by
# ./mpan-install. Both resolve into $ctx->staging_lib instead. What is asserted
# here is that staging lib's contract:
#   1. it lives outside the project, and building one creates no perl5/
#   2. it is seeded copy-on-write from the live generation, so cpanm resolves
#      against what is installed and only builds the delta
#   3. the seeded files that get written in place - perllocal.pod, cpanm's .meta
#      receipts - are not shared, so nothing can write through into the live env
#   4. inject and merge actually use it
# Run under the project env (./mist-run prove): loading the context needs the
# vendored Moo stack.
eval { require App::Mist::Context; 1 }
  or plan skip_all => "cannot load App::Mist::Context: $@";

my $cwd = Cwd::getcwd();   # the context chdirs to its project root on build
END { chdir $cwd if defined $cwd }

my $tmp = dir( tempdir( 'mist-staging-XXXXXX', TMPDIR => 1, CLEANUP => 1 ) );

# Whether this filesystem can hard-link at all: without it the seed falls back to
# a real copy, which is correct but shares no inodes.
my $can_link = do {
  my $file = $tmp->file( 'link-probe' );
  $file->touch;
  my $ok = link "$file", $tmp->file( 'link-probe-2' )->stringify;
  unlink $file->stringify, $tmp->file( 'link-probe-2' )->stringify;
  $ok;
};

# A stand-in for an installed generation: one installed module, plus the two
# kinds of bookkeeping that get rewritten in place rather than installed anew.
sub live_generation {
  my ( $root ) = @_;
  my $arch = $root->subdir( 'lib', 'perl5', 'x86_64-linux' );
  $arch->mkpath;
  $arch->parent->file( 'Installed.pm' )->spew( "package Installed;\n1;\n" );
  $arch->file( 'perllocal.pod' )->spew( "=head2 installed\n" );
  my $meta = $arch->subdir( '.meta', 'Installed-1.00' );
  $meta->mkpath;
  $meta->file( 'install.json' )->spew( '{"name":"Installed"}' );
  return $root;
}

sub context {
  my %args = @_;
  return App::Mist::Context->new({
    project_root => $args{project_root},
    workspace    => $args{workspace},
    ( $args{local_lib} ? ( local_lib => $args{local_lib} ) : () ),
  });
}

SEEDED_FROM_THE_LIVE_GENERATION: {
  my $project = $tmp->subdir( 'seeded' );
  $project->mkpath;
  my $live = live_generation( $tmp->subdir( 'seeded-live' ) );

  my $staging = context(
    project_root => $project,
    workspace    => $tmp->subdir( 'workspace-seeded' ),
    local_lib    => $live,
  )->staging_lib;

  # The separator matters: without it a sibling directory whose name merely
  # starts with the project's would read as being inside it.
  unlike( "$staging", qr{^\Q$project\E/}, 'staging lib is outside the project' );
  ok( ! -e $project->subdir( 'perl5' )->stringify,
    'building a staging lib creates no perl5/ in the project' );

  my $installed = $staging->file( 'lib', 'perl5', 'Installed.pm' );
  ok( -f "$installed", 'the live generation seeded the staging lib' );

  SKIP: {
    skip 'no hard links on this filesystem', 1 unless $can_link;
    my @seed  = stat $live->file( 'lib', 'perl5', 'Installed.pm' )->stringify;
    my @stage = stat "$installed";
    is( "$stage[0]:$stage[1]", "$seed[0]:$seed[1]",
      'an installed file is hard-linked, not copied (copy-on-write seed)' );
  }

  my $arch = $staging->subdir( 'lib', 'perl5', 'x86_64-linux' );
  ok( ! -e $arch->file( 'perllocal.pod' )->stringify,
    'perllocal.pod is not shared with the live generation (appended in place)' );
  ok( ! -e $arch->subdir( '.meta' )->stringify,
    'cpanm receipts are not shared with the live generation (rewritten in place)' );

  ok( -f $live->subdir( 'lib', 'perl5', 'x86_64-linux' )
           ->file( 'perllocal.pod' )->stringify,
    'shedding those touches only the staging lib, never the live generation' );
  ok( -f $live->subdir( 'lib', 'perl5', 'x86_64-linux', '.meta', 'Installed-1.00' )
           ->file( 'install.json' )->stringify,
    'the live generation keeps its receipts' );
}

NO_LIVE_GENERATION_YET: {
  # The reported bug: on a fresh project the injects of `mist init` created
  # perl5/<arch_path> as a real directory before any generation ladder existed,
  # and the next ./mpan-install took its pre-generation migration path and
  # renamed it aside. Nothing may create that path but ./mpan-install.
  my $project = $tmp->subdir( 'fresh' );
  $project->mkpath;

  my $staging = context(
    project_root => $project,
    workspace    => $tmp->subdir( 'workspace-fresh' ),
  )->staging_lib;

  ok( -d "$staging", 'a project with no generation yet still gets a staging lib' );
  ok( ! -e $project->subdir( 'perl5' )->stringify,
    'and no perl5/ is created for it to migrate aside' );
}

INJECT_AND_MERGE_USE_IT: {
  # The staging lib only helps where it is wired in, and the wiring is a single
  # constructor argument that reads almost the same either way.
  my $lib = File::Spec->catdir( $FindBin::Bin, File::Spec->updir, 'lib' );

  for my $command (qw/ inject merge /) {
    my $file = File::Spec->catfile(
      $lib, 'App', 'Mist', 'Command', "${command}.pm" );
    open my $fh, '<', $file or die "open $file: $!";
    my $source = do { local $/; <$fh> };
    close $fh;

    like( $source, qr/local_lib \s* => \s* \$ctx->staging_lib/x,
      "$command resolves into the staging lib" );
    unlike( $source, qr/local_lib \s* => \s* \$ctx->local_lib/x,
      "$command never installs into the live environment" );
  }
}

done_testing;
