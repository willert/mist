# package App::mist::Command;
#
# use strict;
# use warnings;
#
# use Carp;
# use Scalar::Util qw/looks_like_number blessed/;
#
# use App::Cmd::Setup -command;
#
# sub opt_spec {
#   my ( $class, $app ) = @_;
#   return (
#     [ 'help' => "This usage screen" ],
#     # $class->options($app),
#   )
# }
#
# sub validate_args {
#   my ( $self, $opt, $args ) = @_;
#   die $self->_usage_text if $opt->{help};
#   $self->validate( $opt, $args );
# }
#
# 1;
