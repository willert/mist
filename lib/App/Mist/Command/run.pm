package App::Mist::Command::run;
# ABSTRACT: run a command in this projects environment

use 5.010;

use App::Mist -command;

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
