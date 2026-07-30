#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Path qw/ mkpath /;
use File::Spec;
use File::Temp qw/ tempdir /;
use FindBin ();

# Drives a real `mist merge` between two throwaway projects.
#
# The other merge tests cover its pieces - t/merge-block-splice.t the mistfile
# rewrite, t/merge-cascade.t the cpanm option surface and mirror cascade,
# t/staging-lib.t that the source wires the staging lib in. None of them run
# App::Mist::Command::merge::execute, which is the path that builds a sibling
# through Minilla and then installs it. This does, and asserts the invariant that
# changed when merge stopped installing into the live environment:
#
#   merge vendors into mpan-dist and rewrites the mistfile; it creates no perl5/.
#
# HOME is redirected into the sandbox so the per-project ~/.mist workspace (and
# cpanm's own home) land there and not in the real one.

my $mist = do { my $p = `command -v mist 2>/dev/null`; chomp $p; $p };
plan skip_all => 'mist not on PATH' unless length $mist and -x $mist;

my $git = do { my $p = `command -v git 2>/dev/null`; chomp $p; $p };
plan skip_all => 'git not on PATH' unless length $git and -x $git;

eval { require Minilla::Project; 1 }
  or plan skip_all => "Minilla not available: $@";

# Subprocesses must not inherit the pinned env of whatever launched this test
# (./mist-run prove), or the global mist detonates on an XS mismatch.
my @PINNING = qw/
  PERL5LIB PERL5OPT MIST_PERLBREW_VERSION MIST_APP_ROOT MIST_PERL5_LIBDIR
  PERLBREW_PERL PERL_LOCAL_LIB_ROOT PERL_MM_OPT PERL_MB_OPT
/;

my $box      = tempdir( 'mist-merge-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $consumer = File::Spec->catdir( $box, 'consumer' );
my $sibling  = File::Spec->catdir( $box, 'sibling' );
my $home     = File::Spec->catdir( $box, 'home' );
mkpath( $_ ) for $consumer, $home, File::Spec->catdir( $sibling, 'lib', 'Merge' );

sub spew {
  my ( $content, @path ) = @_;
  my $file = File::Spec->catfile( @path );
  open my $fh, '>', $file or die "$file: $!";
  print $fh $content;
  close $fh;
  return $file;
}

sub slurp {
  my ( @path ) = @_;
  my $file = File::Spec->catfile( @path );
  open my $fh, '<', $file or return '';
  local $/;
  return <$fh>;
}

# --- the sibling: a minimal Minilla distribution --------------------------
#
# ExtUtilsMakeMaker, not Minilla's ModuleBuildTiny default: MBT would put
# Module::Build::Tiny in configure_requires, and merge resolves strictly from the
# mirrors, so an empty consumer mpan-dist could not satisfy it. EUMM is core.
# Makefile.PL has to be committed - Minilla::WorkDir picks the manifest's build
# file by whether Makefile.PL is present in the work dir, which is populated from
# git, and falls back to Build.PL when it is not.
spew( <<'TOML', $sibling, 'minil.toml' );
name = "Merge-Probe"
module_maker = "ExtUtilsMakeMaker"
TOML

spew( <<'PM', $sibling, 'lib', 'Merge', 'Probe.pm' );
package Merge::Probe;
use strict;
use warnings;
our $VERSION = '0.01';
1;
__END__

=encoding utf-8

=head1 NAME

Merge::Probe - throwaway distribution for exercising mist merge

=head1 DESCRIPTION

Exists only so a test can merge it into another project.

=head1 LICENSE

Copyright (C) Probe.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Probe E<lt>probe@example.invalidE<gt>

=cut
PM

spew( <<'MAKEFILE', $sibling, 'Makefile.PL' );
use ExtUtils::MakeMaker;
WriteMakefile(
  NAME         => 'Merge::Probe',
  VERSION_FROM => 'lib/Merge/Probe.pm',
);
MAKEFILE

spew( "requires 'strict';\n",              $sibling, 'cpanfile' );
spew( "Revision history\n\n{{\$NEXT}}\n\n        - initial\n", $sibling, 'Changes' );
spew( "Same terms as Perl itself.\n",      $sibling, 'LICENSE' );
spew( "# Merge-Probe\n",                   $sibling, 'README.md' );

# Directive-free on purpose: anything declared in the sibling's mistfile is
# installed during the merge, mirror-only, so it would have to exist in the
# consumer's (empty) mpan-dist. Its mere existence is what triggers the splice.
spew( <<'MISTFILE', $sibling, 'mistfile' );
# Merge::Probe's own mist declarations.
MISTFILE

for my $cmd (
  "$git init -q",
  "$git config user.email probe\@example.invalid",
  "$git config user.name Probe",
  "$git add -A",
  "$git commit -q -m 'probe dist'",
) {
  my $status = system "cd $sibling && $cmd >/dev/null 2>&1";
  plan skip_all => "could not prepare the sibling git repo ($cmd)" if $status != 0;
}

# --- the consumer: a mist project with no perl pin, so no perlbrew re-exec ---
spew( "requires 'strict';\n", $consumer, 'cpanfile' );
spew( q{},                    $consumer, 'mistfile' );

# --- run it ---------------------------------------------------------------
my $log = File::Spec->catfile( $box, 'merge.log' );
my $exit = do {
  local %ENV = %ENV;
  delete @ENV{ @PINNING };
  $ENV{HOME} = $home;
  my $raw = system "$mist -C $consumer merge $sibling >$log 2>&1 </dev/null";
  $raw == -1 ? -1 : ( $raw >> 8 );
};

my $output = slurp( $log );
is( $exit, 0, 'mist merge succeeds against a real sibling' )
  or diag( $output );

ok( ! -e File::Spec->catdir( $consumer, 'perl5' ),
  'merge creates no perl5/ - it vendors, it does not install' );

my ( $tarball ) = glob File::Spec->catfile(
  $consumer, 'mpan-dist', '*', 'Merge-Probe-*.tar.gz' );
ok( $tarball, "the sibling's dist is vendored into mpan-dist" );

my $mistfile = slurp( $consumer, 'mistfile' );
like( $mistfile, qr/^### <<<\[Merge::Probe\] - keep this line intact$/m,
  "the consumer's mistfile gains the merge block" );
like( $mistfile, qr/^merge 'Merge::Probe' => sub \{$/m,
  '...wrapping a merge directive for the dist' );
like( $mistfile, qr/^### \[Merge::Probe\]>>> - keep this line intact$/m,
  '...closed by its end marker' );

# The install has to have gone somewhere, and "not perl5/" alone would also hold
# if nothing had been built at all. The staging container under the per-project
# mist workspace is the positive half: it is created only on the path that
# resolves into a throwaway. (The lib inside it is a CLEANUP'd tempdir and is
# gone by now; the container it was made in persists.)
like( $output, qr/Successfully installed Merge-Probe/,
  'the dist really was built and installed' );
my ( $staging ) = glob File::Spec->catdir( $home, '.mist', '*', 'staging' );
ok( $staging && -d $staging,
  '...into a staging lib under the mist workspace, never the project' );

like( $output, qr{\./mpan-install},
  'and the user is told to run ./mpan-install, since nothing was installed for them' );

done_testing;
