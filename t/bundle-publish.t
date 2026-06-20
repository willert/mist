#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use File::Temp qw/ tempdir /;
use Path::Class qw/ dir /;

# `mist bundle publish` promotes an ephemeral workspace bundle into the committed
# mpan-dist mirror under a chosen name, attaching metadata. _publish is the verb
# body; it takes only ctx/opt/args, so a duck-typed ctx + opt exercise it without
# building a real Context. Run under ./mist-run prove (loads App::Mist).
eval { require App::Mist::Command::bundle; require Mist::Bundle; 1 }
  or plan skip_all => "cannot load bundle command: $@";

{
  package FakeOpt;
  sub new { my ( $class, %a ) = @_; bless { %a }, $class }
  sub as          { $_[0]->{as} }
  sub description { $_[0]->{description} }

  package FakeCtx;
  sub new { my ( $class, %a ) = @_; bless { %a }, $class }
  sub workspace { $_[0]->{workspace} }
  sub mpan_dist { $_[0]->{mpan_dist} }
}

sub publish { App::Mist::Command::bundle::_publish( 'App::Mist::Command::bundle', @_ ) }

my $root = dir( tempdir( 'mist-publish-XXXXXX', TMPDIR => 1, CLEANUP => 1 ) );
my $ctx  = FakeCtx->new(
  workspace => $root->subdir( 'workspace' ),
  mpan_dist => $root->subdir( 'mpan-dist' ),
);

my $uuid  = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
my @specs = qw/ HTTP::Tiny~0.090 Net::SSLeay~1.94 /;
Mist::Bundle->new({ specs => \@specs })
  ->save( $ctx->workspace->subdir( 'bundles' ), $uuid );

PUBLISH_COPIES_SPECS_AND_ATTACHES_META: {
  publish( $ctx,
    FakeOpt->new( as => 'cve-2026-1234', description => 'bump HTTP stack' ),
    [ $uuid ] );

  my $bundles = $ctx->mpan_dist->subdir( 'bundles' );
  ok -e $bundles->file( 'cve-2026-1234.bundle' ), 'published .bundle lands in mpan-dist';
  ok -e $bundles->file( 'cve-2026-1234.meta' ),   'published .meta lands in mpan-dist';

  my $got = Mist::Bundle->load( $bundles, 'cve-2026-1234' );
  is_deeply $got->specs, \@specs, 'specs copied verbatim from the ephemeral bundle';
  is $got->meta->{name},        'cve-2026-1234',   'name recorded';
  is $got->meta->{description}, 'bump HTTP stack', 'description recorded';
  like $got->meta->{published}, qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/,
    'publish timestamp recorded in ISO-8601 UTC';
}

PUBLISH_WITHOUT_DESCRIPTION_OMITS_IT: {
  publish( $ctx, FakeOpt->new( as => 'no-desc' ), [ $uuid ] );
  my $got = Mist::Bundle->load( $ctx->mpan_dist->subdir( 'bundles' ), 'no-desc' );
  ok !exists $got->meta->{description}, 'no description key when --description is absent';
}

PUBLISH_VALIDATES_INPUTS: {
  ok !eval { publish( $ctx, FakeOpt->new(), [ $uuid ] ); 1 },
    'missing --as is rejected';
  ok !eval { publish( $ctx, FakeOpt->new( as => '../escape' ), [ $uuid ] ); 1 },
    'a traversal name is rejected';
  ok !eval { publish( $ctx, FakeOpt->new( as => 'fine' ), [ 'no-such-uuid' ] ); 1 },
    'a missing ephemeral bundle is rejected';
}

done_testing;
