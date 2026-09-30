-- bench/stream.sql — one data stream per node (BENCH.md §2)
--
-- Each node owns a disjoint key range, so the only cross-node work is
-- replication. pgbench's built-in tpcb-like cannot be used here: every
-- transaction updates pgbench_branches, and at -s 1 that is one row, so N
-- nodes would be measuring conflict resolution and could not scale by
-- construction.
--
--   pgbench -f bench/stream.sql -D node=<n> -D nodes=<N> -D scale=<s> ...
--
-- Run it against the S1 baseline too, with -D node=1 -D nodes=1, or the
-- baseline is executing a different workload than the cluster.
-- Requires -s (scale) >= nodes * 10 so every node owns at least 10 branches.
\set branches_per_node  (:scale / :nodes)
\set tellers_per_node   (10 * :scale / :nodes)
\set accounts_per_node  (100000 * :scale / :nodes)

\set bid random((:node - 1) * :branches_per_node + 1, :node * :branches_per_node)
\set tid random((:node - 1) * :tellers_per_node  + 1, :node * :tellers_per_node)
\set aid random((:node - 1) * :accounts_per_node + 1, :node * :accounts_per_node)
\set delta random(-5000, 5000)

BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
UPDATE pgbench_tellers  SET tbalance = tbalance + :delta WHERE tid = :tid;
UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime)
     VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
END;
