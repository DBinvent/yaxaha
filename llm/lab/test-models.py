#!/usr/bin/env python3
"""The models of the model service, one by one: health, one real call each with
its answer graded, and llama-server's own timings.

    python3 test-models.py [--ch <ssh target>] [--plain] [name ...]

  name     which models: "default" and the names in llm.env's LLM_MODELS
           (route, ch, ...). Default: all of them.
  --ch     ssh target of a ClickHouse node (clickhouse-client, read-only). The ch
           answer is then also checked there: EXPLAIN AST, and its rows against a
           hand-written query. Without it the statement is checked for shape only.
  --plain  also ask the ch model without the JSON answer shape, to see what its
           explanation costs

What each model is asked (llm2.md §2.4):
  route    categorize: a question and the table lists -> {"tables": [...]}, forced
           by a JSON schema. Graded on the tables; the target is looked up from
           the lists they are in, as the node will do.
  default  PostgreSQL, XiYanSQL's template. Graded on shape.
  ch       ClickHouse SQL -> {"sql": "..."}, forced by a JSON schema. Graded on
           shape, and on ClickHouse with --ch.
  other    health and the model's id only.
The questions are about the lab's data: the shop schema of sample_data.sql, and
the ClickHouse tables default.etcd_events and public.bench_analytics.

Config: llm-client.env next to this script (LLM_URL, LLM_CA, LLM_CLIENT_CERT,
LLM_CLIENT_KEY), with the environment on top, and a path that does not exist is
looked up next to llm-client.env; these are test-yt-llm.sh's rules. Without
llm-client.env, this machine's own service, as ask.py uses it (HF_HOME/ssl, client
'local'). Model names come from LLM_MODELS in llm.env, or in the environment.
YT_SSH is the ssh command for --ch (ssh -o BatchMode=yes ..., with the lab key
when this machine has it).
Prints PASS / FAIL / INFO lines; exit status 0 when nothing FAILed. Standard
library only.
"""
import http.client
import json
import os
import re
import shlex
import ssl
import subprocess
import sys
import time
import urllib.parse

# yt-pgxt's llm/ folder holds the settings: LLM_DIR, else YT_PGXT/llm, else the
# sibling checkout of this repository
_TESTS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.environ.get("LLM_DIR") or os.path.join(
    os.environ.get("YT_PGXT") or os.path.join(os.path.dirname(_TESTS), "yt-pgxt"), "llm")
RESULTS = {"PASS": 0, "FAIL": 0}


def say(kind, label, detail):
    if kind in RESULTS:
        RESULTS[kind] += 1
    print("  %s %s: %s" % (kind, label, detail), flush=True)


def read_env(path):
    """KEY=VALUE lines, `export` and quotes allowed; ${HOME} / $HOME expanded."""
    c = {}
    if not os.path.isfile(path):
        return c
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$", line)
            if m:
                v = m.group(2).strip().strip('"').strip("'")
                c[m.group(1)] = v.replace("${HOME}", os.path.expanduser("~")).replace("$HOME", os.path.expanduser("~"))
    return c


def config():
    env_file = os.environ.get("LLM_CLIENT_ENV") or os.path.join(HERE, "llm-client.env")
    client = read_env(env_file)
    host = read_env(os.path.join(HERE, "llm.env"))
    for k in ("LLM_URL", "LLM_CA", "LLM_CLIENT_CERT", "LLM_CLIENT_KEY", "LLM_MODELS"):
        if os.environ.get(k):
            client[k] = os.environ[k]

    def resolve(p):
        near = os.path.join(os.path.dirname(env_file), os.path.basename(p))
        return p if os.path.isfile(p) else near

    if client.get("LLM_URL"):
        url = client["LLM_URL"]
        ca, crt, key = (resolve(client["LLM_CA"]), resolve(client["LLM_CLIENT_CERT"]),
                        resolve(client["LLM_CLIENT_KEY"]))
    else:
        # this machine's own service, as ask.py
        hf = host.get("HF_HOME") or (r"D:\huggingface" if os.name == "nt" else os.path.expanduser("~/huggingface"))
        ssl_dir = os.path.join(hf, "ssl")
        url = "https://localhost:%s" % host.get("LLM_PORT", "8080")
        ca, crt, key = (os.path.join(ssl_dir, "ca.crt"), os.path.join(ssl_dir, "clients", "local.crt"),
                        os.path.join(ssl_dir, "clients", "local.key"))
    models = client.get("LLM_MODELS") or host.get("LLM_MODELS", "")
    names = [e.split("=", 1)[0].strip() for e in models.split(",") if "=" in e]
    return url, ca, crt, key, names


URL, CA, CRT, KEY, NAMES = config()
TARGET = urllib.parse.urlsplit(URL)
CTX = ssl.create_default_context(cafile=CA)
CTX.load_cert_chain(CRT, KEY)


def request(method, path, body=None):
    """(status, parsed JSON or text, seconds). Generous: a sleeping model loads
    first, and a CPU answer can take minutes."""
    c = http.client.HTTPSConnection(TARGET.hostname, TARGET.port or 443, context=CTX, timeout=900)
    t0 = time.time()
    try:
        c.request(method, path, json.dumps(body) if body is not None else None,
                  {"Content-Type": "application/json"} if body is not None else {})
        r = c.getresponse()
        raw = r.read().decode("utf-8", "replace")
    finally:
        c.close()
    secs = time.time() - t0
    try:
        return r.status, json.loads(raw), secs
    except ValueError:
        return r.status, raw, secs


def ask(prefix, label, prompt, schema=None, sampling=None):
    """One chat call; the answer text, or None when the call failed."""
    body = {"messages": [{"role": "user", "content": prompt}], "max_tokens": 1024}
    body.update(sampling or {"temperature": 0.1, "top_p": 0.8})
    if schema:
        body["response_format"] = {"type": "json_schema",
                                   "json_schema": {"name": "answer", "schema": schema}}
    st, a, secs = request("POST", prefix + "/v1/chat/completions", body)
    if st != 200 or not isinstance(a, dict):
        say("FAIL", label, "HTTP %s after %.1f s: %s" % (st, secs, str(a)[:200]))
        return None
    t = a.get("timings", {})
    say("INFO", label + ".time", "%.1f s: prompt %d tok at %.0f tok/s, answer %d tok at %.1f tok/s" % (
        secs, t.get("prompt_n", 0), t.get("prompt_per_second", 0),
        t.get("predicted_n", 0), t.get("predicted_per_second", 0)))
    return a["choices"][0]["message"]["content"]


# ── the questions, over the lab's data ─────────────────────────────────────────

LISTS = {
    "sql": {  # tables the asking node holds whole (PostgreSQL)
        "shop.customers": "id, name, email, country, created_at",
        "shop.products": "id, name, category, price",
        "shop.orders": "id, customer_id, order_date, status",
        "shop.order_items": "order_id, product_id, quantity, unit_price",
        "public.pgbench_branches": "bid, bbalance, filler",
        "public.pgbench_tellers": "tid, bid, tbalance, filler",
    },
    "ch": {  # ClickHouse
        "default.etcd_events": "id, source, payload, ts",
        "public.bench_analytics": "src_id, bid, amount, note, node_uuid, node_host, node_state, rtt, load, cerr, seen_at",
    },
    "df": {},  # cluster tables not whole here: none on the lab today
}
ROUTE = [
    ("How many etcd events came from each source?", {"default.etcd_events"}),
    ("How many customers are there in each country?", {"shop.customers"}),
    ("What is the average rtt per node host in the bench analytics?", {"public.bench_analytics"}),
]
CH_Q = "How many etcd events came from each source, with the first and the last event time?"
CH_HAND = "SELECT source, count(), min(ts), max(ts) FROM default.etcd_events GROUP BY source"


def lists_text():
    out = []
    for target, tables in LISTS.items():
        out.append("[%s] %s" % (target, {"sql": "tables this database holds whole (PostgreSQL)",
                                        "ch": "ClickHouse tables",
                                        "df": "cluster tables this node does not hold whole"}[target]))
        out += ["- %s: %s" % (t, cols) for t, cols in tables.items()] or ["(none)"]
    return "\n".join(out)


def xiyan(dialect, question, schema_block, reference=""):
    """XiYanSQL's template, the one ytserv's prompt() fills (llm.rs)."""
    return ("You are a %s expert. Read and understand the [Database schema] description below and any "
            "[Reference information] that may be useful, then use your %s knowledge to write an SQL "
            "statement that answers the [User question].\n[User question]\n%s\n\n[Database schema]\n%s"
            "[Reference information]\n%s\n\n[User question]\n%s\n\n```sql"
            % (dialect, dialect, question, schema_block, reference, question))


def sql_of(text):
    m = re.search(r"```(?:sql|postgresql|clickhouse)?\s*(.*?)```", text, re.S | re.I)
    return (m.group(1) if m else text.replace("```sql", "").replace("```", "")).strip().rstrip(";").strip()


# ── per purpose ────────────────────────────────────────────────────────────────

def test_route(prefix, name):
    schema = {"type": "object", "properties": {"tables": {"type": "array", "items": {"type": "string"}}},
              "required": ["tables"], "additionalProperties": False}
    where = {t: target for target, tables in LISTS.items() for t in tables}
    for i, (q, want) in enumerate(ROUTE, 1):
        text = ask(prefix, "%s.q%d" % (name, i),
                   "Pick the tables that answer the question, all from one list.\n" + lists_text()
                   + "\n\nQuestion: " + q, schema, {"temperature": 0})
        if text is None:
            continue
        try:
            got = set(json.loads(text)["tables"])
        except (ValueError, KeyError, TypeError):
            say("FAIL", "%s.q%d" % (name, i), "not the JSON asked for: %s" % text[:200])
            continue
        targets = {where.get(t, "?") for t in got}
        target = targets.pop() if len(targets) == 1 else "mixed" if targets else "none"
        say("PASS" if got == want else "FAIL", "%s.q%d" % (name, i),
            "%s -> tables %s, target %s (want %s)" % (q, sorted(got), target, sorted(want)))


def test_default(prefix, name):
    q = "How many customers are there in each country?"
    block = ("[DB_ID] pgbench\n[Schema]\n# Table: shop.customers\n[\n(id:INTEGER, Primary Key),\n(name:TEXT),\n"
             "(email:TEXT),\n(country:TEXT),\n(created_at:DATE)\n]\n[Foreign keys]\n\n\n")
    text = ask(prefix, name + ".sql", xiyan("PostgreSQL", q, block))
    if text is None:
        return
    sql = sql_of(text)
    ok = re.search(r"\bfrom\s+shop\.customers\b", sql, re.I) and re.search(r"\bgroup\s+by\s+(\w+\.)?country\b", sql, re.I)
    say("PASS" if ok else "FAIL", name + ".sql", " ".join(sql.split())[:200])


def clickhouse(target, query):
    """Run one read-only query on the --ch node; (ok, output)."""
    ssh = os.environ.get("YT_SSH")
    if not ssh:
        ssh = "ssh -o BatchMode=yes -o ConnectTimeout=8"
        key = os.path.expanduser("~/.ssh/lab_cluster_ed25519")
        if os.path.isfile(key):
            ssh += " -o IdentitiesOnly=yes -i " + key
    p = subprocess.run(shlex.split(ssh) + [target, "clickhouse-client --readonly=1"],
                       input=query, capture_output=True, text=True, timeout=300)
    return p.returncode == 0, (p.stdout if p.returncode == 0 else p.stderr).strip()


def rows(tsv):
    """Rows as sorted values, so column order and names do not matter."""
    return sorted("|".join(sorted(line.split("\t"))) for line in tsv.splitlines() if line)


def test_ch(prefix, name, ch_node, plain):
    block = ("[DB_ID] clickhouse\n[Schema]\n# Table: default.etcd_events\n[\n(id:Int32, Sorting Key),\n"
             "(source:String),\n(payload:Nullable(String)),\n(ts:DateTime)\n]\n")
    prompt = xiyan("ClickHouse", CH_Q, block, "default.etcd_events: MergeTree")
    schema = {"type": "object", "properties": {"sql": {"type": "string"}},
              "required": ["sql"], "additionalProperties": False}
    text = ask(prefix, name + ".sql", prompt + "\nAnswer with the statement only.", schema)
    if plain:
        ask(prefix, name + ".plain", prompt)
    if text is None:
        return
    try:
        sql = json.loads(text)["sql"].strip().rstrip(";").strip()
    except (ValueError, KeyError, TypeError):
        say("FAIL", name + ".sql", "not the JSON asked for: %s" % text[:200])
        return
    ok = re.search(r"\bfrom\s+default\.etcd_events\b", sql, re.I) and re.search(r"\bgroup\s+by\s+source\b", sql, re.I)
    say("PASS" if ok else "FAIL", name + ".sql", " ".join(sql.split())[:200])
    if not ch_node:
        return
    good, out = clickhouse(ch_node, "EXPLAIN AST " + sql)
    root = out.splitlines()[0].split(" ")[0] if good and out else out[:160]
    say("PASS" if root == "SelectWithUnionQuery" else "FAIL", name + ".parse", "EXPLAIN AST root %s" % root)
    good, got = clickhouse(ch_node, "SELECT * FROM (%s) FORMAT TSV" % sql)
    ok2, want = clickhouse(ch_node, CH_HAND + " FORMAT TSV")
    if not (good and ok2):
        say("FAIL", name + ".rows", (got if not good else want)[:200])
    else:
        say("PASS" if rows(got) == rows(want) else "FAIL", name + ".rows",
            "%d rows, %s the hand-written query" % (len(rows(got)), "the same as" if rows(got) == rows(want) else "not"))


def main(argv):
    ch_node, plain, wanted = None, False, []
    it = iter(argv)
    for a in it:
        if a == "--ch":
            ch_node = next(it, None)
        elif a == "--plain":
            plain = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            wanted.append(a)
    names = wanted or ["default"] + NAMES
    print("== %s (CA %s, client %s); models: %s" % (URL, os.path.basename(CA), os.path.basename(CRT),
                                                   ", ".join(names)), flush=True)
    for name in names:
        prefix = "" if name == "default" else "/" + name
        print("== " + name, flush=True)
        st, a, _ = request("GET", prefix + "/health")
        say("PASS" if st == 200 and isinstance(a, dict) and a.get("status") == "ok" else "FAIL",
            name + ".health", "HTTP %s %s" % (st, a))
        st, a, _ = request("GET", prefix + "/v1/models")
        if st == 200 and isinstance(a, dict) and a.get("data"):
            say("INFO", name + ".model", os.path.basename(a["data"][0].get("id", "").replace("\\", "/")))
        if name == "route":
            test_route(prefix, name)
        elif name == "default":
            test_default(prefix, name)
        elif name == "ch":
            test_ch(prefix, name, ch_node, plain)
    print("== %d PASS, %d FAIL" % (RESULTS["PASS"], RESULTS["FAIL"]))
    return 1 if RESULTS["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
