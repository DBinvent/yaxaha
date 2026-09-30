-- Grading helpers for test.sh, created per psql session (pg_temp).
--
-- A result is a SET of rows, each row the sorted list of its values joined by
-- '|': column names, column order and row order do not matter, only the values.
-- The expected rows come from a hand-written query - PostgreSQL's (want_sql) or
-- ClickHouse's TSV output (want_tsv). Every check prints one line,
-- PASS|FAIL <label>.<check>: ..., which test.sh counts.

CREATE FUNCTION pg_temp.want_sql(ref text) RETURNS text[] LANGUAGE plpgsql AS $f$
DECLARE w text[];
BEGIN
    EXECUTE format('SELECT array_agg(s ORDER BY s) FROM (SELECT (SELECT string_agg(v, ''|'' ORDER BY v)
                      FROM json_each_text(row_to_json(t)) x(k, v)) AS s FROM (%s) t) a', ref) INTO w;
    RETURN w;
END $f$;

CREATE FUNCTION pg_temp.want_tsv(tsv text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT array_agg(s ORDER BY s) FROM (
        SELECT (SELECT string_agg(v, '|' ORDER BY v) FROM unnest(string_to_array(line, E'\t')) v) AS s
          FROM unnest(string_to_array(tsv, E'\n')) line WHERE line <> '') a
$f$;

-- A question the node must answer from `engine` (sql, df or ch), with the rows
-- `want`. `note`, when given, must be part of the answer's notes. Three calls:
-- the statement (the model is asked), a page of its rows (the kept statement,
-- not asked again), and yt_llm() typed by that page.
CREATE FUNCTION pg_temp.ask(label text, nl text, engine text, want text[], note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
    t0   timestamptz := clock_timestamp();
    s    json;
    d    json;
    got  text[];
    defs text;
    secs numeric;
BEGIN
    BEGIN
        s := yt_llm_query(nl);
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE 'FAIL %.type: %', label, SQLERRM;
        RETURN;
    END;
    secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
    RAISE NOTICE '%', format('%s %s.type: %s in %s s: %s', CASE WHEN s->>'type' = engine THEN 'PASS' ELSE 'FAIL' END,
        label, s->>'type', secs, replace(s->>'sql', E'\n', ' '));
    IF s->'notes' IS NOT NULL THEN
        RAISE NOTICE 'INFO %.notes: %', label, s->'notes';
    END IF;
    IF s->>'type' IS DISTINCT FROM engine THEN
        RETURN;
    END IF;
    IF note IS NOT NULL THEN
        RAISE NOTICE '%', format('%s %s.note: %s', CASE WHEN coalesce(s->>'notes', '') LIKE '%' || note || '%'
            THEN 'PASS' ELSE 'FAIL' END, label, 'the answer says: ' || note);
    END IF;
    IF engine = 'df' THEN
        RAISE NOTICE '%', format('%s %s.plan: %s table(s), %s partition(s), the script %s',
            CASE WHEN s->>'script' LIKE '%CREATE EXTERNAL TABLE%' AND json_array_length(s->'plan'->'tables') > 0
                 THEN 'PASS' ELSE 'FAIL' END, label, json_array_length(s->'plan'->'tables'),
            (SELECT sum(json_array_length(t->'parts')) FROM json_array_elements(s->'plan'->'tables') t),
            CASE WHEN s->>'script' LIKE '%CREATE EXTERNAL TABLE%' THEN 'registers them' ELSE 'is missing' END);
    END IF;

    t0 := clock_timestamp();
    BEGIN
        d := yt_llm_query(nl, 0, 1000);
        SELECT array_agg(x ORDER BY x) INTO got
          FROM (SELECT (SELECT string_agg(v, '|' ORDER BY v) FROM json_each_text(r) e(k, v)) AS x
                  FROM json_array_elements(d->'data') r) a;
        secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
        IF d->>'type' = 'data' AND d->>'engine' = engine AND got IS NOT DISTINCT FROM want THEN
            RAISE NOTICE 'PASS %.data: % rows read by %, the same as by hand, columns %, % s', label,
                d->>'total_rows', engine, d->'column_names', secs;
        ELSE
            RAISE NOTICE 'FAIL %.data: engine %, % s: got % want %', label, d->>'engine', secs, got, want;
            RETURN;
        END IF;
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE 'FAIL %.data: %', label, SQLERRM;
        RETURN;
    END;

    SELECT string_agg(format('%I %s', n, t), ', ' ORDER BY i) INTO defs
      FROM json_array_elements_text(d->'column_names') WITH ORDINALITY AS a(n, i)
      JOIN json_array_elements_text(d->'column_desc') WITH ORDINALITY AS b(t, j) ON i = j;
    t0 := clock_timestamp();
    BEGIN
        EXECUTE format('SELECT array_agg(s ORDER BY s) FROM (SELECT (SELECT string_agg(v, ''|'' ORDER BY v)
                          FROM json_each_text(row_to_json(t)) x(k, v)) AS s FROM yt_llm($1) AS t(%s)) a', defs)
           INTO got USING nl;
        secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
        RAISE NOTICE '% %.rows: yt_llm(..) AS t(%): % rows, % s', CASE WHEN got IS NOT DISTINCT FROM want
            THEN 'PASS' ELSE 'FAIL' END, label, defs, coalesce(cardinality(got), 0), secs;
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE 'FAIL %.rows: yt_llm(..) AS t(%): %', label, defs, SQLERRM;
    END;
END $f$;

-- A question no target here answers exactly: yt_llm_query must refuse it, and
-- its message must contain `expect`. A refusal is the right answer - never a
-- partial number.
CREATE FUNCTION pg_temp.refused(label text, nl text, expect text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
    t0   timestamptz := clock_timestamp();
    s    json;
    secs numeric;
BEGIN
    s := yt_llm_query(nl);
    RAISE NOTICE 'FAIL %.refused: answered instead (%): %', label, s->>'type', replace(s->>'sql', E'\n', ' ');
EXCEPTION WHEN query_canceled OR others THEN
    secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
    RAISE NOTICE '%', format('%s %s.refused: in %s s: %s', CASE WHEN SQLERRM LIKE '%' || expect || '%'
        THEN 'PASS' ELSE 'FAIL' END, label, secs, SQLERRM);
END $f$;
