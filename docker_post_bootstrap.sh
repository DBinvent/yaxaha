#!/bin/bash
set -Eeu

PGBIN=$(pg_config --bindir)
sudo su -c "$PGBIN/createuser -d -s rust" postgres || true
sudo su -c "$PGBIN/createdb -O rust rust" postgres || true

psql -c "create extension ytpgxt; select * from public.yt_info('o');"

echo "try check more on psql with 'select * from yt_help_with_defaults;'"
echo
echo "to run integration tests type: cd && cargo make"

if [ $# -gt 1 ]; then
 $@
fi

bash
