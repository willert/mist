package Mist::Script::usage;
1;

=head1 NAME

 mpan-install

=head1 SYNOPSIS

 ./mpan-install [OPTIONS] [cpanm options] [MODULES ...]

 Options:
   --help            display this help message

   --force-tests       ignore notest from mistfile, but still install dists
   --perlbrew VERSION  use this perlbrew-managed perl version
   --build-only        build (or rebuild) the target perl's environment but
                       do not activate it; the current selector is untouched
   --no-resume         discard a resumable build left by a failed install and
                       reseed the generation from its parent (the default resumes)
   --rebuild           build the whole closure into a fresh, un-seeded generation,
                       shedding cruft accumulated across copy-on-write generations
   --purge             after a successful install, remove this perl's other
                       auto-numbered generations (and stale ...-build dirs),
                       keeping the active one; named generations are left untouched
   --bundle ID         apply a dependency bundle: install its Module~VERSION
                       floors into a fresh generation (incremental and atomic,
                       never a downgrade). ID is a published name found in
                       mpan-dist/bundles/, else an ephemeral uuid in the workspace

   --branch [BRANCH]
       build into a named generation instead of an auto-numbered one
       (defaults to the git branch name)
   --parent BRANCH
       seed the new generation from another named generation

   --prove
       after install, run `prove -l t` against this env

 All other options will be passsed on to cpanm.

 If MODULES are given install just those modules instead of the dependencies
 given in cpanfile

=cut
