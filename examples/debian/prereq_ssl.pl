die <<'ERROR' if system('pkg-config --exists libssl');
Could not find pkg-config for libssl
Do you have libssl-dev installed?
ERROR

my $libssl_version = `pkg-config --modversion libssl`;
chomp $libssl_version;
$libssl_version =~ s/[^\d\.].*//;

printf "libssl version ${libssl_version} found\n";

use version;
my $needed_version = qv(0.9.8);
die <<"ERROR" if qv( $libssl_version ) < $needed_version;
libssl-dev version ${libssl_version} is too old, ${needed_version} needed
ERROR

printf "libssl version confirms to requirements\n";
