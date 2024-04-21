export PERLBREW_ROOT='/opt/perl5'
curl -L https://install.perlbrew.pl | sudo -E bash
sudo -E SHELL=/bin/bash /opt/perl5/bin/perlbrew init
source /opt/perl5/etc/bashrc
sudo -E /opt/perl5/bin/perlbrew install perl-5.20.3
sudo -E /opt/perl5/bin/perlbrew install-cpanm
sudo -E /opt/perl5/bin/perlbrew exec -q --with perl-5.20.3 /opt/perl5/bin/cpanm --reinstall -v local::lib

sudo adduser --quiet --system mist

sudo rm -Rf /opt/perl5/mist &&
  sudo git clone -b master --depth 1 --single-branch \
    https://github.com/willert/mist.git /opt/perl5/mist &&
  sudo rm -rf /opt/perl5/mist/.git/ && (
    cd /opt/perl5/mist &&
    sudo mkdir -p perl5 &&
    sudo chown mist perl5 &&
    sudo -u mist SHELL=/bin/bash ./mpan-install &&
    sudo rm -f /usr/local/bin/mist &&
    sudo ln -s /opt/perl5/mist/perl5/script/mist /usr/local/bin/
  )
