# creating a `mist` user to install the local lib
# in case you want to deploy as root

id mist >/dev/null 2>&1 || # if no mist user exists
  useradd -s /bin/false -d /nonexistent mist
mkdir -p perl5
chgrp -R mist perl5
chmod -R g+rwX perl5
sudo -H -u mist ./mist-install 

