package App::Mist::Command::merge;
# ABSTRACT: merge mist-managed dist from given path

use 5.010;

use App::Mist -command;

use Carp qw/ croak /;
use Path::Class qw/ dir file /;
use File::Spec::Functions qw/ catfile /;
use File::Basename qw/ basename /;
use File::Copy qw/ copy /;
use File::Path ();

use Mist::ParseDistribution;
use Mist::PackageManager::MPAN;

use Mist::Minilla::Project;
use Minilla::Util qw/ check_git /;

use Cwd;
use Try::Tiny;
use Capture::Tiny ':all';

sub usage_desc { '%c merge %o <project-path>' }

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  my ( $dist, $project, $work_dir );

  die "$0: No Minilla directory to merge\n"
    unless $args and ref $args eq 'ARRAY' and @$args;

  my $path = dir( pop @$args )->absolute->resolve;

  die "$0: ${path} is not Minilla distribution\n"
    unless -d q{}. $path and -f -r q{}. $path->file('cpanfile');

  printf "Merging distribution located in %s\n", $path;

  my $current_pwd = dir( getcwd());
  try {
    chdir( "$path" );
    check_git;
    capture_stdout {
      $project = Mist::Minilla::Project->new;
      $work_dir = $project->work_dir;
      $dist = $work_dir->dist();
    };
  } catch {
    /Minilla::Error::CommandExit/ and return;
    printf STDERR "%s\n", $_;
  } finally {
    chdir "$current_pwd";
  };

  exit 1 unless $dist;

  printf "Injecting distribution %s\n", $dist;

  $ctx->ensure_correct_perlbrew_context;

  my $package_manager = Mist::PackageManager::MPAN->new({
    project_root => $ctx->project_root,

    # The sibling and its call stack are vendored into mpan-dist, not installed
    # into the live environment: a throwaway seeded from it absorbs the install -
    # see App::Mist::Context::_build_staging_lib.
    local_lib    => $ctx->staging_lib,
    workspace    => $ctx->workspace_lib,
    mirror_only  => 1,    # merge resolves strictly from the pinned mpans
  });

  my $other_mistfile = $path->file( 'mistfile' );
  my $other_env = do{
    if ( -f -r "$other_mistfile" ) {
      Mist::Environment->new( "$other_mistfile" )->parse
          or die "Error parsing $other_mistfile";
    }
  };

  $package_manager->add_mirror(
    sprintf( 'file://%s/', $path->subdir( 'mpan-dist' ))
  ) if -d -r $path->subdir( 'mpan-dist' )->stringify;

  $package_manager->begin_work;

  eval {

    for my $cmd ( $other_env ? $other_env->build_cpanm_call_stack : () ) {
      # run foreign mist callstack before trying to install dist itself
      $package_manager->install( @$args, @$cmd );
    }

    $package_manager->install( @$args, $dist );
  };


  my $install_error = $@;
  $package_manager->commit;

  die "Merging ${dist} failed:\n" . $install_error if $install_error;


  my $dist_info = Mist::ParseDistribution->new(
    $dist, repository => $ctx->mpan_dist
  );

  if ( -f -r "$other_mistfile" ) {
    print "Merging mistfile $other_mistfile\n";

    my $our_mistfile = $ctx->project_root->file( 'mistfile' );
    $our_mistfile->touch; # ensure local mistfile exists

    if ( not -f -r -w "$our_mistfile" ) {
      print STDERR "Can't write to $our_mistfile, skipping merge\n";
      goto MISTFILE_DONE;
    }

    # slurp is context-sensitive: in list context it returns one value per line.
    # These have to reach scalars before being passed on - inlined into the call
    # below, the first one explodes into one argument per line of the mistfile.
    my $mistfile = $our_mistfile->slurp( iomode => '<:utf8' );
    my $spec     = $other_mistfile->slurp( iomode => '<:utf8' );

    my $backup = $ctx->workspace->file( 'mistfile.bak' );
    _write_mistfile( $our_mistfile, $backup, _splice_merge_block(
      $mistfile, $dist_info->as_module_name, $spec
    ));
    printf "Previous mistfile kept at %s\n", $backup;
  }

  print "\nPlease run\n  mist compile\n  ./mpan-install\n"
      . "as the mistfile might have changed, and the merged distribution is\n"
      . "vendored but not installed yet\n";

 MISTFILE_DONE:

  $project->cleanup if $project;
}

# Render dist $distname's merge block from $spec - the dist's own mistfile - and
# splice it into $mistfile, replacing that dist's existing block or appending a
# new one.
#
# Both markers are anchored at column 0. Embedding a mistfile indents every line
# of it, so a column-0 marker is top-level by construction while a nested one
# always carries at least two spaces: the anchor is what keeps this from binding
# to a subordinate block, where the next merge of the dist owning the enclosing
# block would regenerate the subtree and silently drop what we wrote.
sub _splice_merge_block {
  # Fixed arity, checked: Path::Class' slurp returns a list of lines in list
  # context, so passing one straight into this call silently shifts the mistfile
  # into $mistfile-is-line-1, $distname-is-line-2, $spec-is-line-3 and drops the
  # rest as surplus arguments. That wrote a mistfile down to its first three lines.
  croak sprintf 'BUG: _splice_merge_block takes 3 arguments, got %d', scalar @_
    if @_ != 3;

  my ( $mistfile, $distname, $spec ) = @_;

  # A blank name renders `### <<<[]` markers and `merge '' => sub`, which will not
  # parse. Refuse rather than write unparseable code into hand-authored source.
  croak 'BUG: refusing to write a merge block with a blank dist name'
    unless defined $distname and $distname =~ /\S/;
  croak "BUG: refusing to write a merge block for multi-line dist name '${distname}'"
    if $distname =~ /\n/;

  $spec =~ s/\n(?!\n|$)/\n  /g; # indent merged file

  my $merged = sprintf <<'MERGE_SPEC', ( $distname ) x 2, $spec, $distname;
### <<<[%s] - keep this line intact
merge '%s' => sub {
  # generated code block - do not edit

  %s
};
### [%s]>>> - keep this line intact
MERGE_SPEC

  my $original = $mistfile;

  $mistfile =~ s{^### <<<\[(\Q${distname}\E)\].*?^### \[\1\]>>>[^\n]*(?:\n|\z)}
                {$merged}sm
    or $mistfile .= "\n\n${merged}";

  _assert_only_target_block_changed( $original, $mistfile, $distname );

  return $mistfile;
}

# The backstop for the whole class of rewrite bug: a merge may only ever touch
# $distname's own top-level block, so every other top-level block must come out
# the far side, and none may be invented. Cheap, and it fails loudly on a rewrite
# that would otherwise silently discard hand-authored source.
sub _assert_only_target_block_changed {
  my ( $before, $after, $distname ) = @_;

  my %was = map { $_ => 1 } $before =~ m{^### <<<\[([^\]\n]*)\]}mg;
  my %now = map { $_ => 1 } $after  =~ m{^### <<<\[([^\]\n]*)\]}mg;
  delete $was{ $distname };
  delete $now{ $distname };

  if ( my @lost = sort grep { not $now{$_} } keys %was ) {
    croak sprintf 'BUG: refusing to write mistfile, it would drop top-level '
      . 'merge block(s): %s', join ', ', @lost;
  }
  if ( my @invented = sort grep { not $was{$_} } keys %now ) {
    croak sprintf 'BUG: refusing to write mistfile, it would invent top-level '
      . 'merge block(s): %s', join ', ', @invented;
  }

  return;
}

# The mistfile is hand-authored source that no generated artefact can
# reconstruct, so keep the previous content and swap the new one in by rename. A
# consumer without version control can then still recover.
#
# $backup belongs in the per-project mist workspace rather than beside the
# mistfile: projects commit their mistfile, so a backup in the project root shows
# up as an untracked file and trips the CheckUntrackedFiles step of their own
# mist release.
#
# The iomode has to be passed as a flat list: spew's `%args = splice(@_, 0, @_-1)`
# takes a hashref as a single odd element, leaving $args{iomode} undef and
# silently writing bytes - which would mangle a mistfile that the matching
# '<:utf8' slurp had decoded.
sub _write_mistfile {
  my ( $file, $backup, $content ) = @_;

  copy( "$file", "$backup" )
    or croak "Can't back $file up to $backup: $!";

  # Staged in the target's own directory: rename is only atomic within a single
  # filesystem, and the workspace may be on another one.
  my $tmp = $file->dir->file( $file->basename . '.tmp' );
  unless ( eval { $tmp->spew( iomode => '>:utf8', $content ); 1 } ) {
    my $error = $@;
    $tmp->remove if -e "$tmp";  # else the leftover is itself untracked cruft
    croak "Can't write ${tmp}: ${error}";
  }

  rename( "$tmp", "$file" )
    or croak "Can't move $tmp onto $file: $!";

  return;
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::merge - merge another mist-managed project into this one

=head1 SYNOPSIS

  mist merge ../other-project

=head1 DESCRIPTION

Pulls another mist-managed project, given by its path on disk, into the
current one. C<merge> builds and injects that project's distribution --
together with the dependency call-stack from its own F<mistfile> -- into
F<mpan-dist/>, and then splices a marker-delimited block into the local
F<mistfile>:

  ### <<<[Other::Dist] - keep this line intact
  merge 'Other::Dist' => sub { ... };
  ### [Other::Dist]>>> - keep this line intact

This is how those C<merge> blocks are created in the first place -- see the
C<merge> directive of the mistfile DSL. Re-running C<merge> on a project
whose block already exists refreshes that block in place.

The block written is always a top-level one. A F<mistfile> can also carry
I<subordinate> blocks for the same dist - nested inside the block of a
sibling that merges it too, and owned by that sibling's F<mistfile> - and
C<merge> neither binds to nor rewrites those.

Like L<mist inject|App::Mist::Command::inject>, C<merge> vendors rather than
installs. The sibling and its call stack are built in a throwaway lib seeded
from the live environment, and F<./perl5/> is left to C<./mpan-install>. So a
merge ends by asking for both C<mist compile>, because the F<mistfile> changed,
and C<./mpan-install>, which is what puts the merged distribution into the
environment.

=head1 SEE ALSO

L<App::Mist::Command::compile>, L<App::Mist::Command::init>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
