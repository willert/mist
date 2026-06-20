package App::Mist::Command::bundle;
# ABSTRACT: manage dependency bundles (errata)

use 5.010;

use App::Mist -command;

use POSIX qw/ strftime /;
use Mist::Bundle;

# A single flat command dispatching on the first positional verb. Only `publish`
# exists today; list/show/prune can join here, or this can migrate to
# App::Cmd::Subdispatch, once a second verb earns the machinery.
my %VERB = (
  publish => \&_publish,
);

sub usage_desc { '%c bundle %o <verb> [args]' }

sub opt_spec {
  return (
    [ 'as=s'          => 'the published name (required for publish)' ],
    [ 'description=s' => 'a human description to record in the bundle metadata' ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;

  my ( $verb, @rest ) = @{ $args || [] };
  die "$0: bundle needs a verb (one of: @{[ sort keys %VERB ]})\n"
    unless defined $verb;

  my $handler = $VERB{ $verb }
    or die "$0: unknown bundle verb '$verb' (try: @{[ sort keys %VERB ]})\n";

  return $self->$handler( $self->app->ctx, $opt, \@rest );
}

# publish <uuid> --as <name> [--description ...]
#
# Promote an ephemeral bundle from the workspace into the committed mpan-dist
# mirror under a chosen name, attaching the human metadata. This is the
# deliberate "this set is worth keeping" act and the only point a bundle gains a
# name. Pure filesystem work - no perlbrew context.
sub _publish {
  my ( $self, $ctx, $opt, $args ) = @_;

  my ( $uuid ) = @$args;
  die "$0: bundle publish needs an ephemeral bundle id\n" unless defined $uuid;

  my $name = $opt->as;
  die "$0: bundle publish needs --as <name>\n"
    unless defined $name and length $name;
  die "$0: invalid bundle name '$name' (use letters, digits, '.', '-', '_')\n"
    unless Mist::Bundle->valid_id( $name );

  my $src = $ctx->workspace->subdir( 'bundles' );
  die "$0: no ephemeral bundle '$uuid' under $src\n"
    unless -e $src->file( "$uuid.bundle" );

  my $ephemeral = Mist::Bundle->load( $src, $uuid );

  my %meta = (
    name      => $name,
    published => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
  );
  $meta{description} = $opt->description
    if defined $opt->description and length $opt->description;

  my $dst    = $ctx->mpan_dist->subdir( 'bundles' );
  my $bundle = Mist::Bundle->new({ specs => $ephemeral->specs, meta => \%meta })
    ->save( $dst, $name );

  printf STDERR "Published bundle '%s' (%d floors) to %s\n",
    $name, scalar @{ $ephemeral->specs }, $bundle;
  printf STDERR
    "Commit %s and its .meta with mpan-dist; apply with: ./mpan-install --bundle %s\n",
    $bundle->basename, $name;

  return;
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::bundle - manage dependency bundles

=head1 SYNOPSIS

  mist bundle publish <uuid> --as "cve-2026-1234"
  mist bundle publish <uuid> --as "cve-2026-1234" --description "bump HTTP stack"

=head1 DESCRIPTION

A B<bundle> is a small, named set of dependency floor specs - mist's equivalent
of a distribution security erratum ("these versions, applied as a unit"). See
L<Mist::Bundle> for the format and L<mist inject|App::Mist::Command::inject>'s
C<--full-dependency-tree> for how an ephemeral bundle is produced.

=head1 VERBS

=head2 publish I<uuid> C<--as> I<name> [ C<--description> I<text> ]

Promotes the ephemeral bundle I<uuid> (produced under
F<~/.mist/E<lt>projectE<gt>/bundles/>) into the committed mirror at
F<mpan-dist/bundles/I<name>.bundle>, writing an F<I<name>.meta> sidecar with the
name, the optional description, and the publish timestamp. Metadata is attached
here, at publish time, not when the ephemeral bundle is produced.

This is the point a bundle becomes durable and portable: once committed with
F<mpan-dist>, it travels with the project and applies on any machine - including
production hosts that have only F<./mpan-install> and no C<mist> - via
C<< ./mpan-install --bundle I<name> >>.

Publishing over an existing name simply rewrites the files; the overwrite is a
tracked change you review before committing and can revert from history, so there
is no C<--force> ceremony.

=head1 SEE ALSO

L<Mist::Bundle>, L<App::Mist::Command::inject>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
