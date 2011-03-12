package App::Mist;

use strict;
use warnings;

use Carp;
use Scalar::Util qw/looks_like_number blessed/;

use App::Cmd::Setup -app;
use Module::Pluggable search_path => [ 'App::Mist::Command' ];


1;