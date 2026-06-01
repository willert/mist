use strict;
use warnings;

# Integration guard for `mist release`'s contained-lib dist-test
# (App::Mist::Command::release). It proves two properties of a release:
#
#   1. no pollution - the released dist's deps install into a throwaway
#      contained lib, never into mist's own perl5; and
#   2. hermetic test - the dist-test resolves only the dist's *declared*
#      closure, so an undeclared dependency fails the release.
#
# It exercises the real release helpers (_cleanroom_inc /
# _install_prereqs_contained) plus Minilla's dist_test, mirroring the
# orchestration in release.pm's execute(). It is heavier than a unit test
# (it shells cpanm against the mpan-dist mirror), so it self-skips when the
# environment cannot support it.

use Test::More;
use FindBin ();
use File::Spec;
use Config;

BEGIN {
  # Don't run a release-shaped integration test from inside an actual release
  # clean-room (mist's own `mist release` sets RELEASE_TESTING and would pull
  # this in recursively).
  plan skip_all => 'skipped under RELEASE_TESTING' if $ENV{RELEASE_TESTING};
}

my $repo = File::Spec->rel2abs(
  File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
my $mirror_dir = File::Spec->catdir( $repo, 'mpan-dist' );
plan skip_all => "no mpan-dist mirror at $mirror_dir" unless -d $mirror_dir;

chomp( my $cpanm = `which cpanm` );
plan skip_all => 'cpanm not found' unless $cpanm && -x $cpanm;

# Needs the project perl env: Minilla, the release helpers, and the modules
# used below. require (not use) so an unsupported env skips instead of dies.
eval {
  require Minilla::Project;
  require App::Mist::Command::release;
  require File::Temp;
  require File::Path;
  File::Temp->import('tempdir');
  File::Path->import('make_path');
  1;
} or plan skip_all => "project perl env unavailable: $@";

my $mirror = "file://$mirror_dir";
my $dep    = 'Capture::Tiny';          # vendored in mpan-dist, not in core
my $dep_pm = 'Capture/Tiny.pm';

# The env the mist CLI runs under - a release must never write here.
my $ambient = File::Spec->catdir(
  $repo, 'perl5', "perl-$Config{version}-$Config{archname}", qw/ lib perl5 / );

sub count_files {
  my $d = shift;
  return 0 unless -d $d;
  my ( $n, @stack ) = ( 0, $d );
  while ( @stack ) {
    my $dir = pop @stack;
    opendir my $dh, $dir or next;
    for ( readdir $dh ) {
      next if $_ eq '.' || $_ eq '..';
      my $p = File::Spec->catfile( $dir, $_ );
      -d $p ? push( @stack, $p ) : -f $p ? $n++ : ();
    }
  }
  return $n;
}

sub spew { my ( $f, $c ) = @_; open my $fh, '>', $f or die "$f: $!"; print $fh $c; close $fh }

# Build a minimal Minilla dist whose only test does `use $dep`, declaring
# $dep in the cpanfile iff $declared. Returns ($disttest_failed, $cleanroom).
sub run_case {
  my $declared = shift;

  my $cwd  = File::Spec->rel2abs('.');
  my $dist = tempdir( CLEANUP => 1 );
  chdir $dist or die "chdir $dist: $!";

  make_path( 'lib/My', 't' );
  spew( 'lib/My/Dist.pm',
      "package My::Dist;\n# ABSTRACT: cleanroom test dist\n"
    . "our \$VERSION = '0.01';\n1;\n__END__\n\n=head1 NAME\n\nMy::Dist - x\n\n"
    . "=head1 AUTHOR\n\nT <t\@example.com>\n\n=head1 LICENSE\n\nperl_5\n\n=cut\n" );
  spew( 'cpanfile', $declared ? "requires '$dep';\n" : "# nothing declared\n" );
  spew( 't/00.t', "use Test::More;\nuse $dep;\nok 1;\ndone_testing;\n" );
  spew( 'Changes', "Revision history\n\n{{\$NEXT}}\n    - initial\n" );
  spew( 'minil.toml',
    "name = \"My-Dist\"\nauthors = [\"T <t\@example.com>\"]\nlicense = \"perl_5\"\n" );

  system( qw/git init -q/ ) == 0 or die 'git init';
  system( qw/git add -A/ )  == 0 or die 'git add';
  system( 'git', '-c', 'user.email=t@example.com', '-c', 'user.name=t',
          'commit', '-qm', 'init' ) == 0 or die 'git commit';

  $Minilla::AUTO_INSTALL = 1;
  my $project = Minilla::Project->new;
  my $work    = $project->work_dir;

  my $cleanroom = tempdir( CLEANUP => 1 );
  my @inc       = App::Mist::Command::release::_cleanroom_inc( $cleanroom );
  {
    no warnings 'redefine', 'once';
    *Minilla::Project::verify_prereqs = sub {
      return unless $Minilla::AUTO_INSTALL;
      App::Mist::Command::release::_install_prereqs_contained(
        $cpanm, $mirror, $cleanroom );
    };
  }
  local $ENV{MINILLA_DISABLE_WRITE_RELEASE_TEST} = 1;
  local $ENV{PERL5LIB} = join $Config{path_sep}, @inc;

  # Run the dist-test, but keep its inner TAP-harness summary (printed to our
  # STDOUT) out of this test's own TAP stream. Save/redirect/restore at the fd
  # level so child procs are covered and STDOUT is reliably restored.
  open( my $save_out, '>&', \*STDOUT ) or die "save STDOUT: $!";
  open( my $save_err, '>&', \*STDERR ) or die "save STDERR: $!";
  open( STDOUT, '>', File::Spec->devnull ) or die;
  open( STDERR, '>', File::Spec->devnull ) or die;
  my $failed = eval { $work->dist_test };
  my $err    = $@;
  open( STDOUT, '>&', $save_out ) or die "restore STDOUT: $!";
  open( STDERR, '>&', $save_err ) or die "restore STDERR: $!";
  diag( "dist_test died: $err" ) if $err;

  chdir $cwd;
  return ( $failed, $cleanroom );
}

my $before = count_files( $ambient );

my ( $decl_fail, $decl_cr ) = run_case( 1 );
is( $decl_fail, 0, 'declared dep: dist-test passes' );
ok( -e File::Spec->catfile( $decl_cr, qw/ lib perl5 /, $dep_pm ),
    "declared dep installed into the contained lib, not mist's perl5" );

my ( $undecl_fail, $undecl_cr ) = run_case( 0 );
ok( $undecl_fail, 'undeclared dep: dist-test fails (hermetic)' );
ok( !-e File::Spec->catfile( $undecl_cr, qw/ lib perl5 /, $dep_pm ),
    'undeclared dep absent from the contained lib' );

my $after = count_files( $ambient );
is( $after, $before, "mist's perl5 untouched by the release dist-test" );

done_testing;
