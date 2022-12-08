# YaXAHA Cluster Integration Tests

We run our tests on Debian-based Linux distributions and can’t give any promises about the compatibility with many other versions and distros, except for those we use ourselves in development now. Last tests were made on Ubuntu 22.10 and Debian 11.

YaXAHA Cluster is written in Rust and out of habit we use cargo-make in the integration tests.

## Preparations

This instruction assumes that you have _sudo_ command installed and there is a sudo user in your system. If you have a fresh system installed, no sudo command, or no sudo user in the system, additional steps will be required.

Make sure the _sudo_ command is installed. Under _root_ user, run:

```shell
apt install -y sudo
```

Then create a new user and add it to the sudo group.

```shell
adduser username
adduser username sudo
```

After the log-in with the user created, you can copy-and-paste commands from the next steps and everything should go nice and smooth. To log in with the user created, please run:

```shell
su - username
```

Before you can start YaXAHA Cluster Integration Tests, you'll need to install [PostgreSQL](https://www.postgresql.org/download/linux/debian/) server with psql frontend, Rust, cargo-make tool with several dependencies and a few utilities we have adopted in the test scripts. Please run the following command:

```shell
sudo apt update && sudo apt install -y build-essential curl git uuid lsb-release postgresql
```

Now we can install Rust. To save time, we took the instructions from https://rustup.rs for supported Linux distributions. Run the following command:

```shell
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

![Installing Cargo](https://github.com/DBinvent/yaxaha/blob/main/images/cargo-installation.jpg?raw=true)

Before Rust will be installed, the script will ask you to specify the settings. Default settings should be OK, you can press ```Enter``` here.

![Configuring the current shell](https://github.com/DBinvent/yaxaha/blob/main/images/configure-shell-for-cargo.jpg?raw=true)

After Rust is installed, we need to configure current shell:

```shell
source "$HOME/.cargo/env"
```

In our last preparation step we need to install the _cargo-make_ tool that we heavily use in testing.

```shell
cargo install cargo-make
```

Now, everything is ready for the YaXAHA Cluster installation and running the integration tests.

## Installing YaXAHA Cluster

Please download and install the public signing key:

```shell
wget -O - https://www.dbinvent.com/dist/DBinventLLC.gpg.key | sudo apt-key add -
```

Add our repository to your sources.list:

```shell
echo "deb http://apt.dbinvent.com/focal focal non-free" > sudo /etc/apt/sources.list.d/dbinvent.list
```

Install the YaXAHA Cluster package:

```shell
sudo apt update && sudo apt install yaxaha
```

Then run ytsetup to install the PostgreSQL extension and finally enable YaXAHA Cluster.

```shell
sudo ytsetup
```

And now we are ready to perform the YaXAHA Cluster integration tests.

## Running the tests

Clone the repository:

```shell
git clone https://github.com/DBinvent/yaxaha.git
```

Then cd into the yaxaha directory.

```shell
cd yaxaha
```

Now you can run an integration test that will locally create three copies of PostgreSQL, run them on different ports as if they were three independent cluster nodes, then run some tests and shut down all nodes.

> Note: the `PG_VER` parameter specifies the PostgreSQL version installed. Different Linux distributions have different PostgreSQL versions onboard, for example, Debian 11 comes with PostgreSQL v.13, while Ubuntu 22.10 comes with v.14.

To run several nodes in parallel:

```shell
cargo make --env PG_VER=14 --env CNT=3
```

To run an individual node with ID=$NODE_ID and psql:
```shell
cargo make --makefile node.toml --env NID=$NODE_ID --env psql=1
```

To run a single node with ID=1 and psql:
```shell
cargo make --makefile node.toml --env NID=1 --env psql=1 --env CNT=1 --env INIT=it_init_single.sql
```

### Running manually

You can also play around with the tests, make changes to the scripts, and run the tests manually. For example, you can change the debug level in the `it_init.sql` file.

In general, the script are executed in the following order:

1. `it_init.sql`
2. `it_preparetest.sql`
3. `it_test.sql`

In three consoles, start a node with different `NID` by executing the following commands:

```shell
cargo make --env PG_VER=14 --makefile node.toml --env psql=1 --env YTSERV_BIN=$(./ytserv_locator.sh) --env NID=1
```
```shell
cargo make --env PG_VER=14 --makefile node.toml --env psql=1 --env YTSERV_BIN=$(./ytserv_locator.sh) --env NID=2
```
```shell
cargo make --env PG_VER=14 --makefile node.toml --env psql=1 --env YTSERV_BIN=$(./ytserv_locator.sh) --env NID=3
```

As a result, you should get the following:

- No ERROR messages when nodes have been started.
- You’ll get the node configuration listed in a table-like representation and a psql command line prompt.
- One of the consoles will display its node Leader status:
    ```
    cluster   | E  	| Term: 3, for 6sec., Leader
    ```
  
    While others will display the leader address and port:
    ```
    cluster   | E  	| Term: 3, for 6sec., Leader: 6e..65316e:127.0.0.1:28771
    ```

You can query current cluster state by running:
```
select * from json_to_recordset(yt_info('E')) as x(name text, module text, value text);
```
  
Now, you can run any SQL queries you like on one node and see how it affects the other nodes.

#### Playing with cluster

After you managed to successfully start three nodes of the cluster in the previous section, you can execute any SQL queries you like. [YaXAHA Cluster](https://dbinvent.local/cluster/) does not have a dedicated master node, so you can start on any node.

You can also execute an existed SQL script, for example, try running a simple test:

```
\i it_test.sql
```

Below is an example of a transaction. Here we will not go into details on how the cluster works, but basically every transaction in the cluster looks like this. On the transaction initiator node, simulate the following transaction:

```
begin;
insert into yt_config(name, value) values ('test0', 'test10');
select yt.yt_complete(true);
commit;
```

Now, check the result on other cluster nodes:

```
select * from yt_config where value = 'test10';
```

To stop a node, run this in the PostgreSQL command prompt:

``` 
\q
```

#### If something goes wrong

To abort tests, run:

```
cargo make killall
```

### Docker

If you have Docker installed, you can play around with tests in a container without messing up the system. In order to deploy the container with these tests, run:
```shell
./docker.sh
```
