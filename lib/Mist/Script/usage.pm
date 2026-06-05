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
   --build-only        build (or rebuild) the target perl's environment but
                       do not activate it; the current selector is untouched

   --branch [BRANCH]
       work on a named local::lib branch (defaults to git branch)
   --parent BRANCH
       use another named branch as basis for branch to work on

   --prove
       after install, run `prove -l t` against this env

 All other options will be passsed on to cpanm.

 If MODULES are given install just those modules instead of the dependencies
 given in cpanfile

=cut
