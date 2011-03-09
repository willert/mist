package App::Mist;

use strict;
use warnings;

use Carp;
use Scalar::Util qw/looks_like_number blessed/;

use App::Cmd::Setup -app;

use App::Mist::Command::build;
use App::Mist::Command::index;

1;
