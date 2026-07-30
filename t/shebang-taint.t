#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

# `mist compile` warns about a shebang that puts perl in taint mode, because a
# tainted script cannot work in a mist project at all: taint makes perl ignore
# PERL5LIB, which is the only way mist hands a script the project's libraries,
# so every vendored module goes missing. (And `#!/usr/bin/env perl -T` never
# starts, since the kernel passes env the single word "perl -T".)
#
# The detection parses rather than greps: a bare /-T/ would fire on an
# interpreter path, and a non-perl interpreter's -T means something else.
eval { require App::Mist::Command::compile; 1 }
  or plan skip_all => "cannot load App::Mist::Command::compile: $@";

my $taints = \&App::Mist::Command::compile::_shebang_enables_taint;

my @tainted = (
  '#!/usr/bin/perl -T'              => 'the plain form',
  '#!/usr/bin/perl -wT'             => 'bundled after -w',
  '#!/usr/bin/perl -Tw'             => 'bundled before -w',
  '#!/usr/bin/perl -T -w'           => 'as a separate switch',
  '#!/usr/bin/env perl -T'          => 'the env form, which cannot even start',
  '#!/usr/local/bin/perl5.20.3 -T'  => 'a versioned interpreter',
  '#! /usr/bin/perl -T'             => 'a space after the bang',
);

while ( my ( $shebang, $why ) = splice @tainted, 0, 2 ) {
  ok $taints->( $shebang ), "tainted: $why  [$shebang]";
}

my @clean = (
  '#!/usr/bin/env perl'             => 'the recommended shebang',
  '#!/usr/bin/perl'                 => 'a bad shebang, but not a tainted one',
  '#!/usr/bin/perl -w'              => '-w is not -T',
  '#!/usr/bin/perl -l'              => 'another lowercase switch',
  '#!/opt/perl-T/bin/perl'          => '-T inside the interpreter PATH',
  '#!/opt/perl-T/bin/perl -w'       => '...even with other switches present',
  '#!/bin/sh -T'                    => 'a non-perl interpreter taking its own -T',
  '#!/usr/bin/env python -T'        => 'env running something that is not perl',
  '#!/usr/bin/perl --taint-ish'     => 'a long option is never taint',
  'print "no shebang at all\n";'    => 'a file that is not a script',
  ''                                => 'an empty first line',
);

while ( my ( $shebang, $why ) = splice @clean, 0, 2 ) {
  ok !$taints->( $shebang ), "clean:   $why  [$shebang]";
}

ok !$taints->( undef ), 'clean:   an unreadable/empty file yields undef, not a warning';

done_testing;
