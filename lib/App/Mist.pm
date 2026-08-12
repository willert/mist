package App::Mist;
# ABSTRACT: MPAN distribution manager
use 5.010;
use FindBin qw/$RealBin/;
use File::Spec;
use Config;
use Cwd qw/realpath/;

BEGIN {
  my $basedir = realpath( File::Spec->catdir( $RealBin => '..' ));
  if ( not eval "require local::lib" ) {
    my $extlib = File::Spec->catdir( $basedir => qw/ extlib / );
    if ( -d $extlib ) {
      $extlib = realpath( $extlib );
      print STDERR "Using local::lib from extlib $extlib\n";
      push @INC, $extlib;
      require local::lib;
    } else {
      die "Please install local::lib in the current environment\n";
    }
  }

  my $version_dir = join( q{-}, 'perl', $Config{version}, $Config{archname} );
  my $mist_lib    = File::Spec->catdir( $basedir => 'perl5', $version_dir );

  if ( not -d $mist_lib and not $ENV{MIST_REBUILD_IN_PROGRESS} ) {
    die <<"ERROR_MSG";
Mist is not yet installed for perl $Config{version}-$Config{archname}.
Please run:
  cd $basedir; ./mpan-install --perlbrew=$Config{version}
ERROR_MSG
  }

  require local::lib;
  local::lib->import( $mist_lib );

  # local::lib->import prepends the vendored perl5 paths, which can shadow
  # mist's own lib/ - and with it the Minilla::CLI::Release override that
  # swaps BumpVersionSmart and TagPublish into the release pipeline. Whether
  # that shadowing happens depends on how the process was reached (a perlbrew
  # re-exec reorders PERL5LIB), so re-assert our own code ahead of the
  # vendored dependencies unconditionally.
  my $own_lib = File::Spec->catdir( $basedir => 'lib' );
  unshift @INC, $own_lib if -d $own_lib;
}

# BEGIN {
#   if ( my $root = $ENV{MIST_APP_ROOT} and not local::lib->active_paths ) {
#     my $arch_path = join( q{-}, 'perl', $Config{version}, $Config{archname} );
#     my $lib_path = File::Spec->catdir( $root, 'perl5', $arch_path );
#     printf STDERR "Re-initializing local lib path %s\n", $lib_path;
#     local::lib->import( $lib_path );
#   }
# }

use App::Cmd::Setup -app;

our $VERSION = '0.56';

use App::Mist::Context;

# Set only by the argv parse below, and deliberately not readable from the
# environment: this is an emergency escape, and an env var would let one export
# turn every later invocation into one silently. It has to be typed each time.
our $FORCE_SYSTEM_PERL = 0;

sub ctx {
  my $self = shift;
  $self->{ctx} //= App::Mist::Context->new;
}

# git-style global "-C <path>": run as if mist had been started in <path>.
# Applied before App::Cmd dispatches, so the project root (found by walking up
# from cwd) and everything downstream resolve from there. The options are
# stripped from @ARGV so the perlbrew re-exec in App::Mist::Context does not
# re-apply a relative path on top of the already-changed cwd.
sub run {
  my $class = shift;

  # Leading global options only, in any order. Restricted to the front rather
  # than swept from the whole argv because `mist run -- <cmd> <args>` passes
  # everything after the separator through untouched, and a global option
  # stripped out of a wrapped command's arguments would be a silent corruption.
  while ( @ARGV ) {
    if ( $ARGV[0] eq '--force-system-perl' ) {
      shift @ARGV;
      $FORCE_SYSTEM_PERL = 1;
      next;
    }

    my @paths = $class->_shift_chdir_paths( \@ARGV );
    last unless @paths;

    for my $path ( @paths ) {
      next unless length $path;        # -C "" leaves the cwd unchanged, like git
      chdir $path or die "mist: cannot chdir to '$path': $!\n";
    }
  }

  return $class->SUPER::run( @_ );
}

# Pull leading -C options off the front of an argv arrayref and return their
# paths in order. Accepts "-C <path>", "-C=<path>" and "-C<path>". Applying the
# paths with successive chdir gives git's rule that a non-absolute -C is taken
# relative to the preceding one for free.
sub _shift_chdir_paths {
  my ( $class, $argv ) = @_;
  my @paths;
  while ( @$argv and $argv->[0] =~ /\A-C(=?.*)\z/s ) {
    if ( length $1 ) {                 # -C<path> or -C=<path>
      ( my $path = $1 ) =~ s/\A=//;
      shift @$argv;
      push @paths, $path;
    } else {                           # -C <path>
      shift @$argv;
      die "mist: option -C requires a path argument\n" unless @$argv;
      push @paths, shift @$argv;
    }
  }
  return @paths;
}

1;

__END__

=head1 GLOBAL OPTIONS

=head2 -C <path>

Run as if C<mist> had been started in C<< <path> >> instead of the current
directory. It is parsed before the subcommand, so the project root (located by
walking up for F<mistfile> / F<cpanfile>) and everything derived from it
resolve from C<< <path> >>.

May be given more than once; as with C<git -C>, a non-absolute C<< <path> >> is
taken relative to the preceding one, and an empty C<< -C '' >> leaves the
directory unchanged. The forms C<-C path>, C<-C=path> and C<-Cpath> are all
accepted.

=head2 --force-system-perl

Run the subcommand under the perl on C<PATH> instead of re-executing under the
perl the mistfile pins. For a host that cannot provide a perlbrew context and
needs one command to go through anyway.

This is an escape, not a mode. C<./mpan-install --system-perl> is the supported
way for a machine to build against its own perl, and it records that choice;
this flag records nothing, must be typed on every invocation, cannot be set
from the environment, and warns each time it is used.

It is refused for C<compile>, C<build_dist>, C<release> and C<prerelease>.
Those emit artifacts that other checkouts and other people consume, and nothing
in the result records which perl resolved it - so an unpinned one is a mistake
that is invisible afterwards and reaches every consumer.

Contradictory with C<--perlbrew>, which names an interpreter to use.

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=head1 LICENSE

Copyright (C) 2013 Sebastian Willert.

This library is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
