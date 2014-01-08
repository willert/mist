package App::Mist::Command::local;
use 5.014;

use Moose;
extends 'MooseX::App::Cmd::Command';
with 'Mist::Role::cpanminus';

use Mist::PackageManager::MPAN;

sub execute {
  my ( $self, $opt, $args ) = @_;

  die "$0: No module to install"
    unless $args and ref $args eq 'ARRAY' and @$args;

  $self->app->ensure_correct_perlbrew_context;

  my @cpanm_options = (
    '--quiet',
    '--local-lib-contained' => $self->app->local_lib,
    '--mirror-only',
    # use cpan for the requested package
    '--mirror' => 'http://search.cpan.org/CPAN',
  );

  my @modules  = grep{ !/^-/ } @$args;
  my @cmd_args = grep{ /^-/ } @$args;

  for my $module ( @modules ) {
    $self->run_cpanm( @cpanm_options, @cmd_args, $module );
  }
}

1;
