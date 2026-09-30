# One yaxaha node of the llm test cluster: PostgreSQL 18, the yaxaha package
# (extension + ytserv + yxctl) and DataFusion for yt_llm's df target.
#
# build.sh stages this directory with the package as yaxaha.deb. Nothing is
# compiled here: the package is built elsewhere, the same rule as a real node.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -qy --no-install-recommends \
        postgresql-18 postgresql-client-18 ca-certificates python3 python3-venv

# `apt-get install ./file.deb`, not `dpkg -i`: the package's Depends (libcurl,
# libpq) are fetched too. libexpat1 is needed by the embedded libpython but is
# not in the Depends. The index is refreshed in this layer, so a cached one
# cannot point at superseded versions.
COPY yaxaha.deb /tmp/yaxaha.deb
RUN apt-get update -q \
    && apt-get install -qy /tmp/yaxaha.deb libexpat1 \
    && rm -f /tmp/yaxaha.deb && rm -rf /var/lib/apt/lists/*
RUN ldconfig \
    && test -x /usr/local/bin/yaxaha/ytserv \
    && ! ldd /usr/local/bin/yaxaha/ytserv | grep -q "not found"

# The extension in PostgreSQL's own directories (on a real node `yxctl --batch`
# copies it); baked in so the three containers share the layer.
RUN cp /usr/local/include/yaxaha/yaxaha0_5-pg18-glibc2_39.so "$(pg_config --pkglibdir)/yaxaha.so" \
    && cp /usr/local/include/yaxaha/yaxaha.control /usr/local/include/yaxaha/yaxaha--0.5.sql \
          "$(pg_config --sharedir)/extension/"

# DataFusion for the df target: a venv of its own (C llm_df_python). ytserv
# copies the rows out itself; this python only computes.
COPY requirements.txt /opt/llm-df/requirements.txt
RUN python3 -m venv /opt/llm-df \
    && /opt/llm-df/bin/pip install -q --no-cache-dir --disable-pip-version-check -r /opt/llm-df/requirements.txt \
    && /opt/llm-df/bin/python -c "import datafusion, pyarrow; print('datafusion', datafusion.__version__, 'pyarrow', pyarrow.__version__)"

# the cluster WAL, the log, and the ClickHouse cluster file ytserv renders
RUN mkdir -p /var/yaxaha /var/log/yaxaha /etc/yaxaha/clickhouse \
    && chown postgres:postgres /var/yaxaha /var/log/yaxaha

COPY entrypoint.sh /usr/local/bin/node-entrypoint.sh
RUN chmod +x /usr/local/bin/node-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]
