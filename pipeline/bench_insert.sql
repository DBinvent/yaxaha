-- pgbench driver: one INSERT per transaction into the table that
-- on_commit_python is armed on.
\set bid random(1, 10)
\set amount random(1, 1000)
BEGIN;
INSERT INTO public.bench_src (bid, amount, note) VALUES (:bid, :amount, 'pgbench');
END;
