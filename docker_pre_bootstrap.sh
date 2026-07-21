#!/bin/bash
set -Eeu

sudo mkdir -p /var/log/yaxaha/
sudo chmod a+rw /var/log/yaxaha

sudo apt-get update
echo "refresh yaxaha..."
sudo apt-get install --only-upgrade yaxaha
sudo localedef -i en_US -f UTF-8 en_US.UTF-8

sudo service postgresql start # required for ytsetup

echo
echo "Please ignore errors as of systemctl is not working on Docker, and the final"
echo "self-test failing since YtServ isn't actually running until docker_bootstrap.sh does"
echo

sudo /usr/local/bin/yxctl-glibc2_35 --batch -v -s -g $(pwd)/pgbouncer.ini --docker_bootstrap ./docker_bootstrap.sh || true

echo "\$@" | sudo tee -a ./docker_bootstrap.sh > /dev/null
echo
echo "Restarting Postgres to activate YtServ configuration..."
echo

sudo service postgresql restart || bash # activate yt.node


$@
