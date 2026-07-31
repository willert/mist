#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use Cwd ();
use File::Path qw/ mkpath /;
use File::Spec;
use File::Temp ();

# The doctor checks that inspect the project layout rather than perl's core set.
# Each fires on a specific, measured failure condition; the point of the tests is
# that they stay silent on a healthy project, since a check that cries wolf is
# worse than no check.
eval { require App::Mist::Command::doctor; 1 }
  or plan skip_all => "cannot load App::Mist::Command::doctor: $@";

my $cwd = Cwd::getcwd();          # Context::BUILD chdirs into project_root
END { chdir $cwd if defined $cwd }

sub project {
  my ( %file ) = @_;
  my $tmp = File::Temp->newdir( CLEANUP => 1 );
  my $root = "$tmp";
  for my $rel ( sort keys %file ) {
    my $path = File::Spec->catfile( $root, split m{/}, $rel );
    mkpath( ( File::Spec->splitpath( $path ) )[1] );
    open my $fh, '>', $path or die "$path: $!";
    print $fh $file{ $rel };
    close $fh;
  }
  my $ctx = App::Mist::Context->new({
    project_root => Path::Class::dir( $root ),
  });
  chdir $cwd;
  return ( $ctx, $root, $tmp );   # $tmp held so CLEANUP does not fire early
}

sub report_from {
  my ( $code, $ctx ) = @_;
  my $out = '';
  open my $saved, '>&STDOUT' or die $!;
  close STDOUT;
  open STDOUT, '>', \$out or die $!;
  my $fired = $code->( $ctx );
  close STDOUT;
  open STDOUT, '>&', $saved or die $!;
  return ( $fired, $out );
}

STALE_BIN_LAYOUT: {
  my $check = \&App::Mist::Command::doctor::_report_stale_bin_layout;

  # A plain file where the selector symlink belongs: the pre-per-perl layout.
  my ( $ctx, $root, $keep ) = project(
    'cpanfile'           => "requires 'strict';\n",
    'perl5/bin/mist-run' => "#!/bin/bash\n",
  );
  my ( $fired, $out ) = report_from( $check, $ctx );
  ok $fired, 'a plain mist-run is reported';
  like $out, qr/not a selector symlink/, '...saying what is wrong';
  like $out, qr/mpan-install/, '...and what regenerates it';

  # The healthy shape.
  my ( $ctx2, $root2, $keep2 ) = project( 'cpanfile' => "requires 'strict';\n" );
  mkpath( File::Spec->catdir( $root2, 'perl5', 'bin' ) );
  chdir $cwd;
  symlink 'mist-run-perl-5.20.3-x86_64-linux',
    File::Spec->catfile( $root2, 'perl5', 'bin', 'mist-run' )
    or plan skip_all => 'cannot create symlinks here';
  my ( $fired2, $out2 ) = report_from( $check, $ctx2 );
  ok !$fired2, 'a selector symlink is silent';
  is $out2, q{}, '...saying nothing at all';

  # No environment built yet is not a complaint.
  my ( $ctx3, $root3, $keep3 ) = project( 'cpanfile' => "requires 'strict';\n" );
  my ( $fired3 ) = report_from( $check, $ctx3 );
  ok !$fired3, 'a project with no perl5/ yet is silent';
}

UNSET_MODULE_MAKER: {
  my $check = \&App::Mist::Command::doctor::_report_unset_module_maker;

  # Both halves true: no maker chosen, and bin/ present for MBT to refuse.
  my ( $ctx, $root, $keep ) = project(
    'cpanfile'      => "requires 'strict';\n",
    'minil.toml'    => qq{name = "Some-Dist"\n},
    'bin/something' => "#!/usr/bin/env perl\n",
  );
  my ( $fired, $out ) = report_from( $check, $ctx );
  ok $fired, 'unset maker plus bin/ is reported';
  like $out, qr/ModuleBuildTiny/,       '...naming the default it falls back to';
  like $out, qr/ExtUtilsMakeMaker/,     '...and the fix';
  # Matched on a single word: the surrounding prose is hard-wrapped, so any
  # phrase long enough to be meaningful is also long enough to straddle a break.
  like $out, qr/mid-release/, '...and when it would bite';

  # Unset, but nothing for MBT to refuse - not a problem.
  my ( $ctx2, undef, $keep2 ) = project(
    'cpanfile'         => "requires 'strict';\n",
    'minil.toml'       => qq{name = "Some-Dist"\n},
    'script/something' => "#!/usr/bin/env perl\n",
  );
  my ( $fired2 ) = report_from( $check, $ctx2 );
  ok !$fired2, 'script/-only projects are silent - MBT installs those';

  # Set explicitly: nothing to say whatever the layout.
  my ( $ctx3, undef, $keep3 ) = project(
    'cpanfile'      => "requires 'strict';\n",
    'minil.toml'    => qq{name = "D"\nmodule_maker = "ExtUtilsMakeMaker"\n},
    'bin/something' => "#!/usr/bin/env perl\n",
  );
  my ( $fired3 ) = report_from( $check, $ctx3 );
  ok !$fired3, 'an explicit maker is silent';

  # Not a Minilla dist at all.
  my ( $ctx4, undef, $keep4 ) = project(
    'cpanfile'      => "requires 'strict';\n",
    'bin/something' => "#!/usr/bin/env perl\n",
  );
  my ( $fired4 ) = report_from( $check, $ctx4 );
  ok !$fired4, 'a project with no minil.toml is silent';
}

UNSATISFIABLE_DECLARATIONS: {
  my $check = \&App::Mist::Command::doctor::_report_unsatisfiable_declarations;

  # A stray space makes the name match nothing, however well stocked the mirror
  # is - and it masquerades as a missing distribution, so it is reported first
  # and on its own terms. This is a real cpanfile in the estate.
  my ( $ctx, undef, $keep ) = project(
    'cpanfile' => "requires 'String::Truncate ';\n",
  );
  my ( $fired, $out ) = report_from( $check, $ctx );
  ok $fired, 'a module name with stray whitespace is reported';
  like $out, qr/stray whitespace/, '...naming the actual fault';
  like $out, qr/String::Truncate /, '...quoting the entry verbatim';
  unlike $out, qr/neither indexed/,
    '...and not as a missing distribution, which is what it looks like';

  # Core modules are not indexed and must not be reported as absent.
  my ( $ctx2, undef, $keep2 ) = project(
    'cpanfile' => "requires 'strict';\nrequires 'Carp';\n",
  );
  my ( $fired2, $out2 ) = report_from( $check, $ctx2 );
  ok !$fired2, 'core modules are not reported as unvendored';
  is $out2, q{}, '...silently';

  # A non-core module with no mirror at all cannot be satisfied.
  my ( $ctx3, undef, $keep3 ) = project(
    'cpanfile' => "requires 'Some::Thing::Not::Core';\n",
  );
  my ( $fired3, $out3 ) = report_from( $check, $ctx3 );
  ok $fired3, 'a non-core module the mirror does not carry is reported';
  like $out3, qr/neither indexed by this mirror nor core/, '...as unsatisfiable';
}

KNOWN_BAD_VERSIONS_TABLE: {
  # The blacklist is data, so the table itself is what is worth asserting: each
  # entry has to carry enough to act on without looking anything up.
  my @bad = @App::Mist::Command::doctor::KNOWN_BAD;
  ok scalar @bad, 'the known-bad table has entries';

  for my $entry ( @bad ) {
    my $m = $entry->{module} // '<unnamed>';
    ok length( $entry->{module} // '' ), "$m: names a module";
    ok length( $entry->{below}  // '' ), "$m: names the version it is fixed in";
    ok length( $entry->{what}   // '' ), "$m: says what is wrong";
    ok length( $entry->{why}    // '' ), "$m: explains why it bites";
    like $entry->{fix} // '', qr/\bmist\b/, "$m: gives a runnable fix";
  }

  my ( $term ) = grep { $_->{module} eq 'Term::Table' } @bad;
  ok $term, 'Term::Table is covered';
  is $term->{below}, '0.019',
    '...fixed in 0.019, where the Test-Simple use cycle was resolved';
  ok !$term->{above_perl}, '...and its cycle is unconditional, so it is ungated';

  my ( $cpants ) = grep { $_->{module} eq 'Module::CPANTS::Analyse' } @bad;
  ok $cpants, 'Module::CPANTS::Analyse is covered';
  is $cpants->{below}, '1.03', '...fixed in 1.03, which carries the test patch';
  is $cpants->{above_perl}, '5.20.3',
    '...and gated on the perl, since Archive::Tar only refuses it above 5.20.3';
}

ABOVE_PERL_DESCRIBES_RATHER_THAN_FILTERS: {
  # A conditional entry is reported whichever perl is asked about - "this will
  # cause problems later" is worth knowing while working on the project, not only
  # once someone sits down to evaluate a newer perl. The condition is stated in
  # the report instead of deciding whether there is one.
  my $check = \&App::Mist::Command::doctor::_report_known_bad_versions;

  local @App::Mist::Command::doctor::KNOWN_BAD = ( {
    module     => 'Some::Dist',
    below      => '2.0',
    above_perl => '5.20.3',
    what       => 'explodes',
    why        => "  because it does\n",
    fix        => 'mist inject Some::Dist~2.0',
  } );

  no warnings 'redefine';
  local *App::Mist::Command::doctor::_indexed_versions = sub { { 'Some::Dist' => '1.0' } };

  my ( $under, $out_under ) = report_from( sub { $check->( $_[0], '5.20.3' ) }, undef );
  ok $under, 'reported even when the perl asked about is below the threshold';
  like $out_under, qr/not under the 5\.20\.3/, '...saying it does not bite there yet';

  my ( $over, $out_over ) = report_from( sub { $check->( $_[0], '5.38.2' ) }, undef );
  ok $over, 'and reported when it is above';
  like $out_over, qr/including the 5\.38\.2/, '...saying it bites there';
}

PERL_VERSIONS_COMPARE_NUMERICALLY: {
  # The gate is evaluated against the perl being asked about, so the comparison
  # has to order 5.38.2 above 5.20.3 - which string comparison does not.
  my $num = \&App::Mist::Command::doctor::_numeric_perl;

  is $num->('5.38.2'),   '5.038002', 'dotted becomes the CoreList shape';
  is $num->('5.38'),     '5.038000', '...with a missing patch level as zero';
  is $num->('5.020003'), '5.020003', '...and an already-numeric spec passes through';
  ok $num->('5.38.2') > $num->('5.20.3'),
    '5.38.2 orders above 5.20.3, which it does not as a string';
  ok $num->('5.8.9') < $num->('5.20.3'), 'and 5.8.9 below 5.20.3, likewise';
  is $num->('nonsense'), undef, 'an unparseable spec yields undef, not a guess';
}

done_testing;
