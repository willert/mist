package App::Mist::Command::local;
# ABSTRACT: Install module into local lib, bypassing mpan-dist

use 5.010;

use App::Mist -command;

use Mist::Generation;
use Mist::Role::cpanminus;
use Mist::PackageManager::MPAN;

sub usage_desc { '%c local %o <module>...' }

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
    '--mirror' => 'https://www.cpan.org/',
  );

  my @modules  = grep{ !/^-/ } @$args;
  my @cmd_args = grep{ /^-/ } @$args;

  Mist::Role::cpanminus->run_bundled_cpanm_script(
    @cpanm_options, @cmd_args, @modules
  );

  # No activation runs here - the install mutated the active generation in
  # place - so refresh the stamp restarters watch. The recorded name is
  # unchanged; the full rewrite is the signal (a bare mtime touch would be
  # invisible to inotify-based watchers).
  Mist::Generation::stamp_active_generation(
    $ctx->perl5_base_lib->subdir( Mist::Generation::arch_path() )->stringify );
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::local - install a module into perl5/ without vendoring it

=head1 SYNOPSIS

  mist local Some::Module
  mist local --notest Some::Module

=head1 DESCRIPTION

Installs one or more modules straight into the project's F<./perl5/> with
C<cpanm>, fetching from CPAN. Unlike C<inject>, it does B<not> save the
distribution into F<mpan-dist/>.

The install is therefore local and temporary: it will not survive a
C<mist init --rebuild>, and it will not ship to other hosts. Use C<local>
for throwaway experiments; for anything a reproducible build depends on,
use L<mist inject|App::Mist::Command::inject> and declare it in F<cpanfile>.

Arguments beginning with C<-> are passed through to C<cpanm> as options;
the remaining arguments are taken as module names.

A successful install also refreshes the activation stamp
F<perl5/etc/mist.active-generation>: the named generation is unchanged, but
the stamp is rewritten in full, so restarters watching it pick up the new
modules (a bare mtime touch would be invisible to inotify-based watchers).

=head1 SEE ALSO

L<App::Mist::Command::inject>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
