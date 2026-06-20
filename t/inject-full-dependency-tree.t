#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Temp qw/ tempdir /;
use File::Path qw/ mkpath /;
use File::Spec;

# inject --full-dependency-tree resolves the target's whole tree in a clean-room
# lib and reads the resolved versions back from cpanm's install.json receipts.
# _resolved_floors is that read-back, isolated so it can be exercised against a
# synthetic receipt tree without a real cpanm run. Loading the command pulls in
# App::Mist (needs this repo's perl5 env), so run under ./mist-run prove.
eval { require App::Mist::Command::inject; 1 }
  or plan skip_all => "cannot load App::Mist::Command::inject: $@";

sub floors { App::Mist::Command::inject::_resolved_floors( @_ ) }

# Lay down a receipt the way cpanm does: <lib>/lib/perl5/<arch>/.meta/<dist>/install.json
sub receipt {
  my ( $lib, $arch, $dist, $json ) = @_;
  my $dir = File::Spec->catdir( $lib, 'lib', 'perl5', $arch, '.meta', $dist );
  mkpath $dir;
  my $file = File::Spec->catfile( $dir, 'install.json' );
  open my $fh, '>', $file or die "open $file: $!";
  print {$fh} $json;
  close $fh;
}

my $lib = tempdir( 'mist-fdt-lib-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

receipt( $lib, 'x86_64-linux', 'Foo-Bar-2.0',
  '{"name":"Foo::Bar","target":"Foo::Bar","version":"2.0"}' );
receipt( $lib, 'x86_64-linux', 'Baz-Qux-1.5',
  '{"name":"Baz::Qux","target":"Baz::Qux","version":"1.5"}' );

# name absent -> falls back to target
receipt( $lib, 'x86_64-linux', 'Only-Target-3.0',
  '{"target":"Only::Target","version":"3.0"}' );

# no version -> skipped (cannot floor on nothing)
receipt( $lib, 'x86_64-linux', 'No-Version-0',
  '{"name":"No::Version"}' );

my %floor = floors( $lib );

is_deeply \%floor,
  {
    'Foo::Bar'    => '2.0',
    'Baz::Qux'    => '1.5',
    'Only::Target'=> '3.0',
  },
  'one floor per dist keyed by main module; target fallback; version-less skipped';

# Each floor renders to a whitespace-free, cat-able spec.
for my $module ( sort keys %floor ) {
  my $spec = Mist::Bundle->spec_for( $module, $floor{ $module } );
  unlike $spec, qr/\s/, "floor spec for $module is a single token";
}

EMPTY_LIB_YIELDS_NO_FLOORS: {
  my $empty = tempdir( 'mist-fdt-empty-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  is_deeply { floors( $empty ) }, {}, 'a lib with no receipts yields no floors';
}

done_testing;
