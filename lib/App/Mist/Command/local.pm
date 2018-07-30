package App::Mist::Command::local;
# ABSTRACT: Install module into local lib, bypassing mpan-dist

use 5.010;

use App::Mist -command;

use Mist::Role::cpanminus;
use Mist::PackageManager::MPAN;

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

  Mist::Role::cpanminus->run_bundled_cpanm_script(
    @cpanm_options, @cmd_args, @modules
  );
}

1;
