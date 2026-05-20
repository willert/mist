package App::Mist::Command::lib_paths;
# ABSTRACT: Print library paths of current project

use 5.010;

use App::Mist -command;
use local::lib 2.00 ();

sub execute {
  my ( $self, $opt, $args ) = @_;
  my $ctx = $self->app->ctx;
  $ctx->ensure_correct_perlbrew_context;

  say $_ for $ctx->project_root->subdir('lib'),
    local::lib->lib_paths_for( $ctx->local_lib );
}

1;

__END__

=pod

=head1 NAME

App::Mist::Command::lib_paths - print the project's Perl library paths

=head1 SYNOPSIS

  mist lib_paths

=head1 DESCRIPTION

Prints, one per line, the library paths that make up the project's Perl
environment: the project's own F<lib/> directory followed by the
C<local::lib> paths under F<./perl5/>.

Useful for wiring the environment into an editor, an IDE or any external
tool that wants a C<PERL5LIB> without going through C<mist run>.

=head1 SEE ALSO

L<App::Mist::Command::run>

=head1 AUTHORS

Sebastian Willert <s.willert@wecare.de>

=cut
