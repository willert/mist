package App::Mist::Command::run;
# ABSTRACT: run a command in this projects environment

use 5.010;

use App::Mist -command;

sub usage_desc { '%c run %o <command>...' }

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $ctx    = $self->app->ctx;
  my $runner = $ctx->project_root->file(qw/ perl5 bin mist-run /);

  die "No initialized Mist environment found" unless -x "$runner";

  $ctx->ensure_correct_perlbrew_context;

  $ENV{ $_ } = undef for grep{ /PERL|MIST/ } keys %ENV;

  my @cmd = ( bash => '-l', $runner, @$args );
  exec @cmd;
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::run - run a command inside the project's Perl environment

=head1 SYNOPSIS

  mist run prove -lr t/
  mist run perl -Ilib -MMy::Module -e '...'

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

=head1 SEE ALSO

L<App::Mist::Command::init>, L<App::Mist::Command::lib_paths>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
