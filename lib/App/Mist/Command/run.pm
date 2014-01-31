package App::Mist::Command::run;
use 5.014;

use Moose;
extends 'MooseX::App::Cmd::Command';

sub execute {
  my ( $self, $opt, $args ) = @_;

  my $ctx    = $self->app->ctx;
  my $runner = $ctx->project_root->file(qw/ perl5 bin mist-run /);

  die "No initialized Mist environment found" unless -x "$runner";

  exec $runner, @$args;
}
