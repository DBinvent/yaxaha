-- bench/cluster/digest.sql — BENCH.md §5. Run on every node; compare.
-- search_path must include the schema holding pgbench_* (default: public).
--
-- Line format (psql -tAF'|'):
--   <rel>|<count>|<sum>|<md5>
--   INVARIANT|<accounts>|<branches>|<tellers>|<history>
-- The four INVARIANT values must be equal on a node (pgbench's TPC-B
-- property) and every <rel> line must match the reference node.

SELECT 'accounts' AS rel, count(*)::text, coalesce(sum(abalance),0)::text,
       md5(coalesce(string_agg(md5(aid || ':' || abalance), '' ORDER BY aid), ''))
  FROM pgbench_accounts
UNION ALL
SELECT 'branches', count(*)::text, coalesce(sum(bbalance),0)::text,
       md5(coalesce(string_agg(md5(bid || ':' || bbalance), '' ORDER BY bid), ''))
  FROM pgbench_branches
UNION ALL
SELECT 'tellers', count(*)::text, coalesce(sum(tbalance),0)::text,
       md5(coalesce(string_agg(md5(tid || ':' || tbalance), '' ORDER BY tid), ''))
  FROM pgbench_tellers
UNION ALL
SELECT 'history', count(*)::text, coalesce(sum(delta),0)::text,
       md5(coalesce(string_agg(md5(mtime || tid || bid || aid || delta), ''
                    ORDER BY mtime, tid, bid, aid, delta), ''))
  FROM pgbench_history
UNION ALL
SELECT 'INVARIANT',
       (SELECT coalesce(sum(abalance),0) FROM pgbench_accounts)::text,
       (SELECT coalesce(sum(bbalance),0) FROM pgbench_branches)::text,
       (SELECT coalesce(sum(tbalance),0) FROM pgbench_tellers)::text,
       (SELECT coalesce(sum(delta),0)    FROM pgbench_history)::text;
