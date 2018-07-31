package Minilla::Release::LocalTest;
use strict;
use warnings;
use utf8;

# use App::Prove;
#
# sub run {
#   my ($self, $project, $opts) = @_;
#
#   $opts->{test} or return;
#
#   my $app = App::Prove->new;
#   $app->process_args();
#   my $success = $app->run ? 1 : 0;
#   if ( not $success ) {
#     Minilla::Logger::errorf("Some tests failed, giving up.\n");
#     exit 1;
#   }
# }

use Minilla::Util qw(cmd);


sub run {
  my ($self, $project, $opts) = @_;

  $opts->{test} or return;
  cmd( mist => run => 'prove' );
}

1;
