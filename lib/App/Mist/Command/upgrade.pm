package App::Mist::Command::upgrade;
use 5.010;

use App::Mist -command;

use Capture::Tiny qw/ capture /;

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;
  $ctx->ensure_correct_perlbrew_context;

  my $mpan_dist_url = sprintf( 'file://%s/', $ctx->mpan_dist );

  my $cpan_outdated = File::Share::dist_file( 'App-Mist', 'cpan-outdated' );
  my @cpo_args = (
    '--mirror'              => $mpan_dist_url,
    '--local-lib-contained' => $ctx->local_lib,
  );

  # print "$cpan_outdated @cpo_args\n";
  my ( $stdout, $stderr, $exit ) = capture {
    system( $cpan_outdated, @cpo_args ) == 0 or die;
  };

  my @outdated = split qq{\n}, $stdout;

  if ( not @outdated ) {
    print "All modules up to date\n";
    exit 0;
  }

  require Mist::PackageManager::MPAN;
  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $ctx->project_root,
    local_lib    => $ctx->local_lib,
    workspace    => $ctx->workspace_lib,
    mirror_list  => [ $mpan_dist_url ],
  });

  $package_manager->begin_work;
  $package_manager->install( @outdated );
  $package_manager->commit;

}

1;
