
FROM ubuntu:20.04

ARG TOOLCHAIN=stable

ARG ZLIB_VERSION=1.2.13
ARG POSTGRESQL_VERSION_MAJOR=14

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    export DEBIAN_FRONTEND=noninteractive && \
    apt-get install -yq systemd systemd-sysv dbus dbus-user-session \
        libpq-dev libssl-dev linux-libc-dev xutils-dev libevent-dev libreadline-dev zlib1g-dev  \
        curl file git pkgconf sudo flex bison build-essential cmake libc6-i386 libtool uuid vim && \
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

RUN env CARGO_HOME=/opt/rust/cargo cargo install cargo-make

RUN curl -o DBinventLLC.gpg https://www.dbinvent.com/dist/DBinventLLC.gpg.key
RUN apt-key add DBinventLLC.gpg

RUN echo "deb http://apt.dbinvent.com/focal focal  non-free" > /etc/apt/sources.list.d/dbinvent.list

RUN date >/build-date.txt

RUN apt-get update && apt-get install -yq yaxaha


# Allow sudo without a password.
ADD sudoers /etc/sudoers.d/nopasswd

RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2777 /var/run/postgresql

ENV PGDATA /var/lib/postgresql/data

RUN sed s/peer/trust/  -i /etc/postgresql/$POSTGRESQL_VERSION_MAJOR/main/pg_hba.conf

RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 777 "$PGDATA"

VOLUME /var/lib/postgresql/data

USER postgres
#RUN localedef -i en_US -f UTF-8 en_US.UTF-8

ADD pgbouncer.ini /etc
ADD userlist.txt /etc

RUN ls /etc/postgresql/14/main

#ENV PGBIN /usr/lib/postgresql/$POSTGRESQL_VERSION_MAJOR/bin
#RUN $PGBIN/initdb &&\
# $PGBIN/pg_ctl start &&\
# $PGBIN/createuser -d -s rust &&\
# $PGBIN/createdb -O rust rust &&\
# sudo ytsetup -v -s -g /etc/pgbouncer.ini --pg_config /etc/postgresql/14/main/postgresql.conf --docker_bootstrap ./docker_bootstrap.sh

COPY pg_hba.conf $PGDATA/pg_hba.conf

USER rust
ENV USER=rust

WORKDIR /home/rust
ADD docker_bootstrap.sh /home/rust
ADD docker_pre_bootstrap.sh /home/rust
ADD docker_post_bootstrap.sh /home/rust

ENTRYPOINT ["/home/rust/docker_pre_bootstrap.sh", "/home/rust/docker_bootstrap.sh", "/home/rust/docker_post_bootstrap.sh"]
CMD ["bash"]
