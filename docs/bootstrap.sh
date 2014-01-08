# Run this from project root if you ever have to rebuild Mists own mpan-dist :

mkdir mpan-dist
cp share/cmd-wrapper.bash mpan-dist
./mpan-install --cascade-search --mirror http://www.cpan.org/ --notest --save-dists mpan-dist
