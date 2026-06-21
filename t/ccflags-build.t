#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use lib "$FindBin::Bin/lib";

use Config;
use File::Spec;
use File::Temp qw/ tempdir /;
use File::Path qw/ make_path /;

# End-to-end guard for the ccflags host mechanism. build_cpanm_call_stack emits a
# { ccflags => FLAGS } marker on a dist's own build; install.pm's run_cpanm turns
# that into a real compiler flag by reconstructing local::lib's install env (via
# build_environment_vars_for), appending CCFLAGS="$Config{ccflags} FLAGS" to
# PERL_MM_OPT, and running --self-contained so cpanm's own local::lib setup does
# not clobber it. This test reproduces that env-mode against a real mirror and a
# real cpanm build, and asserts:
#   - the flag reaches the flagged dist's Makefile.PL, with $Config{ccflags} kept;
#   - its dependency, built by the undecorated --installdeps call, never sees it.
# It mirrors run_cpanm (lib/Mist/Script/install.pm) and must track it.

eval { require Mist::Distribution; require Mist::Environment;
       require Archive::Tar; require Path::Class; require local::lib; 1 }
  or plan skip_all => "missing prerequisites: $@";

my $arch  = join q{-}, 'perl', $Config{version}, $Config{archname};
my $cpanm = File::Spec->catfile( $FindBin::Bin, File::Spec->updir,
  'perl5', $arch, 'bin', 'cpanm' );
plan skip_all => "no cpanm for this perl at $cpanm" unless -e $cpanm;
plan skip_all => "no make available"
  unless grep { -x File::Spec->catfile( $_, 'make' ) } File::Spec->path;

require Archive::Tar::Constant;
Archive::Tar::Constant->import('COMPRESS_GZIP');
require Mist::CPAN::PackageIndex;

my $root = tempdir( 'mist-ccflags-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

# A dist whose Makefile.PL records the CCFLAGS EUMM resolves into a per-dist file,
# and (optionally) declares a prereq. Pure-perl: no compiler needed, the CCFLAGS
# is captured at the configure step regardless.
sub make_dist {
  my ( $authors, $module, $version, $prereq ) = @_;
  ( my $dist = $module ) =~ s/::/-/g;
  my $base = "$dist-$version";
  ( my $pm_rel = $module ) =~ s{::}{/}g; $pm_rel = "lib/$pm_rel.pm";
  my $prereq_clause = $prereq ? "PREREQ_PM => { '$prereq' => 0 }," : '';
  my $mpl = <<"MPL";
use ExtUtils::MakeMaker;
my \$mm = WriteMakefile( NAME => '$module', VERSION_FROM => '$pm_rel', $prereq_clause );
if ( my \$out = \$ENV{MIST_CCFLAGS_OUT} ) {
  open my \$fh, '>', File::Spec->catfile( \$out, '$dist' ) or die \$!;
  print \$fh ref(\$mm) && defined \$mm->{CCFLAGS} ? \$mm->{CCFLAGS} : '<unset>';
  close \$fh;
}
MPL
  my $tar = Archive::Tar->new;
  $tar->add_data( "$base/$pm_rel", "package $module;\nour \$VERSION='$version';\n1;\n" );
  $tar->add_data( "$base/Makefile.PL", "use File::Spec;\n$mpl" );
  $tar->write( File::Spec->catfile( $authors, "$base.tar.gz" ), COMPRESS_GZIP() );
}

# A Module::Build dist: its Build.PL records the extra_compiler_flags that
# Module::Build resolves from PERL_MB_OPT, proving the MB builder path (not just
# that the env was set). Built only when Module::Build is usable self-contained.
sub make_mb_dist {
  my ( $authors, $module, $version ) = @_;
  ( my $dist = $module ) =~ s/::/-/g;
  my $base = "$dist-$version";
  ( my $pm_rel = $module ) =~ s{::}{/}g; $pm_rel = "lib/$pm_rel.pm";
  my $bpl = <<"BPL";
use File::Spec;
use Module::Build;
my \$b = Module::Build->new(
  module_name => '$module', dist_version => '$version',
  dist_abstract => 'probe', license => 'perl',
);
if ( my \$out = \$ENV{MIST_CCFLAGS_OUT} ) {
  open my \$fh, '>', File::Spec->catfile( \$out, '$dist' ) or die \$!;
  print \$fh join ' ', \@{ \$b->extra_compiler_flags || [] };
  close \$fh;
}
\$b->create_build_script;
BPL
  my $tar = Archive::Tar->new;
  $tar->add_data( "$base/$pm_rel", "package $module;\nour \$VERSION='$version';\n1;\n" );
  $tar->add_data( "$base/Build.PL", $bpl );
  $tar->write( File::Spec->catfile( $authors, "$base.tar.gz" ), COMPRESS_GZIP() );
}

# A real-XS dist. With $guarded, its C source carries `#ifndef MIST_CCTEST #error`,
# so it compiles ONLY if -DMIST_CCTEST reaches the actual C compiler - the
# load-bearing proof that ccflags hits cc, not merely that EUMM resolved it into
# its CCFLAGS hash. Needs a working C toolchain (gated below).
sub make_xs_dist {
  my ( $authors, $module, $version, $guarded ) = @_;
  ( my $dist    = $module ) =~ s/::/-/g;
  ( my $xs_base = $module ) =~ s/.*:://;
  ( my $pm_rel  = $module ) =~ s{::}{/}g; $pm_rel = "lib/$pm_rel.pm";
  my $base = "$dist-$version";

  my $guard = $guarded
    ? qq{#ifndef MIST_CCTEST\n#error "ccflags -DMIST_CCTEST did not reach the C compiler"\n#endif\n}
    : '';
  my $xs = <<"XS";
#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

$guard
MODULE = $module   PACKAGE = $module

int
cctest_ok()
  CODE:
    RETVAL = 1;
  OUTPUT:
    RETVAL
XS

  my $tar = Archive::Tar->new;
  $tar->add_data( "$base/$pm_rel",
    "package $module;\nour \$VERSION='$version';\n"
    . "require XSLoader; XSLoader::load('$module', \$VERSION);\n1;\n" );
  $tar->add_data( "$base/$xs_base.xs", $xs );
  $tar->add_data( "$base/Makefile.PL",
    "use ExtUtils::MakeMaker;\n"
    . "WriteMakefile( NAME => '$module', VERSION_FROM => '$pm_rel' );\n" );
  $tar->write( File::Spec->catfile( $authors, "$base.tar.gz" ), COMPRESS_GZIP() );
}

my $have_mb = eval { require Module::Build; Module::Build->VERSION; 1 };

my $mirror  = File::Spec->catdir( $root, 'mpan' );
my $authors = File::Spec->catdir( $mirror, qw/ authors id L LO LOCAL / );
make_path( $authors );
make_dist( $authors, 'Acme::CcDep',  '0.01' );
make_dist( $authors, 'Acme::CcMain', '0.01', 'Acme::CcDep' );
make_mb_dist( $authors, 'Acme::CcMb', '0.01' ) if $have_mb;
make_xs_dist( $authors, 'Acme::CcPlainXs', '0.01', 0 );   # unguarded: toolchain probe
make_xs_dist( $authors, 'Acme::CcXs',      '0.01', 1 );   # guarded by -DMIST_CCTEST
{
  local *STDOUT; open STDOUT, '>', File::Spec->devnull;
  Mist::CPAN::PackageIndex->new( cpan_dist_root => Path::Class::dir($mirror) )
    ->reindex_distributions;
}

my $lib    = tempdir( 'lib-XXXXXX',  DIR => $root, CLEANUP => 1 );
my $ccout  = tempdir( 'cc-XXXXXX',   DIR => $root, CLEANUP => 1 );
my $FLAG   = '-DMIST_CCFLAGS_T';

# Faithful mirror of run_cpanm: peel a leading { ccflags => ... } marker; env-mode
# for a ccflags call, --local-lib-contained otherwise.
sub run_cpanm_like {
  my @args = @_;
  my %marker;
  %marker = %{ shift @args } if @args and ref $args[0] eq 'HASH';

  local %ENV = %ENV;
  delete @ENV{qw/ PERL_MM_OPT PERL_MB_OPT PERL_LOCAL_LIB_ROOT PERL5LIB /};
  $ENV{HOME} = tempdir( 'home-XXXXXX', DIR => $root, CLEANUP => 1 );
  $ENV{MIST_CCFLAGS_OUT} = $ccout;

  my @opts = ( '--quiet', '--mirror', "file://$mirror", '--mirror-only', '--notest' );
  if ( defined $marker{ccflags} and length $marker{ccflags} ) {
    my %ll = local::lib->build_environment_vars_for( $lib );
    $ENV{$_} = $ll{$_} for grep { defined $ll{$_} } keys %ll;
    my $flags = $marker{ccflags};
    $ENV{PERL_MM_OPT} = join q{ },
      ( defined $ENV{PERL_MM_OPT} && length $ENV{PERL_MM_OPT} ? $ENV{PERL_MM_OPT} : () ),
      qq{CCFLAGS="$Config{ccflags} $flags"};
    $ENV{PERL_MB_OPT} = join q{ },
      ( defined $ENV{PERL_MB_OPT} && length $ENV{PERL_MB_OPT} ? $ENV{PERL_MB_OPT} : () ),
      qq{--extra_compiler_flags="$flags"};
    push @opts, '--self-contained';
  } else {
    push @opts, "--local-lib-contained=$lib";
  }
  return system( $cpanm, @opts, @args ) == 0;
}

# Build the call stack for a ccflags directive on the dist with the dependency.
my $dist = Mist::Environment->new->parse(
  source => "ccflags q{Acme::CcMain} => q{$FLAG};" );
my @stack = $dist->build_cpanm_call_stack( { 'skip-core-satisfied' => 1 }, 'Acme::CcMain' );

# Sanity: the stack is the undecorated installdeps call then the marked dist call.
is_deeply \@stack,
  [ [ '--installdeps', 'Acme::CcMain' ],
    [ { ccflags => $FLAG }, 'Acme::CcMain' ] ],
  'call stack: undecorated --installdeps, then the ccflags-marked dist build';

my $ok = 1;
$ok &&= run_cpanm_like( @$_ ) for @stack;
ok $ok, 'cpanm built the dependency and the flagged dist via the two-call split'
  or diag "cpanm build failed";

SKIP: {
  skip "build did not complete", 3 unless $ok;

  my $main_cc = do {
    my $f = File::Spec->catfile( $ccout, 'Acme-CcMain' );
    -e $f ? do { local $/; open my $fh, '<', $f; <$fh> } : '<no record>';
  };
  my $dep_cc = do {
    my $f = File::Spec->catfile( $ccout, 'Acme-CcDep' );
    -e $f ? do { local $/; open my $fh, '<', $f; <$fh> } : '<no record>';
  };

  like $main_cc, qr/\Q$FLAG\E/,
    'the ccflags flag reaches the flagged dist Makefile.PL';
  like $main_cc, qr/\Q$Config{ccflags}\E/,
    'the default $Config{ccflags} is preserved (prepended), not clobbered';
  unlike $dep_cc, qr/\Q$FLAG\E/,
    'the dependency, built by the --installdeps call, never sees the flag (no leak)';
}

# Module::Build path: the same env-mode appends --extra_compiler_flags to
# PERL_MB_OPT; assert Module::Build actually resolves it into extra_compiler_flags.
SKIP: {
  skip "Module::Build not usable for an MB-builder smoke", 1 unless $have_mb;
  my @mb_stack = Mist::Environment->new
    ->parse( source => "ccflags q{Acme::CcMb} => q{$FLAG};" )
    ->build_cpanm_call_stack( { 'skip-core-satisfied' => 1 }, 'Acme::CcMb' );
  my $built = 1;
  $built &&= run_cpanm_like( @$_ ) for @mb_stack;

  skip "Module::Build dist did not build (not usable self-contained here)", 1
    unless $built;

  my $mb_flags = do {
    my $f = File::Spec->catfile( $ccout, 'Acme-CcMb' );
    -e $f ? do { local $/; open my $fh, '<', $f; <$fh> } : '<no record>';
  };
  like $mb_flags, qr/\Q$FLAG\E/,
    'Module::Build resolves the ccflags flag into extra_compiler_flags (PERL_MB_OPT path)';
}

# Real C-compile proof. The scenarios above prove EUMM/MB *resolve* the flag; this
# proves it reaches the actual compiler. Acme::CcXs's XS guards on
# `#ifndef MIST_CCTEST #error`, so it compiles only if ccflags delivers
# -DMIST_CCTEST to cc.
SKIP: {
  # Gate on a usable XS toolchain by building the unguarded probe dist. If even
  # that cannot compile, there is no working compiler/headers here - skip, so a
  # genuine flag-delivery failure is never masked as a toolchain problem.
  skip "no usable XS toolchain", 2 unless run_cpanm_like( 'Acme::CcPlainXs' );

  # Control (runs first; installs nothing on failure): without the flag the guard
  # fires and the build must fail - proving the success below is the flag's doing.
  ok ! run_cpanm_like( 'Acme::CcXs' ),
    'without the flag, the guarded XS fails to compile (#error fires)';

  # With ccflags, -DMIST_CCTEST must reach cc and suppress the #error.
  my @xs_stack = Mist::Environment->new
    ->parse( source => "ccflags q{Acme::CcXs} => q{-DMIST_CCTEST};" )
    ->build_cpanm_call_stack( { 'skip-core-satisfied' => 1 }, 'Acme::CcXs' );
  my $xs_built = 1;
  $xs_built &&= run_cpanm_like( @$_ ) for @xs_stack;
  ok $xs_built,
    'ccflags delivers -DMIST_CCTEST to the C compiler: the guarded XS compiles and installs';
}

done_testing;
