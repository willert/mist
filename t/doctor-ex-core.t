#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Spec;
use FindBin ();

# `mist doctor` reports modules that are core in the project's perl, are NOT core
# in some other perl, and are not vendored in mpan-dist - the set a build on a
# newer perl would have to find somewhere else.
#
# The comparison is run against real perls rather than fixtures, because the
# whole point is that a perl's own Module::CoreList is the only thing that knows
# its core set: the 5.20.3 copy mist runs under stops at 5.23.2 and cannot answer
# for anything later. That also makes this test environment-dependent, so it
# skips rather than guesses when the pieces are missing.

my $mist = do { my $p = `command -v mist 2>/dev/null`; chomp $p; $p };
plan skip_all => 'mist not on PATH' unless length $mist and -x $mist;

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );

my $other = '/usr/bin/perl';
plan skip_all => "no system perl at $other" unless -x $other;

my $other_version = do { my $v = `$other -e 'printf "%vd", \$^V' 2>/dev/null`; $v };
plan skip_all => 'cannot determine the other perl version'
  unless defined $other_version and length $other_version;

# Module::CoreList has to know that perl, or there is nothing to compare against
# and doctor deliberately says nothing.
my $knows = `$other -MModule::CoreList -e 'print exists \$Module::CoreList::version{ \$] + 0 } ? 1 : 0' 2>/dev/null`;
plan skip_all => "Module::CoreList on $other does not know $other_version"
  unless $knows;

my $out = `$mist -C $repo doctor --perl $other 2>&1`;

REPORTS_A_GAP: {
  like $out, qr/module\(s\) are core in this project's perl/,
    'a 5.20.3-pinned project has an ex-core gap against a modern perl';
  like $out, qr/\Q$other_version\E/, '...naming the perl it compared against';
}

NAMES_THE_KNOWN_EVICTIONS: {
  # These left core between 5.20.3 and 5.38 and mist does not vendor them.
  like $out, qr/^\s+CGI\s+\d+/m,     'CGI is reported';
  like $out, qr/^\s+Locale\s+\d+/m,  'the Locale::Codes family is reported';
  like $out, qr/^\s+Pod\s+\d+/m,     'the Pod::Parser modules are reported';
}

EXCLUDES_WHAT_THE_MIRROR_ALREADY_CARRIES: {
  # mist vendors Module-Build, so Module::Build itself must not be listed - only
  # the submodules its index does not carry. Reported as a group, so check the
  # verbose form where individual names appear.
  my $verbose = `$mist -C $repo doctor --perl $other --verbose 2>&1`;
  unlike $verbose, qr/^\s+Module::Build$/m,
    'a module the mirror vendors is not reported as missing';
  like $verbose, qr/^\s+CGI$/m,
    '...while one it does not vendor is';
}

GROUPS_BY_DEFAULT: {
  like $out, qr/--verbose lists them individually/,
    'the default report is grouped, and says how to expand it';
  unlike $out, qr/Locale::Codes::LangVar_Retired/,
    '...so a 27-module family does not flood the output';
}

done_testing;
