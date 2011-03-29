
die <<'ERROR' if system('pkg-config --exists libxml-2.0');
Could not find pkg-config for libxml
Do you have pkg-config and libxml2-dev installed?
ERROR
