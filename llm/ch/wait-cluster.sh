#!/bin/bash
# A ClickHouse node's entrypoint: wait until its yaxaha node has rendered the
# cluster definition (yt_config C clickhouse_cluster, with the inter-server
# secret filled in from module K), link it into config.d, then start ClickHouse
# the way the image does. ClickHouse reloads the file by itself when an edit of
# the row rewrites it.
f=/etc/yaxaha/clickhouse/yt-cluster.xml
echo "[ch] waiting for $f, rendered by ytserv from yt_config"
until [ -s "$f" ]; do sleep 1; done
ln -sf "$f" /etc/clickhouse-server/config.d/yt-cluster.xml
exec /entrypoint.sh "$@"
