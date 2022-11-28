
FROM ubuntu:20.04

ARG TOOLCHAIN=stable

ARG ZLIB_VERSION=1.2.13
ARG POSTGRESQL_VERSION_MAJOR=14

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    export DEBIAN_FRONTEND=noninteractive && \
    apt-get install -yq systemd systemd-sysv dbus dbus-user-session \
        libpq-dev libssl-dev linux-libc-dev xutils-dev libevent-dev libreadline-dev zlib1g-dev  \
        curl file git pkgconf sudo flex bison build-essential cmake libc6-i386 libtool uuid && \
    apt-get clean && \
    useradd rust --user-group --create-home --shell /bin/bash --groups sudo

RUN echo "deb http://apt.postgresql.org/pub/repos/apt focal-pgdg main" > /etc/apt/sources.list.d/pgdg.list
RUN curl -o ACCC4CF8.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
RUN apt-key add ACCC4CF8.asc

RUN apt-get update
RUN apt-get install -yq postgresql-$POSTGRESQL_VERSION_MAJOR postgresql-client-$POSTGRESQL_VERSION_MAJOR

ENV RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PATH=/home/rust/.cargo/bin:/opt/rust/cargo/bin:/usr/local/musl/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN curl https://sh.rustup.rs -sSf | \
    env CARGO_HOME=/opt/rust/cargo \
        sh -s -- -y --default-toolchain $TOOLCHAIN --profile minimal --no-modify-path && \
    env CARGO_HOME=/opt/rust/cargo \
        rustup component add rustfmt


RUN curl -o DBinventLLC.gpg https://www.dbinvent.com/dist/DBinventLLC.gpg.key
RUN apt-key add DBinventLLC.gpg

RUN echo "deb http://apt.dbinvent.com/focal focal non-free" > /etc/apt/sources.list.d/dbinvent.list

RUN apt-get update && apt-get install -yq yaxaha


# Allow sudo without a password.
ADD sudoers /etc/sudoers.d/nopasswd

RUN env CARGO_HOME=/opt/rust/cargo cargo install cargo-make


RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2777 /var/run/postgresql

ENV PGDATA /var/lib/postgresql/data

RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 777 "$PGDATA"
VOLUME /var/lib/postgresql/data

COPY pg_hba.conf $PGDATA/pg_hba.conf
RUN sed s/peer/trust/ -i /etc/postgresql/$POSTGRESQL_VERSION_MAJOR/main/pg_hba.conf

USER rust
ENV USER=rust

WORKDIR /home/rust
