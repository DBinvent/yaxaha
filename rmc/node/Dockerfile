# A yaxaha node for the rmc test: PostgreSQL 18, the yaxaha package (the
# extension and ytserv). The same image runs the load client, with its own
# entrypoint (lib.sh load_run), for psql.
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -qy --no-install-recommends \
        postgresql-18 postgresql-client-18 ca-certificates
COPY yaxaha.deb /tmp/yaxaha.deb
# apt, not dpkg -i: the package's dependencies come with it. libexpat1: the
# vendored libpython links it and the package does not depend on it.
RUN apt-get update -q \
    && apt-get install -qy /tmp/yaxaha.deb libexpat1 \
    && rm -f /tmp/yaxaha.deb && rm -rf /var/lib/apt/lists/*
RUN ldconfig \
    && test -x /usr/local/bin/yaxaha/ytserv \
    && ! ldd /usr/local/bin/yaxaha/ytserv | grep -q "not found"
RUN cp /usr/local/include/yaxaha/yaxaha0_5-pg18-glibc2_39.so "$(pg_config --pkglibdir)/yaxaha.so" \
    && cp /usr/local/include/yaxaha/yaxaha.control /usr/local/include/yaxaha/yaxaha--0.5.sql \
          "$(pg_config --sharedir)/extension/"
RUN mkdir -p /var/yaxaha /var/log/yaxaha \
    && chown postgres:postgres /var/yaxaha /var/log/yaxaha
COPY entrypoint.sh /usr/local/bin/node-entrypoint.sh
RUN chmod +x /usr/local/bin/node-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]
