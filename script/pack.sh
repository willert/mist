echo Trace
perl -Mlocal::lib=perl5 -Ilib `which fatpack` trace script/mist.PL
echo Create packlist
perl -Mlocal::lib=perl5 -Ilib `which fatpack` packlists-for `cat fatpacker.trace` > packlists
echo Build tree
perl -Mlocal::lib=perl5 -Ilib `which fatpack` tree `cat packlists`
echo Fat-packing
( echo '#!/usr/bin/perl'; perl -Mlocal::lib=perl5 -Ilib `which fatpack` file; cat script/mist.PL ) > bin/mist

rm fatpacker.trace
rm packlists

chmod a+x bin/mist
