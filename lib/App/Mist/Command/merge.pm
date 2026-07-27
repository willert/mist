package App::Mist::Command::merge;
# ABSTRACT: merge mist-managed dist from given path

use 5.010;

use App::Mist -command;

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
    local_lib    => $ctx->local_lib,
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

    $our_mistfile->spew({ iomode => '<:utf8' }, _splice_merge_block(
      $our_mistfile->slurp( iomode => '<:utf8' ),
      $dist_info->as_module_name,
      $other_mistfile->slurp( iomode => '<:utf8' ),
    ));
  }

  print "\nPlease run\n  mist compile\nas mistfile might have changed\n";

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
  my ( $mistfile, $distname, $spec ) = @_;

  $spec =~ s/\n(?!\n|$)/\n  /g; # indent merged file

  my $merged = sprintf <<'MERGE_SPEC', ( $distname ) x 2, $spec, $distname;
### <<<[%s] - keep this line intact
merge '%s' => sub {
  # generated code block - do not edit

  %s
};
### [%s]>>> - keep this line intact
MERGE_SPEC

  $mistfile =~ s{^### <<<\[(\Q${distname}\E)\].*?^### \[\1\]>>>[^\n]*(?:\n|\z)}
                {$merged}sm
    or $mistfile .= "\n\n${merged}";

  return $mistfile;
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

Because the F<mistfile> changes, C<merge> reminds you to run
L<mist compile|App::Mist::Command::compile> afterwards.

=head1 SEE ALSO

L<App::Mist::Command::compile>, L<App::Mist::Command::init>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
