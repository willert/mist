#!/bin/sh

fatpack trace cpan-outdated.PL
cat fatpacker.trace |
  grep -v 'Cwd\.pm' |
  grep -v 'File/Spec.*pm' |
  grep -v 'Scalar/Util\.pm' |
  grep -v 'List/Util\.pm' |
	sponge fatpacker.trace
fatpack packlists-for `cat fatpacker.trace` > packlists
fatpack tree `cat packlists`
fatpack file cpan-outdated.PL > cpan-outdated
chmod a+x cpan-outdated
