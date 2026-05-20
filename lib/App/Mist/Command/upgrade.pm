package App::Mist::Command::upgrade;
# ABSTRACT: upgrade all outdated distributions in mpan-dist

use 5.010;

use App::Mist -command;

use Mist::PackageManager::MPAN;

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

__END__

=pod

=head1 NAME

App::Mist::Command::upgrade - re-inject outdated distributions in mpan-dist

=head1 SYNOPSIS

  mist upgrade

=head1 DESCRIPTION

Catches the project's installed F<./perl5/> up to the module versions
vendored in F<mpan-dist/>. Using the bundled C<cpan-outdated> helper, it
compares each module installed under F<perl5/> against the version recorded
in F<mpan-dist/>'s package index, and reinstalls -- from F<mpan-dist/> --
every module whose installed copy lags behind. It prints C<All modules up
to date> when nothing lags.

This closes a gap that C<./mpan-install> cannot. C<mpan-install> resolves
the F<cpanfile> prerequisites through C<cpanm>, which reinstalls a
distribution only when its requirement is I<unsatisfied>: an older version
that still satisfies the F<cpanfile> pin is left untouched, even once
F<mpan-dist/> vendors something newer. C<upgrade> keys off the raw
installed-versus-vendored version comparison instead, so it pulls the newer
vendored release in regardless -- without the full F<perl5/> wipe and cold
rebuild that would otherwise be the only way to get there.

The typical trigger: F<mpan-dist/> is version-controlled, a teammate
commits newer vendored tarballs, you pull them, and C<mist upgrade> brings
your F<perl5/> into line incrementally.

=head1 SEE ALSO

L<App::Mist::Command::inject>, L<App::Mist::Command::init>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
