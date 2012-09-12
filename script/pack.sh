echo Trace
perl -Mlocal::lib=perl5 -Ilib `which fatpack` trace script/mist.PL
echo Create packlist
perl -Mlocal::lib=perl5 -Ilib `which fatpack` packlists-for `cat fatpacker.trace` > packlists
echo Build tree
perl -Mlocal::lib=perl5 -Ilib `which fatpack` tree `cat packlists`
echo Fat-packing
(
		echo '#!/usr/bin/env perl' >&2;
		perl -Mlocal::lib=perl5 -Ilib `which fatpack` file 3>&1 1>&2 2>&3 |
		  grep -v "\.pod isn't a .pm file" |
		  grep -v "auto/List/Util/Util" |
		  grep -v "auto/Params/Util/Util" |
			cat
    cat script/mist.PL | grep -v '^#' >&2
) 2> bin/mist

rm fatpacker.trace
rm packlists

chmod a+x bin/mist
