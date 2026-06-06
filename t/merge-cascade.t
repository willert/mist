#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use File::Temp ();
use File::Spec ();
use File::Path ();
use FindBin ();
use Path::Class ();
use IO::Compress::Gzip qw/ gzip /;

use Mist::PackageManager::MPAN;

# `mist merge` resolves a sibling's declared version pins by letting cpanm
# cascade among the curated file-mirrors (the consumer's own mpan-dist first,
# the sibling's appended last) - never live CPAN. Tested here:
#   1-2. mist emits the right cpanm flags and mirror list (pure, no install).
#   3.   the bundled cpanm cascades on an unsatisfying version - both as a
#        top-level requirement and as a declared prerequisite (the real merge
#        shape) - and stays bounded by the listed mirrors.
# See docs/proposal-merge-dep-propagation.md.

# Keep the mirror list deterministic: the MIST_APP_ROOT branch of
# _build_mirror_list adds another file mirror and prints to STDERR.
BEGIN { delete $ENV{MIST_APP_ROOT} }

my $tmp = File::Temp->newdir( CLEANUP => 1 );

sub mpan {
  my ( $tag, $mirror_only ) = @_;
  return Mist::PackageManager::MPAN->new(
    project_root => Path::Class::dir( "$tmp", $tag ),
    local_lib    => Path::Class::dir( "$tmp", $tag, 'perl5' ),
    mirror_only  => $mirror_only,
  );
}
sub has { my ( $list, $flag ) = @_; scalar grep { $_ eq $flag } @$list }

CASCADE_SCOPED_TO_MIRROR_ONLY: {
  # The fix: --cascade-search is emitted iff mirror_only. This is the guard the
  # long-commented-out line was begging for - cascade-search must never reach the
  # general (non-mirror_only) install path, where the mirror list holds cpan.org.
  my @merge = mpan( 'merge', 1 )->cpanm_install_options;
  ok has( \@merge, '--mirror-only' ),
    'mirror_only install passes --mirror-only';
  ok has( \@merge, '--cascade-search' ),
    'mirror_only install passes --cascade-search';

  my @general = mpan( 'general', 0 )->cpanm_install_options;
  ok !has( \@general, '--cascade-search' ),
    'non-mirror_only install never cascades (no CPAN fallthrough from the general path)';
  ok !has( \@general, '--mirror-only' ),
    'non-mirror_only install is not --mirror-only';
}

MERGE_MIRROR_LIST_OMITS_CPAN: {
  # The other no-fallthrough guard: the merge (mirror_only) mirror list is
  # file-mirrors only, so cascade-search has no cpan.org to fall through to.
  my @merge = mpan( 'm2', 1 )->mirror_list;
  is_deeply [ grep { m{^https?://}i } @merge ], [],
    'mirror_only mirror list is file-mirrors only - no cpan.org to fall through to';

  my @general = mpan( 'g2', 0 )->mirror_list;
  ok scalar( grep { m{cpan\.org}i } @general ),
    'non-mirror_only mirror list includes cpan.org (control)';
}

# --- the bundled cpanm's cascade behaviour, the mechanism the fix relies on ---

my $cpanm = File::Spec->catfile( $FindBin::Bin, File::Spec->updir, 'share', 'cpanm' );

SKIP: {
  skip 'no bundled share/cpanm here (a dist/clean-room checkout)', 10
    unless -f $cpanm;

  my $ap    = 'M/MI/MISTTEST';   # 02packages paths are relative to authors/id/
  my $build = File::Spec->catdir( "$tmp", 'build' );

  # Build a mirror holding one or more buildable pure-perl dists. Each dist is
  # [ pkg, version, prereq-hashref? ]; a prereq becomes PREREQ_PM.
  my $mkmirror = sub {
    my ( $name, @dists ) = @_;
    my $mirror  = File::Spec->catdir( "$tmp", $name );
    my $authors = File::Spec->catdir( $mirror, 'authors', 'id', split m{/}, $ap );
    File::Path::make_path( $authors );

    my @lines;
    for my $d ( @dists ) {
      my ( $pkg, $version, $prereq ) = @$d;
      my $dist = File::Spec->catdir( $build, "$pkg-$version" );
      File::Path::make_path( File::Spec->catdir( $dist, 'lib' ) );
      my $pq = $prereq
        ? ', PREREQ_PM=>{' . join( ',', map "'$_'=>'$prereq->{$_}'", sort keys %$prereq ) . '}'
        : '';
      _spew( File::Spec->catfile( $dist, 'Makefile.PL' ),
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME=>'$pkg',VERSION=>'$version'$pq);\n" );
      _spew( File::Spec->catfile( $dist, 'lib', "$pkg.pm" ),
        "package $pkg;\nour \$VERSION='$version';\n1;\n" );
      system( 'tar', '-czf',
        File::Spec->catfile( $authors, "$pkg-$version.tar.gz" ),
        '-C', $build, "$pkg-$version" ) == 0 or die "tar failed: $?";
      push @lines, sprintf "%-32s %s  %s/%s-%s.tar.gz", $pkg, $version, $ap, $pkg, $version;
    }

    my $mods = File::Spec->catdir( $mirror, 'modules' );
    File::Path::make_path( $mods );
    my $idx = _index_header( $mirror, scalar @lines ) . join( "\n", @lines ) . "\n";
    gzip( \$idx, File::Spec->catfile( $mods, '02packages.details.txt.gz' ) )
      or die 'gzip failed';
    return 'file://' . $mirror;
  };

  my $A = $mkmirror->( 'mirrorA', [ 'Foo', '1.0' ] );   # stale - the consumer's mirror
  my $B = $mkmirror->( 'mirrorB', [ 'Foo', '2.0' ] );   # fresh - the sibling's mirror

  # install($want, @mirror-args) -> ( exit, contained-lib ). cpanm output is
  # captured so it stays out of the TAP stream.
  my $lib_n = 0;
  my $install = sub {
    my ( $want, @args ) = @_;
    my $ll = File::Spec->catdir( "$tmp", 'll-' . $lib_n++ );
    my @cmd = ( $^X, $cpanm, '--quiet', '--mirror-only',
                '--local-lib-contained', $ll, @args, $want );
    my $out = `@{[ map { _sh($_) } @cmd ]} 2>&1`;
    return ( $? >> 8, $ll );
  };

  # (a) Top-level requirement. A answers Foo at 1.0, which fails ~2.0; without
  # cascade cpanm does NOT fall through to B, so the install fails outright.
  my ( $ce, $cll ) = $install->( 'Foo~2.0', '--mirror', $A, '--mirror', $B );
  isnt $ce, 0,
    'top-level: without --cascade-search, an unsatisfying first mirror fails (mode-1 reproduced)';
  is _installed_version( $cll, 'Foo' ), 'none',
    'top-level: nothing is installed';

  my ( $te, $tll ) = $install->( 'Foo~2.0', '--mirror', $A, '--mirror', $B, '--cascade-search' );
  is $te, 0,
    'top-level: with --cascade-search, cpanm cascades to the satisfying version';
  is _installed_version( $tll, 'Foo' ), '2.0',
    'top-level: installs Foo 2.0, from the second mirror';

  # (b) Declared prerequisite - the actual merge shape. The consumer-side mirror
  # carries the stale Foo 1.0 alongside Bar (whose Makefile.PL requires Foo 2.0);
  # the satisfying Foo 2.0 lives only in the appended sibling mirror. The pin is
  # resolved during dependency walking, a different cpanm path than a top-level
  # argv, so it gets its own coverage.
  my $AB = $mkmirror->( 'mirrorAB', [ 'Foo', '1.0' ], [ 'Bar', '1.0', { Foo => '2.0' } ] );

  my ( $pce, $pcll ) = $install->( 'Bar', '--mirror', $AB, '--mirror', $B );
  isnt $pce, 0,
    'prereq: a declared dependency (Bar needs Foo~2.0) fails without cascade';
  is _installed_version( $pcll, 'Foo' ), 'none',
    'prereq: the unsatisfied dependency blocks the build';

  my ( $pte, $ptll ) = $install->( 'Bar', '--mirror', $AB, '--mirror', $B, '--cascade-search' );
  is $pte, 0,
    'prereq: with cascade, the dependency resolves and the dist builds';
  is _installed_version( $ptll, 'Foo' ), '2.0',
    'prereq: Foo 2.0 pulled in as a cascaded dependency';

  # No fallthrough: a module present only in an UNlisted mirror stays
  # unreachable; listing that mirror makes it resolve. Cascade is bounded by the
  # listed mirrors, so a cpan.org-free list cannot reach CPAN.
  my $S = $mkmirror->( 'mirrorS', [ 'Sentinel', '1.0' ] );
  my ( $ue ) = $install->( 'Sentinel', '--mirror', $A, '--mirror', $B, '--cascade-search' );
  isnt $ue, 0,
    'a module only in an unlisted mirror is unreachable (cascade does not fall through)';
  my ( $le ) = $install->( 'Sentinel', '--mirror', $A, '--mirror', $B, '--mirror', $S, '--cascade-search' );
  is $le, 0,
    'listing that mirror makes it resolve (the unreachable result was genuine confinement)';
}

done_testing;

sub _spew {
  my ( $path, $content ) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print $fh $content;
  close $fh;
}

# version string baked into a generated <Mod>.pm by $mkmirror, or 'none'.
sub _installed_version {
  my ( $lib, $mod ) = @_;
  my $pm = File::Spec->catfile( $lib, 'lib', 'perl5', "$mod.pm" );
  return 'none' unless -f $pm;
  open my $fh, '<', $pm or return 'none';
  local $/;
  my ( $v ) = <$fh> =~ /VERSION\s*=\s*'([^']+)'/;
  return $v // 'none';
}

sub _sh { my $s = shift; $s =~ m{\A[\w.\-/:~]+\z} ? $s : "'" . ( $s =~ s/'/'\\''/gr ) . "'" }

sub _index_header {
  my ( $mirror, $count ) = @_;
  return <<"HEADER";
File:         02packages.details.txt
URL:          file://$mirror/modules/02packages.details.txt.gz
Description:  merge-cascade.t fixture mirror
Columns:      package name, version, path
Intended-For: test
Line-Count:   $count
Last-Updated: Sat, 01 Jan 2000 00:00:00 GMT

HEADER
}
