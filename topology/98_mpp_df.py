# [mpp] The analytic, driven from a server function, executed by DataFusion.
#
# Runs inside ytserv's embedded python (rppd), triggered by on_commit_python.
# `DF` is bound by rppd only when `datafusion_url` is set AND the `ballista`
# package imports AND the scheduler answers - so the first thing recorded is
# whether it is bound at all, because an unbound DF is silent otherwise.
#
# ## Why this is written as straight-line code with no helper function
#
# rppd execs the body as `py.run(code, None, Some(&locals))` (`py.rs`): globals
# is None and locals is a separate dict. Every top-level assignment here lands
# in locals, and a nested `def` or `lambda` resolves its free names through
# GLOBALS - so it never sees anything assigned above it and raises NameError.
# Verified: `exec("x=5\ndef f(): return x\nf()", g, l)` -> NameError. A trivial
# `def put(stage, value)` wrapper around the sink INSERT therefore failed on its
# first call, and because the except-handler called the same wrapper, the
# function completed with an empty sink, no output and no error row - success,
# to anything looking at rppd_function_log.
#
# So: no helper functions, and where a callable is unavoidable (the thread pool)
# every name it needs is bound as a DEFAULT ARGUMENT, which is evaluated at def
# time in this frame and does work. Comprehensions are safe on python 3.12
# (they are inlined) but are avoided below anyway where the body reads a local.
#
# Each stage is inserted and committed as it happens, so a hang halfway still
# leaves a readable trail.
import json
import os
from concurrent.futures import ThreadPoolExecutor

TBL = "public.mp_t"
PARTS = 4
INS = "insert into df_sink (stage, value) values (%s,%s)"

cur = DB.cursor()

try:
    ctx = None
    try:
        ctx = DF
    except NameError:
        ctx = None
    cur.execute(INS, ("df_bound", "yes" if ctx is not None else "no"))
    DB.commit()

    if ctx is not None:
        # DataFusion answers at all, before anything depends on it.
        probe = ctx.sql("select 41+1 as a").collect()[0].column(0)[0].as_py()
        cur.execute(INS, ("df_probe", str(probe)))
        DB.commit()

        # The layout ytserv hands a planner, read from INSIDE the function:
        # that is the point of the surface - a server function is a planner too.
        # psycopg2 registers a json/jsonb typecaster, so yt_info() arrives as a
        # python list ALREADY PARSED - `json.loads` on it raises "the JSON object
        # must be str, bytes or bytearray, not list". The per-row `value` below
        # is a text field inside that JSON, so it does still need parsing.
        cur.execute("select yt_info('p:%s/%d')" % (TBL, PARTS))
        raw = cur.fetchone()[0]
        if isinstance(raw, (str, bytes, bytearray)):
            rows = json.loads(raw)
        else:
            rows = raw
        numbered = []
        for r in rows:
            if ".part." in r["name"]:
                numbered.append((int(r["name"].rsplit(".", 1)[1]), json.loads(r["value"])))
        numbered.sort()
        where = []
        for _n, d in numbered:
            where.append(d.get("where") or "true")
        cur.execute(INS, ("partitions", str(len(where))))
        DB.commit()

        cur.execute("select coalesce(sum(amount),0) from " + TBL)
        whole = cur.fetchone()[0]
        cur.execute(INS, ("pg_whole", str(whole)))
        DB.commit()

        # Materialise each partition as a CSV and register it as its own
        # DataFusion table.
        #
        # NOT `ctx.from_pydict`: that builds an IN-MEMORY table, and Ballista has
        # to serialise the logical plan to hand it to an executor, which fails
        # with "Error serializing custom table ... LogicalExtensionCodec is not
        # provided". A distributed engine needs a source its executors can
        # resolve for themselves - which is the real constraint on this whole
        # design, not a quirk of the python binding.
        #
        # `copy_expert` writes client-side, so it needs no server file
        # privileges; 0644 because the scheduler and executor run as a different
        # user in the same container.
        #
        # Sequential on purpose: the extract is not the subject, and a shared
        # psycopg2 connection serialises it anyway - which keeps the parallel
        # section below purely DataFusion.
        counts = []
        i = 0
        for w in where:
            path = "/tmp/mpp_p%d.csv" % i
            fh = open(path, "w")
            cur.copy_expert(
                "COPY (select id, amount from %s where %s) TO STDOUT WITH CSV HEADER"
                % (TBL, w),
                fh,
            )
            fh.close()
            os.chmod(path, 0o644)
            n = 0
            fh = open(path)
            for _line in fh:
                n += 1
            fh.close()
            counts.append(str(n - 1))  # less the header
            ctx.register_csv("p%d" % i, path)
            i += 1
        cur.execute(INS, ("part_rows", ",".join(counts)))
        DB.commit()

        # The MPP shape: one partial per partition, all in flight at once, each
        # executed by the Ballista scheduler rather than by PostgreSQL.
        # `ctx` comes in as a default argument - see the note at the top.
        def partial(n, ctx=ctx):
            return (
                ctx.sql("select coalesce(sum(amount),0) as s from p%d" % n)
                .collect()[0]
                .column(0)[0]
                .as_py()
            )

        pool = ThreadPoolExecutor(max_workers=max(1, len(where)))
        futs = []
        for n in range(len(where)):
            futs.append(pool.submit(partial, n))
        vals = []
        for f in futs:
            vals.append(f.result())
        pool.shutdown()

        shown = []
        total = 0
        for v in vals:
            shown.append(str(v))
            total += v
        cur.execute(INS, ("df_partials", ",".join(shown)))
        cur.execute(INS, ("df_combined", str(total)))
        DB.commit()
except Exception as e:
    # Straight-line, for the same reason as everything above.
    cur.execute(INS, ("error", "%s: %s" % (type(e).__name__, e)))
    DB.commit()
    raise
