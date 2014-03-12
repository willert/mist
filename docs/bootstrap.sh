# Run this from project root if you ever have to rebuild Mists own mpan-dist :

mv mpan-dist mpan-dist.pre-bootstrap
mv perl5 perl5.pre-bootstrap

./mpan-install --reinstall --cascade-search --mirror http://www.cpan.org/ --notest --save-dists mpan-dist
mist index
