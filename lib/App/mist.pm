package App::mist;

use strict;
use warnings;

use Carp;
use Scalar::Util qw/looks_like_number blessed/;

use App::Cmd::Setup -app;

use App::mist::Command::build;
use App::mist::Command::index;

1;
