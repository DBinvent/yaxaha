# [topology] One cluster node: PostgreSQL 18 + the yaxaha extension + ytserv.
#
# Docker rather than LXC, measured on the docker host: ~60 MB/node here against ~70 MB for
# an LXC container running only systemd, before PostgreSQL. A system container
# buys an init system this test does not want - ytserv is started directly - and
# on a host that also runs Docker it needs the macvlan workaround from
# ../lxc/env.sh, because Docker's FORWARD DROP policy cuts lxdbr0 off.
# ## 24.04, not 26.04 - the deb requires python 3.12
#
# `Depends: libpython3.12-stdlib`. ytserv links `libpython3.12.so.1.0` (pyo3,
# baked in at build time on a 24.04 dev host), and `Py_Initialize` looks for a
# stdlib at the version-stamped `/usr/lib/python3.12` - a 3.14 stdlib cannot
# serve a 3.12 core, since its extension modules are named
# `*.cpython-314-*.so` and the C ABI and .pyc magic differ. Ubuntu 26.04 ships
# python 3.14 and nothing older, so the deb does not install there at all and
# server functions could never run. 24.04 has 3.12, which is also what the
# binary is built against.
#
# The cost is PostgreSQL: 24.04's archive stops at PG16, so 18 comes from PGDG.
# Same package layout (/usr/lib/postgresql/18, /etc/postgresql/18/main), so
# node-entrypoint.sh is unchanged.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# git + openssh-client: `rppd_git::materialize` and rdbm's `source_git` SHELL OUT
#   to git, so without them a git-sourced function or migration fails with
#   "is git installed and on PATH?" - and neither had ever been exercised here.
# iproute2: the split-brain and partition tests cut a node off at the network.
RUN apt-get update -q && apt-get install -qy --no-install-recommends \
        ca-certificates curl gnupg git openssh-client iproute2 \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update -q \
    && apt-get install -qy --no-install-recommends postgresql-18 postgresql-client-18 \
        libpython3.12-stdlib python3-psycopg2 python3-etcd3 python3-pip
# The python the server functions run in is ytserv's embedded 3.12, and it reads
# the same dist-packages as /usr/bin/python3:
# - psycopg2 and etcd3: rppd imports both for every function context (`DB`,
#   `ETCD`), so without either nothing on_commit_python runs at all - 92, 92c, 94
#   and 98_mpp_df all failed on "No module named 'psycopg2'", then 'etcd3',
#   before a single assertion meant anything.
# - clickhouse_connect (94's `CH` binding) and ballista (98_mpp_df, a 58 MB
#   wheel): the scripts still install them when missing, but doing it once here
#   keeps a slow or failing pip out of the suite. Its own layer, above the deb,
#   so a new build does not fetch them again.
RUN pip3 install --quiet --no-cache-dir --break-system-packages clickhouse_connect ballista \
    && python3 -c 'import psycopg2, etcd3, clickhouse_connect, ballista'

# The deb is built on the dev host and carries yxctl, ytserv, the PG18 .so and
# the vendored libpython. Nothing is compiled in here - same rule as a real node.
#
# `apt-get install ./file.deb`, not `dpkg -i`: the deb's Depends name libcurl4
# and libpq-dev, and dpkg cannot pull them - it unpacks, fails, and the follow-up
# `apt -f install` REMOVES the package again, leaving an image that builds
# cleanly and contains nothing.
COPY yaxaha.deb /tmp/yaxaha.deb
# libexpat1 is NOT in the deb's Depends but the vendored libpython3.12 links it,
# so ytserv exits 127 at startup on a minimal image. A real node happens to have
# it pulled in by something else; a container has only what is asked for.
# `apt-get update` again, in THIS layer. The update above it is a cached layer, so
# once upstream supersedes any dependency the cached index still names the old
# version and the fetch 404s - measured: `libcurl4t64_8.18.0-1ubuntu2.5 404 Not
# Found`, on an image that had built fine for weeks. The layer that installs must
# refresh the index it installs against, or the build has a silent expiry date.
RUN apt-get update -q \
    && apt-get install -qy /tmp/yaxaha.deb libexpat1 \
    && rm -f /tmp/yaxaha.deb && rm -rf /var/lib/apt/lists/*
# The python stdlib the deb now REQUIRES has to actually be there, or server
# functions fail at the first dispatch with `init_fs_encoding` - which is the
# whole reason for the dependency. Fail the build instead.
RUN test -f /usr/lib/python3.12/encodings/__init__.py
# Fail the BUILD, not the first test run, if anything is still unresolved.
RUN ldconfig \
    && test -f /usr/local/bin/yaxaha/ytserv \
    && ! ldd /usr/local/bin/yaxaha/ytserv | grep -q "not found"

# The extension has to sit in PostgreSQL's own directories; on a real node
# `yxctl --batch` does this copy. Here it is baked into the image so N
# containers share the layer.
RUN cp /usr/local/include/yaxaha/yaxaha0_5-pg18-glibc2_39.so \
       "$(pg_config --pkglibdir)/yaxaha.so" \
    && cp /usr/local/include/yaxaha/yaxaha.control \
          /usr/local/include/yaxaha/yaxaha--0.5.sql \
       "$(pg_config --sharedir)/extension/"

# The cluster WAL directory. pg_basebackup does not copy it and neither does
# any package - on a real node `yxctl --batch` creates it, so a container has to
# do the same or ytserv exits 16 on first write.
RUN mkdir -p /var/yaxaha /var/log/yaxaha \
    && chown postgres:postgres /var/yaxaha /var/log/yaxaha

COPY node-entrypoint.sh /usr/local/bin/node-entrypoint.sh
COPY pg_setup.sql /opt/pg_setup.sql
RUN chmod +x /usr/local/bin/node-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]
