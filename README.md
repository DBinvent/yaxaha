# YaXAHA Cluster Integration Tests

## Preparations

Before you can start YaXAHA Cluster Integration Tests, you'll need to install [PostgreSQL](https://www.postgresql.org/download/linux/debian/) server with psql frontend, [cargo-make](https://github.com/sagiegurari/cargo-make) tool with several dependencies and a few utilities we have adopted in the test scripts. Please run the following command:

```shell
sudo apt install -y build-essential curl git uuid
```

Now we can install Rust. To save time, we took the instructions from https://rustup.rs, for officially supported Linux distributions, execute the following command:

```shell
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```



Required cargo (rust) and cargo-make

https://rustup.rs/

```shell
cargo install cargo-make 
```

Get the yaxaha versino from dbinvent.com and unpack to current directory.


Run the cluster with postgres and ytserver.
The postgres binary use from system installed. The postgres DB use one at cluster/nodeX folder.

Run few nodes in parallel:
```shell
cargo make --env PG_VER=14 --env CNT=3
```

Run individual node with ID=$NODE_ID and psql:
```shell
cargo make --makefile node.toml --env NID=$NODE_ID --env psql=1
```

Run single node with ID=1 and psql:
```shell
cargo make --makefile node.toml --env NID=1 --env psql=1 --env CNT=1 --env INIT=it_init_single.sql
```


## AUTO RUN:

Run all nodes on single console and run all test scenarios. 
- `cargo make`


If failed then run:
- `cargo make killall`


## MANUAL RUN:

Execution order:

1. it_init.sql
2. it_preparetest.sql
3. it_test.sql -- runs only on NODE=1


0. edit `it_init.sql` if want to change debug level and nodes 
1. build on /tests/ `cargo make build`
2. run on three console tabs:
   1.  `cargo make --makefile node.toml --env psql=1 --env NID=1`
   2.  `cargo make --makefile node.toml --env psql=1 --env NID=2`
   3.  `cargo make --makefile node.toml --env psql=1 --env NID=3`

 - Must not ERROR
 - One should have 'Cluster got a new leader', while others: 'confirmed_to_term'
 - you have psql
 - you can check with:
 `select * from json_to_recordset(yt.yt_info('E')) as x(name text, module text, value text);`
 - should have 'cluster': end with 'Leadr' and T:1 (term)

### Now cluster is ready

3. Run on one: `begin; insert into yt_config(name, value) values ('test0', 'test10');`
4. `select yt.yt_complete(true);`
5. `commit;`
6. check on others: `select * from yt_config where value = 'test10';`

7. to stop yt&pg servers type: `\q` 
