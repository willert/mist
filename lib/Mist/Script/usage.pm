package Mist::Script::usage;
1;

=head1 NAME

 mpan-install

=head1 SYNOPSIS

 ./mpan-install [OPTIONS] [cpanm options] [MODULES ...]

 Options:
   --help            display this help message

   --force-tests       ignore notest from mistfile, but still install dists
   --skip-prepended    don't prepend those modules requested in mistfile
   --skip-notest       don't prepend modules marked as 'notest' in mistfile
   --perlbrew VERSION  use this perlbrew-managed perl version

   --branch [BRANCH]
       work on a named local::lib branch (defaults to git branch)
   --parent BRANCH
       use another named branch as basis for branch to work on

   --all-available-versions
       run this mpan-install against all installed perl versions

 All other options will be passsed on to cpanm.

 If MODULES are given install just those modules instead of the dependencies
 given in cpanfile

=cut
