die <<"ERROR" if system("mysql_config --version") < 0;
Could not run mysql_config [$!]
Do you have libmysqlclient-dev installed?
ERROR

printf "Mysql client found\n";
