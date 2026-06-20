package Mist::Bundle;
# ABSTRACT: a portable set of dependency floor specs - mist's dependency erratum

use 5.010;
use Moo;
use Path::Class qw/ dir /;
use Carp qw/ croak /;
use Digest::SHA ();

# An ordered list of floor specs. Each is "Module::Name~VERSION"; cpanm reads
# the ~VERSION suffix as ">= VERSION", so a spec is a single whitespace-free
# token and a .bundle file is cat-able straight into cpanm / ./mpan-install.
has specs => (
  is       => 'ro',
  required => 1,
);

# Human metadata - name / description / published. Ephemeral bundles carry none
# (no .meta on disk); the name and the rest are attached when a bundle is
# published. Stored as a flat string => string map.
has meta => (
  is      => 'ro',
  default => sub { +{} },
);

# Fixed leading order so a published .meta diffs cleanly; any other keys follow,
# sorted.
my @META_ORDER = qw/ name description published /;

# A bundle id is a filename stem (an ephemeral UUID or a published name), never
# a path: reject anything with a slash, a leading dot, or a ".." run, the same
# traversal guard `release` puts on its candidate ids.
sub _check_id {
  my ( $class, $id ) = @_;
  croak "invalid bundle id '" . ( $id // '<undef>' ) . "'"
    unless defined $id
    and    $id =~ /\A[A-Za-z0-9][\w.-]*\z/
    and    $id !~ /\.\./;
  return $id;
}

# A fresh, UUID-shaped, ephemeral id for a produced bundle - an opaque label,
# never re-derived, so uniqueness (not cryptographic strength) is all it needs.
# Mirrors the candidate-id scheme in App::Mist::Command::release: /dev/urandom
# when available, a hash of pid+time+rand otherwise.
sub new_id {
  my $bytes;
  if ( open my $rand, '<:raw', '/dev/urandom' ) {
    read $rand, $bytes, 16;
    close $rand;
  }
  unless ( defined $bytes and length $bytes == 16 ) {
    $bytes = substr Digest::SHA::sha256( join( '-', $$, time, rand ) ), 0, 16;
  }
  my $hex = unpack 'H*', $bytes;
  return join '-',
    map { substr $hex, $_->[0], $_->[1] }
    [ 0, 8 ], [ 8, 4 ], [ 12, 4 ], [ 16, 4 ], [ 20, 12 ];
}

sub valid_id {
  my ( $class, $id ) = @_;
  return eval { $class->_check_id( $id ); 1 } ? 1 : 0;
}

sub spec_for {
  my ( $class, $module, $version ) = @_;
  croak "module name is required" unless defined $module and length $module;
  croak "version is required for a floor spec"
    unless defined $version and length $version;
  croak "module/version must not contain whitespace: '$module~$version'"
    if "$module$version" =~ /\s/;
  return "$module~$version";
}

sub spec_file {
  my ( $class, $dir, $id ) = @_;
  dir( $dir )->file( $class->_check_id( $id ) . '.bundle' );
}

sub meta_file {
  my ( $class, $dir, $id ) = @_;
  dir( $dir )->file( $class->_check_id( $id ) . '.meta' );
}

sub save {
  my ( $self, $dir, $id ) = @_;
  $dir = dir( $dir );
  $dir->mkpath;

  my $bundle = $self->spec_file( $dir, $id );
  my $fh = $bundle->openw;
  print {$fh} "$_\n" for @{ $self->specs };
  $fh->close;

  if ( keys %{ $self->meta } ) {
    my $mfh = $self->meta_file( $dir, $id )->openw;
    print {$mfh} $self->_meta_as_text;
    $mfh->close;
  }

  return $bundle;
}

sub load {
  my ( $class, $dir, $id ) = @_;
  $dir = dir( $dir );

  my $bundle = $class->spec_file( $dir, $id );
  croak "no bundle '$id' in $dir" unless -e "$bundle";

  my @specs;
  for my $line ( $bundle->slurp ) {
    chomp $line;
    $line =~ s/\A\s+//;
    $line =~ s/\s+\z//;
    next unless length $line;
    next if $line =~ /\A#/;
    push @specs, $line;
  }

  my %meta;
  my $meta = $class->meta_file( $dir, $id );
  if ( -e "$meta" ) {
    for my $line ( $meta->slurp ) {
      chomp $line;
      next if $line =~ /\A\s*(?:#|\z)/;
      my ( $key, $value ) = $line =~ /\A\s*(\w+)\s*:\s*(.*?)\s*\z/ or next;
      $meta{ $key } = $value;
    }
  }

  return $class->new({ specs => \@specs, meta => \%meta });
}

sub _meta_as_text {
  my $self = shift;
  my %meta  = %{ $self->meta };
  my %known = map { $_ => 1 } @META_ORDER;
  my @keys  = (
    ( grep { exists $meta{ $_ } } @META_ORDER ),
    ( sort grep { !$known{ $_ } } keys %meta ),
  );
  return join '', map {
    my $value = $meta{ $_ } // '';
    $value =~ s/\s+/ /g;       # one line per key: collapse any embedded newlines
    sprintf "%s: %s\n", $_, $value;
  } @keys;
}

1;

__END__

=pod

=head1 NAME

Mist::Bundle - a portable set of dependency floor specs

=head1 DESCRIPTION

A bundle is a small, named set of pinned-floor dist specs - "these versions,
applied as a unit" - mist's equivalent of a distribution security erratum. It is
the transport and incremental-apply unit for an already-resolved dependency set,
not a declaration of dependencies (that stays the F<cpanfile>) and not a
whole-tree lockfile (that stays the committed F<mpan-dist>).

=head2 On-disk format

A bundle is two files in a directory, keyed by an C<id>:

=over

=item F<< <id>.bundle >>

One floor spec per line, each C<Module::Name~VERSION>. C<cpanm> reads C<~VERSION>
as C<< >= VERSION >>, so applying a bundle never downgrades a host already ahead:
the result is C<max(local, bundle)> per dist. Each line is one whitespace-free
token, so the file is cat-able straight into C<cpanm> / C<./mpan-install>. Blank
lines and C<#> comments are ignored on read.

=item F<< <id>.meta >>

C<key: value> lines - C<name>, C<description>, C<published>. Present only for
published bundles; ephemeral bundles have the F<.bundle> alone.

=back

The C<id> is a filename stem - an ephemeral UUID or a published name - and is
guarded against path traversal.

=head1 METHODS

=over

=item C<< Mist::Bundle->spec_for( $module, $version ) >>

The floor spec string C<"$module~$version">. Dies if either part contains
whitespace.

=item C<< $bundle->save( $dir, $id ) >>

Writes F<< $dir/<id>.bundle >>, and F<< $dir/<id>.meta >> when the bundle carries
metadata. Returns the F<.bundle> path.

=item C<< Mist::Bundle->load( $dir, $id ) >>

Reads a bundle back, picking up the F<.meta> sidecar if present.

=back

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
