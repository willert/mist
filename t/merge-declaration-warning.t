#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use Capture::Tiny qw/ capture /;
use File::Spec;
use File::Temp ();
use Path::Class ();

# A merged distribution the cpanfile does not name is vendored and then never
# installed: cpanm re-resolves a module it is *named*, but one reached
# transitively is measured against its parent's declared floor and never
# compared against the index. The merge appears to work and changes nothing.
#
# The check reads the modules the built distribution provides rather than the
# merge block's name. That matters: block names are labels, and measured across
# the estate, matching on them reported 14 of 94 merged dists - six of those
# only because a label's casing differed from its module's (bofrost carries
# `wecare::env::dbic` while declaring `WeCARE::Env::DBIC` correctly). Reading
# provided modules takes it to 5.

eval { require App::Mist::Command::merge; 1 }
  or plan skip_all => "cannot load App::Mist::Command::merge: $@";

my $check = \&App::Mist::Command::merge::_warn_unless_declared;

{
  package FakeCtx;
  sub new { my ( $class, $dir ) = @_; bless { dir => $dir }, $class }
  sub project_root { $_[0]{dir} }

  package FakeDist;
  sub new { my ( $class, @m ) = @_; bless { m => { map { $_ => '1.00' } @m } }, $class }
  sub modules { $_[0]{m} }
  sub as_module_name { ( sort keys %{ $_[0]{m} } )[0] }
}

sub with_cpanfile {
  my ( $content ) = @_;
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  if ( defined $content ) {
    open my $fh, '>', File::Spec->catfile( "$tmp", 'cpanfile' ) or die $!;
    print $fh $content;
    close $fh;
  }
  return ( FakeCtx->new( Path::Class::dir( "$tmp" ) ), $tmp );
}

sub warning_from {
  my ( $ctx, $dist ) = @_;
  my ( $out, $err ) = capture { $check->( $ctx, $dist ) };
  return $out . $err;
}

DECLARED_DIRECTLY: {
  my ( $ctx, $keep ) = with_cpanfile( "requires 'WeCARE::Env::DBIC';\n" );
  my $msg = warning_from( $ctx, FakeDist->new('WeCARE::Env::DBIC') );
  is $msg, q{}, 'a declared distribution is silent';
}

ANY_PROVIDED_MODULE_COUNTS: {
  # cpanm resolves module -> distribution and installs the whole thing, so
  # naming a submodule is as good as naming the main one.
  my ( $ctx, $keep ) = with_cpanfile( "requires 'WeCARE::Test::Mocked';\n" );
  my $msg = warning_from( $ctx,
    FakeDist->new( 'WeCARE::Test', 'WeCARE::Test::Mocked', 'WeCARE::Test::Util' ) );
  is $msg, q{}, 'naming any one provided module is enough';
}

DECLARED_IN_ANOTHER_PHASE: {
  # A test-phase declaration is still a declaration.
  my ( $ctx, $keep ) = with_cpanfile(
    "on test => sub {\n  requires 'WeCARE::Test::Mocked';\n};\n" );
  my $msg = warning_from( $ctx, FakeDist->new('WeCARE::Test::Mocked') );
  is $msg, q{}, 'a test-phase requirement counts as named';
}

UNDECLARED: {
  my ( $ctx, $keep ) = with_cpanfile( "requires 'Something::Else';\n" );
  my $msg = warning_from( $ctx,
    FakeDist->new( 'Time::Naive', 'Time::Naive::Duration' ) );

  like $msg, qr/nothing in cpanfile names Time::Naive/,
    'an undeclared distribution is reported, by name';
  like $msg, qr/will not install it/, '...saying what the consequence is';
  like $msg, qr/bare `requires`/,     '...and asking for a bare line, not a pin';

  # A note, not a report. The doctor is where verbosity belongs; this fires in
  # the middle of a merge someone is watching for other reasons.
  cmp_ok scalar( () = $msg =~ /\n/g ), '<=', 2,
    '...in at most two lines';
}

NOTHING_TO_JUDGE: {
  my ( $ctx, $keep ) = with_cpanfile( undef );
  is warning_from( $ctx, FakeDist->new('Time::Naive') ), q{},
    'a project with no cpanfile is silent';

  my ( $ctx2, $keep2 ) = with_cpanfile( "requires 'Something::Else';\n" );
  is warning_from( $ctx2, FakeDist->new() ), q{},
    'a distribution that provides nothing is silent';
}

done_testing;
