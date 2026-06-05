package App::Mist::Command::run;
# ABSTRACT: run a command in this projects environment

use 5.010;

use App::Mist -command;

sub usage_desc { '%c run %o <command>...' }

sub opt_spec {
  return (
    [ 'perlbrew=s' => 'run under this perl (e.g. 5.42.2) instead of the project default' ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $ctx = $self->app->ctx;

  return $self->run_under_perlbrew( $ctx, $opt->perlbrew, $args )
    if defined $opt->perlbrew;

  my $runner = $ctx->project_root->file(qw/ perl5 bin mist-run /);
  die "No initialized Mist environment found" unless -x "$runner";

  $ctx->ensure_correct_perlbrew_context;

  $ENV{ $_ } = undef for grep{ /PERL|MIST/ } keys %ENV;

  my @cmd = ( bash => '-l', $runner, @$args );
  exec @cmd;
}

# The generated perl5/bin/mist-run wrapper is pinned to whichever perl last ran
# mpan-install, so it can't honour --perlbrew. Set up the requested perl's
# environment in-process and exec the command directly instead.
sub run_under_perlbrew {
  my ( $self, $ctx, $version, $args ) = @_;

  # The default path hands the command to `bash`, whose `exec` builtin drops a
  # leading `--`; we exec directly, so strip it ourselves.
  shift @$args if @$args and $args->[0] eq '--';

  ( my $bare_version = $version ) =~ s/\Aperl-//;
  my $pb_version = $bare_version =~ /\A[\d._]+\z/ ? "perl-$bare_version" : $version;

  $ctx->ensure_correct_perlbrew_context( $pb_version );

  my $local_lib = $ctx->local_lib;
  die "No Mist environment built for $pb_version.\n"
    . "Build it first with: ./mpan-install --perlbrew=$bare_version\n"
    unless -d "$local_lib";

  $ctx->with_project_libs( sub {
    my $root = $ctx->project_root;
    $ENV{PATH} = join ':',
      ( map { $root->subdir( $_ )->stringify } qw/ bin sbin script / ),
      ( defined $ENV{PATH} ? $ENV{PATH} : () );
    $ENV{PERL5LIB} = join ':',
      $root->subdir( 'lib' )->stringify,
      ( length( $ENV{PERL5LIB} // '' ) ? $ENV{PERL5LIB} : () );
    $ENV{LD_LIBRARY_PATH} = join ':',
      $root->subdir(qw/ perl5 lib /)->stringify,
      ( length( $ENV{LD_LIBRARY_PATH} // '' ) ? $ENV{LD_LIBRARY_PATH} : () );
    exec @$args;
  });
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::run - run a command inside the project's Perl environment

=head1 SYNOPSIS

  mist run prove -lr t/
  mist run perl -Ilib -MMy::Module -e '...'
  mist run --perlbrew=5.42.2 prove -lr t/

=head1 DESCRIPTION

Runs a command with the project's F<./perl5/> environment active: the
pinned perlbrew Perl, the C<local::lib> paths, and the project's F<bin/>,
F<sbin/> and F<script/> directories on C<PATH>.

It is equivalent to the generated F<./mist-run> wrapper, but works before
that wrapper has been created and regardless of the current directory.
C<run> needs an initialized environment -- it aborts if
F<perl5/bin/mist-run> is missing; run L<mist init|App::Mist::Command::init>
first.

Do not use C<mist run> to invoke C<mist> itself: C<mist> manages the
project's Perl and must not run under it.

=head1 OPTIONS

=head2 --perlbrew=VERSION

Run the command under F<./perl5/perl-VERSION-E<lt>archE<gt>/> instead of the
perl pinned in the F<mistfile>. The version may be given bare (C<5.42.2>) or
in perlbrew form (C<perl-5.42.2>). The matching environment must already be
built; if it is missing, run C<./mpan-install --perlbrew=VERSION> first. This
is useful for testing a distribution against several Perl versions installed
side by side.

Unlike the default path, C<--perlbrew> bypasses the generated
F<perl5/bin/mist-run> wrapper, which is pinned to whichever perl last ran
F<mpan-install>.

=head1 SEE ALSO

L<App::Mist::Command::init>, L<App::Mist::Command::lib_paths>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
