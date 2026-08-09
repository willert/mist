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
use version 0.77 ();

use Mist::ParseDistribution;
use Mist::PackageManager::MPAN;

use Mist::Minilla::Project;
use Minilla::Util qw/ check_git /;

use Cwd;
use Try::Tiny;
use Capture::Tiny ':all';

sub usage_desc { '%c merge %o <project-path>' }

sub opt_spec {
  return (
    [ 'trial'     => 'newest release tag including trial (_NN) prereleases' ],
    [ 'release=s' => 'exactly this released version, stable or trial' ],
    [ 'dev'       => "the sibling's working tree instead of a release tag" ],
  );
}

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;

  my ( $dist, $project, $work_dir );

  die "$0: No Minilla directory to merge\n"
    unless $args and ref $args eq 'ARRAY' and @$args;

  die "$0: --dev, --trial and --release are mutually exclusive\n"
    if 1 < grep { defined and length } $opt->dev, $opt->trial, $opt->release;

  my $path = dir( pop @$args )->absolute->resolve;

  die "$0: ${path} is not Minilla distribution\n"
    unless -d q{}. $path and -f -r q{}. $path->file('cpanfile');

  # $source_guard holds the tag checkout alive until execute is left, on every
  # exit path including die; everything below must read from $source, never
  # $path, or a tag merge silently mixes in working-tree state.
  my ( $source, $selected, $source_guard ) =
    $self->_resolve_source( $ctx, $opt, $path );

  my $current_pwd = dir( getcwd());
  try {
    chdir( "$source" );
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

  die "$0: no distribution could be built from ${source}\n" unless $dist;

  if ( defined $opt->release and length $opt->release ) {
    ( my $want = $opt->release ) =~ s/^v//;
    my ( $built ) = basename( "$dist" ) =~ /-v?([0-9][0-9._]*)\.tar\.gz$/;
    die sprintf "$0: tag %s built version %s, not the requested %s\n",
        $selected->{tag}, $built // 'unknown', $opt->release
      unless defined $built
         and eval { version->parse( $built ) == version->parse( $want ) };
  }

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

  my $other_mistfile = $source->file( 'mistfile' );
  my $other_env = do{
    if ( -f -r "$other_mistfile" ) {
      Mist::Environment->new( "$other_mistfile" )->parse
          or die "Error parsing $other_mistfile";
    }
  };

  $package_manager->add_mirror(
    sprintf( 'file://%s/', $source->subdir( 'mpan-dist' ))
  ) if -d -r $source->subdir( 'mpan-dist' )->stringify;

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

  _warn_unless_declared( $ctx, $dist_info );

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
# `./mpan-install` only ever reaches a distribution the cpanfile NAMES. cpanm
# re-resolves a named module against the index, but a dependency reached
# transitively is tested against its parent's declared floor, and an installed
# copy satisfying that floor is never compared against the index at all. So a
# merged distribution nobody declared is vendored and then silently not
# installed - the merge appears to work and changes nothing.
#
# Checked against the modules the built distribution actually provides, never
# the merge block's name: that name is a label, and several in this estate do
# not match their module's real casing. Naming any one provided module suffices,
# since cpanm resolves module -> distribution and installs the whole thing.
#
# Deliberately says nothing about versions. Whether a declaration should carry
# one is a judgement about what this project requires of the world, not
# something a merge can decide.
sub _warn_unless_declared {
  my ( $ctx, $dist_info ) = @_;

  my $cpanfile = $ctx->project_root->file( 'cpanfile' );
  return unless -f -r "$cpanfile";

  my $provided = eval { $dist_info->modules } or return;
  return unless keys %$provided;

  my $declared = eval {
    require Module::CPANfile;
    my %named = map { $_ => 1 }
      Module::CPANfile->load( "$cpanfile" )
                      ->prereqs->merged_requirements->required_modules;
    \%named;
  } or return;

  return if grep { $declared->{ $_ } } keys %$provided;

  printf STDERR "Note: nothing in cpanfile names %s, so ./mpan-install will not "
              . "install it.\n      Add a bare `requires` line for the module "
              . "this project uses.\n",
    eval { $dist_info->as_module_name } || 'this distribution';
  return;
}

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

# Decide which state of the sibling gets built, and hand back a directory that
# every later read goes through. For tag modes that is a detached git worktree
# under the consumer's mist workspace: dist build, mistfile and mpan-dist mirror
# then all come from the same released tree by construction, instead of a tag
# build quietly slurping a working-tree mistfile. Returns the source dir, the
# selected-tag record (undef for --dev), and a guard whose destruction removes
# the checkout.
sub _resolve_source {
  my ( $self, $ctx, $opt, $path ) = @_;

  if ( $opt->dev ) {
    printf "Merging working tree of %s\n", $path;
    _warn_working_tree_state( $path );
    return ( $path, undef, undef );
  }

  my @tags = split /\n/, _git( $path, qw/ tag --merged HEAD / );

  my $selected = _select_release_tag(
    \@tags, trial => $opt->trial, release => $opt->release,
  );

  unless ( $selected ) {
    if ( defined $opt->release and length $opt->release ) {
      my @shaped = grep { /^v?\d+(?:\.\d+)+(?:_\d+)?$/ } @tags;
      die sprintf "$0: no release tag for version %s in %s\n%s",
        $opt->release, $path,
        @shaped ? sprintf( "    available: %s\n", join ', ', @shaped )
                : "    (the project has no release tags at all)\n";
    }
    my $newest_trial = _select_release_tag( \@tags, trial => 1 );
    die $newest_trial
      ? sprintf( "$0: no stable release tag in %s - newest is trial %s\n"
               . "    use --trial for it, or --dev for the working tree\n",
                 $path, $newest_trial->{tag} )
      : sprintf( "$0: no release tags in %s - use --dev to merge the working"
               . " tree\n", $path );
  }

  my $tag = $selected->{tag};

  printf "Merging %s at release tag %s%s\n",
    $path, $tag, $selected->{trial} ? ' (trial)' : '';

  my $ahead = _git( $path, 'rev-list', '--count', "${tag}..HEAD" );
  my $dirty = length _git( $path, qw/ status --porcelain / );
  printf "    the sibling's working tree is %s - use --dev for its current state\n",
    join ' and ', ( $ahead ? "${ahead} commit(s) ahead" : () ),
                  ( $dirty ? 'dirty' : () )
    if $ahead or $dirty;

  ( my $checkout_name = $tag ) =~ s/[^\w.-]+/-/g;
  my $checkout = $ctx->workspace->subdir( 'merge-src' )->subdir( $checkout_name );
  $checkout->parent->mkpath;

  # A leftover from an aborted merge: the guard could not run, but the metadata
  # in the sibling's .git survives, so worktree add would refuse the path.
  _remove_tag_checkout( $path, $checkout ) if -d "$checkout";

  _git( $path, qw/ worktree add --detach /, "$checkout", $tag );

  my $guard = App::Mist::Command::merge::_CleanupGuard->new( sub {
    _remove_tag_checkout( $path, $checkout );
  });

  return ( dir( "$checkout" ), $selected, $guard );
}

sub _remove_tag_checkout {
  my ( $repo, $checkout ) = @_;

  # Best-effort by design: cleanup must never turn a finished merge into a
  # failure, and half-removed state falls to the next merge's stale sweep.
  eval { _git( $repo, qw/ worktree remove --force /, "$checkout" ) };
  File::Path::rmtree( "$checkout" ) if -d "$checkout";
  eval { _git( $repo, qw/ worktree prune / ) };
  return;
}

# Pick the tag to merge from a list of tag names. Only version-shaped tags
# count: an optional leading `v`, dotted digits, an optional _NN trial suffix -
# anything else (release-checkpoint-*, wip, ...) is invisible here. Ordering
# and equality go through version.pm, because that is what the CPAN-shaped
# mirror resolves versions with: 0.9 beats 0.10, and 0.52_01 sorts between
# 0.52 and 0.53, exactly as a consumer's requirement floor would see them.
sub _select_release_tag {
  croak sprintf 'BUG: _select_release_tag takes a tag list and options'
    unless ref $_[0] eq 'ARRAY';

  my ( $tags, %opt ) = @_;

  my @candidates;
  for my $tag ( @$tags ) {
    my ( $vstr ) = $tag =~ /^v?(\d+(?:\.\d+)+(?:_\d+)?)$/ or next;
    my $version = eval { version->parse( $vstr ) } or next;
    push @candidates, {
      tag => $tag, version => $version, trial => ( $vstr =~ /_/ ? 1 : 0 ),
    };
  }

  if ( defined $opt{release} and length $opt{release} ) {
    ( my $want_str = $opt{release} ) =~ s/^v//;
    my $want = eval { version->parse( $want_str ) }
      or die "$0: --release '$opt{release}' does not look like a version\n";
    my ( $hit ) = sort { $a->{tag} cmp $b->{tag} }
      grep { $_->{version} == $want } @candidates;
    return $hit;
  }

  my @eligible = $opt{trial} ? @candidates
                             : grep { not $_->{trial} } @candidates;
  my ( $best ) = sort {
    $b->{version} <=> $a->{version} or $a->{tag} cmp $b->{tag}
  } @eligible;
  return $best;
}

# The dist is built from git's tracked-file list with working-tree content, so
# the two failure modes are asymmetric: uncommitted edits ride along invisibly,
# while untracked files are silently absent from the tarball. Say both out loud.
sub _warn_working_tree_state {
  my ( $path ) = @_;

  my @untracked = split /\n/,
    _git( $path, qw/ ls-files --others --exclude-standard / );
  my @modified  = split /\n/,
    _git( $path, qw/ diff HEAD --name-only / );

  printf STDERR "Warning: uncommitted changes will be merged: %s\n",
    join ', ', @modified if @modified;
  printf STDERR "Warning: untracked files will be MISSING from the merged"
    . " dist: %s\n", join ', ', @untracked if @untracked;
  return;
}

sub _git {
  my ( $repo, @cmd ) = @_;

  my ( $stdout, $stderr, $exit ) = capture {
    system 'git', '-C', "$repo", @cmd;
  };
  croak sprintf "git %s failed in %s:\n%s",
    join( ' ', @cmd ), $repo, $stderr || $stdout
    if $exit != 0;

  chomp $stdout;
  return $stdout;
}

{
  package # hide from PAUSE
    App::Mist::Command::merge::_CleanupGuard;

  sub new { my ( $class, $code ) = @_; return bless { code => $code }, $class }
  sub DESTROY { my $self = shift; $self->{code}->() if $self->{code}; return }
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::merge - merge another mist-managed project into this one

=head1 SYNOPSIS

  mist merge ../other-project                 # newest stable release tag
  mist merge --trial ../other-project         # newest tag, trials included
  mist merge --release 0.52 ../other-project  # exactly this version
  mist merge --dev ../other-project           # the working tree, as-is

=head1 DESCRIPTION

Pulls another mist-managed project, given by its path on disk, into the
current one. C<merge> builds and injects that project's distribution --
together with the dependency call-stack from its own F<mistfile> -- into
F<mpan-dist/>, and then splices a marker-delimited block into the local
F<mistfile>.

By default the state merged is the sibling's newest B<stable release tag>
reachable from its checked-out C<HEAD>: version-shaped tags (C<0.53>,
C<v0.53>) ordered by Perl version semantics, ignoring trial prereleases
(C<0.52_01>) and tags that are not versions at all. Stable tags are the
artifacts that went through C<mist release>'s clean-room validation, so the
bare command means "the last known good version". The tag is checked out
into a detached git worktree under the per-project mist workspace, and
everything C<merge> reads - the distribution build, the sibling's
F<mistfile>, its F<mpan-dist/> mirror - comes from that checkout, so the
merged result corresponds exactly to a released state. The checkout is
removed when the merge finishes, and C<merge> reports when the sibling's
working tree has moved past the tag it built.

Three options select another state; they are mutually exclusive:

=over 4

=item C<--trial>

The newest release tag I<including> trial prereleases as cut by
L<mist prerelease|App::Mist::Command::prerelease>. This is the flag for the
prerelease cycle: run C<prerelease> in the sibling, C<merge --trial> here,
iterate; each iteration is a distinct version, so the mirror never sees the
same tarball name with different content.

=item C<--release VERSION>

Exactly this released version, stable or trial, spelled with or without a
leading C<v>. The merge fails if no such tag exists or if the tag's tree
builds a different version than asked for.

=item C<--dev>

The sibling's working tree, unmediated by any tag. The dist is built from
git's tracked-file list with working-tree I<content>: uncommitted edits ride
along, untracked files are silently absent - C<merge> warns about both. The
result can correspond to no commit of the sibling and its tarball name can
collide with a later real release, so keep a C<--dev> merge out of committed
history.

=back

The block spliced into the local F<mistfile> looks like this:

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
