package App::Mist::Command::local;
use 5.010;

use App::Mist -command;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  die "$0: No module to install"
    unless $args and ref $args eq 'ARRAY' and @$args;

  $ctx->ensure_correct_perlbrew_context;

  my @cpanm_options = (
    '--quiet',
    '--local-lib-contained' => $ctx->local_lib,
    '--mirror-only',
    # use cpan for the requested package
    '--mirror' => 'http://search.cpan.org/CPAN',
  );

  my @modules  = grep{ !/^-/ } @$args;
  my @cmd_args = grep{ /^-/ } @$args;

  require Mist::Role::cpanminus;
  Mist::Role::cpanminus->run_cpanm( @cpanm_options, @cmd_args, @modules );
}

1;
