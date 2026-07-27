package App::Mist::Command::init;
# ABSTRACT: Inject dependencies and run mpan-install

use 5.010;

use App::Mist -command;

use Try::Tiny;
use File::Which;
use File::Find::Upwards;
use Path::Class qw/file dir/;
use Cwd;

sub opt_spec {
  return (
    # Removed, still parsed so it can be rejected by name instead of with Getopt's
    # bare "Unknown option".
    [ "rebuild|R", "removed - see the error text", { hidden => 1 } ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;

  die <<'REMOVED' if $opt->{rebuild};
mist init: --rebuild/-R has been removed.
If you want to start from scratch, you have to do it manually.
REMOVED

  my $ctx  = $self->app->ctx;

  my $app = $self->app;
  my $do  = sub{
    my @cmd = $app->prepare_command( @_ );
    $app->execute_command( @cmd );
  };

  # compile needs to run before switching context because it
  # will dynamically load some modules from mist's local::lib
  $do->( 'compile' ) unless $ENV{__MIST_COMPILATION_DONE};
  $ENV{__MIST_COMPILATION_DONE} = 1;

  $ctx->ensure_correct_perlbrew_context;

  my $plan = _injection_plan( $ctx->dist, $ctx->fetch_prereqs );

  my $run_script = sub {
    my @cmd = @_ == 1 && ref $_[0] eq 'ARRAY' ? @{$_[0]} : @_;
    local $ENV{MIST_APP_ROOT} = $ctx->project_root;
    local $ENV{MIST_PERL5_LIBDIR} = $ctx->local_lib;
    system( @cmd );
  };

  $run_script->( $_ ) for $ctx->dist->get_scripts( 'prepare' );

  $do->( 'inject',             @$args, @{ $plan->{prepend} } ) if @{ $plan->{prepend} };
  $do->( 'inject', '--notest', @$args, @{ $plan->{notest}  } ) if @{ $plan->{notest}  };
  # ccflags implies a host build of the dist, so it must be vendored even when it is
  # not otherwise a prepend/notest/prereq, or the host's mirror-only build of it
  # would fail. The flag is a host build-time directive, so the inject is plain.
  $do->( 'inject',             @$args, @{ $plan->{ccflags} } ) if @{ $plan->{ccflags} };
  $do->( 'inject',             @$args, @{ $plan->{prereqs} } ) if @{ $plan->{prereqs} };

  $run_script->( $_ ) for $ctx->dist->get_scripts( 'finalize' );

  print "Packaging and compilation successful!\n\n";

  {
    print "Running mpan-install\n";
    # we have to get rid of MIST_APP_ROOT here or else
    # ./mpan-install might update mist's own local lib
    # instead of the one of the project being worked on
    local $ENV{MIST_APP_ROOT} = undef;
    system( file('mpan-install')->absolute->stringify );
  }

  return;
}

# Build the four injection lists from the parsed mistfile and the raw cpanfile
# prereqs: the prepend / notest / ccflags directive dists - each vendored so the
# host can build it - and the remaining bulk prereqs. A prereq that names a
# directive dist is dropped from the bulk list and its version folded into the
# directive entry (so the dist injects pinned). ccflags is included because it
# implies a host build of that dist; an un-vendored ccflags dist would fail the
# host's mirror-only install.
sub _injection_plan {
  my ( $dist, @raw_prereqs ) = @_;
  my @prepend = $dist->get_prepended_modules;
  my @notest  = $dist->get_modules_not_to_test;
  # Both ccflags channels imply a host build of the dist, so both must be vendored.
  # Vendoring is mode-agnostic (the host just needs the tarball; the :env/:wrapper
  # distinction only matters at build time), so dedup the union of the two.
  my %cc_seen;
  my @ccflags = grep { !$cc_seen{$_}++ }
    map { $_->[0] } ( $dist->get_ccflags, $dist->get_ccflags_wrapper );
  my @prereqs = grep {
    my $this = $_;
    ! grep {
      $this =~ m/^${_}(?:~.*)$/ and $_ = $this   # fold the version into the directive
    } ( @prepend, @notest, @ccflags );
  } @raw_prereqs;
  return {
    prepend => \@prepend, notest => \@notest,
    ccflags => \@ccflags, prereqs => \@prereqs,
  };
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::init - bootstrap the project environment in one step

=head1 SYNOPSIS

  mist init

=head1 DESCRIPTION

The one-shot bootstrap. C<init> runs, in order:

=over

=item *

C<compile> -- regenerate F<mpan-install>;

=item *

switch into the project's pinned perlbrew Perl;

=item *

inject every declared dependency into F<mpan-dist/> -- the C<prepend>ed
modules first, then the C<notest> modules, then the C<ccflags> modules, then
the F<cpanfile> prereqs;

=item *

run any C<prepare> / C<finalize> scripts declared in the mistfile;

=item *

run F<./mpan-install> to populate F<./perl5/>.

=back

C<init> never deletes F<mpan-dist/> or F<perl5/>; it only adds what is declared
but not yet vendored.

C<-R> / C<--rebuild> is removed; starting from scratch is manual. Mind which
scope you actually want. For the B<environment>, C<./mpan-install --rebuild>
builds the dependency tree into a fresh generation and leaves the current one
activatable, and C<mist purge> reclaims superseded ones -- it reads
F<mpan-dist/> and never writes it, so it is not C<-R> with the re-merging
removed. For the B<mirror>, C<mist clean> drops tarballs the index no longer
references and C<mist merge> re-vendors one dist from its source checkout.
Nothing re-resolves the mirror wholesale: it is a committed artifact of pinned
tarballs, and rebuilding it from live sibling working trees is what made C<-R>
unreproducible.

=head1 SEE ALSO

L<App::Mist::Command::compile>, L<App::Mist::Command::inject>,
L<App::Mist::Command::merge>, L<App::Mist::Command::purge>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
