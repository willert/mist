#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin ();
use File::Spec;

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
my $perlbrew_pm = File::Spec->catfile(
  $repo, qw/ lib Mist Script perlbrew.pm / );

# Stop the perlbrew re-exec from replacing this test process; record that it
# was reached and unwind back to us instead. CORE::GLOBAL overrides only affect
# code compiled afterwards, so this must run before perlbrew.pm is required.
my $exec_reached;
BEGIN { *CORE::GLOBAL::exec = sub { $exec_reached = 1; die "EXEC_REACHED\n" } }

# The re-exec branch fires only for a requested perl that differs from the
# running one and with MIST_PERLBREW_VERSION unset. Pin a fake target.
local $ENV{PERLBREW_ROOT} = '/nonexistent/perlbrew';
local $ENV{PERLBREW_PERL} = 'perl-0.0.0';
delete local $ENV{MIST_PERLBREW_VERSION};

# perlbrew.pm parses @ARGV for --perlbrew at load time, so set it before require.
{
  local @ARGV = ( '--perlbrew=perl-5.99.9' );
  require $perlbrew_pm;
}

# get_archname() shells out to perlbrew; we never reach a real perl, so stub it.
{
  no warnings qw/ redefine once /;
  *Mist::Script::perl::get_archname = sub { 'x86_64-linux' };
}

SEVERS_NON_TTY_STDIN: {
  # A pipe with unread data standing in for an inherited never-EOF STDIN. If the
  # sever fires, fd 0 becomes /dev/null and this data is unreachable.
  pipe( my $rd, my $wr ) or die "pipe: $!";
  print {$wr} "PENDING-INPUT\n";
  close $wr;
  open( STDIN, '<&', $rd ) or die "dup onto STDIN: $!";
  ok( !-t STDIN, 'test STDIN is a non-tty (pipe)' );

  my $err;
  {
    # Swallow the "Restarting ..." banner so it doesn't corrupt TAP.
    local *STDOUT;
    open STDOUT, '>', File::Spec->devnull or die;
    eval { Mist::Script::perl::ensure_runtime_is_correct_perl_version() };
    $err = $@;
  }

  is( $err, "EXEC_REACHED\n", 'reached the perlbrew re-exec' );
  ok( $exec_reached, 'exec() was invoked for the re-exec' );

  my $n = sysread( STDIN, my $buf, 64 );
  is( $n, 0,
    'non-tty STDIN is severed before the re-exec (read hits immediate EOF)' );
}

ARTIFACT_CARRIES_THE_FIX: {
  my $installer = File::Spec->catfile( $repo, 'mpan-install' );
  SKIP: {
    skip 'no mpan-install present', 1 unless -r $installer;
    my $src = do {
      open my $fh, '<', $installer or die "open mpan-install: $!";
      local $/; <$fh>;
    };
    like( $src, qr/open STDIN, '<', File::Spec->devnull unless -t STDIN/,
      'committed mpan-install severs non-tty STDIN at the perlbrew re-exec' );
  }
}

done_testing;
