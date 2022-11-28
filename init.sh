#!/bin/bash
set -Eeu

# simulate sysctl and systemd
sudo service postgresql start
# prepare postgres
psql -U postgres -c "create user rust with superuser" postgres || true
psql -U postgres -c "create database rust" postgres || true

# prepare YTserv
sudo ytsetup -v

sudo service postgresql restart

echo "Starting cluster Integration test with default parameters..."

# use cargo make to run processes conditionally in background
USER=rust cargo make && echo "Integration test completed successfully!"

echo "Starting interactive shell. type 'exit' when done"

bash
