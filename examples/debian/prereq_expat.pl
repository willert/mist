
my $compile = qq{cc -x c -o ${workspace}/expat.out - 2>/dev/null};
die <<'ERROR' if system( q{echo '} . <<'CSOURCE' . qq{'| $compile });
Can't find expat header files
Do you have libexpat-dev installed?
ERROR
#include "expat.h"
void main(){}
CSOURCE

unlink "${workspace}/expat.out";

printf "libexpat header files found\n";
