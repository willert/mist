#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use Cwd ();
use File::Spec;
use File::Temp ();
use FindBin ();

# An unpinned project - no `perl '<version>'` in the mistfile - is deprecated.
# It is the one configuration that silently reinterprets an environment: the
# build follows whatever perl is on PATH, and guard_against_implicit_switch
# short-circuits when no perl is managed, so a later run from a different shell
# re-activates onto that perl without asking. Being unmanaged is fine; falling
# into it by omission is what is being retired.
#
# Both halves warn, and both are checked: the build-master (where you would fix
# the mistfile) and the host installer (where the unguarded repoint happens, and
# which may be vendored long after the mistfile was last edited).

eval { require App::Mist::Context; 1 }
  or plan skip_all => "cannot load App::Mist::Context: $@";

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
require File::Spec->catfile( $repo, qw/ lib Mist Script perlbrew.pm / );

my $cwd = Cwd::getcwd();          # Context::BUILD chdirs into project_root
END { chdir $cwd if defined $cwd }

sub perl_version_for {
  my ( $mistfile ) = @_;
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  for ( [ cpanfile => "requires 'strict';\n" ], [ mistfile => $mistfile ] ) {
    my ( $name, $body ) = @$_;
    open my $fh, '>', File::Spec->catfile( "$tmp", $name ) or die $!;
    print $fh $body;
    close $fh;
  }
  my $ctx = App::Mist::Context->new({
    project_root => Path::Class::dir( "$tmp" ),
  });

  my @warnings;
  my $version = do {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $ctx->perl_version;
  };
  chdir $cwd;
  return ( $version, join q{}, @warnings );
}

BUILD_MASTER_WARNS_ONCE_WHEN_UNPINNED: {
  my ( $version, $warned ) = perl_version_for( "# nothing pinned here\n" );

  is $version, '', 'an unpinned project still resolves to no managed perl';
  like $warned, qr/pins no perl version/,
    '...but says so, rather than passing silently';
  like $warned, qr/deprecated/,
    '...naming it as deprecated rather than merely unusual';
  like $warned, qr/--system-perl/,
    '...and pointing at the supported way to be deliberately unmanaged';
}

A_PINNED_PROJECT_IS_SILENT: {
  my ( $version, $warned ) = perl_version_for( "perl '5.20.3';\n" );

  is $version, 'perl-5.20.3', 'a pinned project resolves to its version';
  is $warned, q{},
    '...and warns about nothing - the deprecation is silent where it does not apply';
}

HOST_INSTALLER_WARNS_TOO: {
  # The installer carries its own copy of the message: it is vendored, so it
  # outlives the mistfile edit that would fix the project, and it is where the
  # selector actually gets repointed.
  my $warning = Mist::Script::perl::_unpinned_warning();

  like $warning, qr/mpan-install/,
    'the host warning names the installer, not the build-master command';
  like $warning, qr/--system-perl/, '...offers the guarded alternative';
  like $warning, qr/deprecated/,    '...and says it is deprecated';
}

done_testing;
