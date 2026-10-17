#!/usr/bin/env bash
# [otel] OpenTelemetry out of ytserv (yt-pgxt resilience.md, phases 0 and 3): an
# OpenTelemetry Collector on the fixture's network receives what the nodes export
# once `open_telemetry` is on with an `open_telemetry_uri`.
#
# The collector prints everything it receives (the `debug` exporter, detailed),
# and this script reads that output - spans with their trace and parent ids and
# their node's `service.instance.id`, and metric names.
#
# ## What is asserted
#
# O1 the nodes export spans: `yt.tx` - a cluster transaction's root, opened on
#    its origin at the first statement - under service.name ytserv
# O2 one transaction is one trace across nodes: a peer's span of the
#    transaction's statement or commit (`modify`, `commit`) is a child in the
#    origin's `yt.tx` trace, from another node
# O3 metrics are pushed (otel_metrics_sec): yt.term, yt.leader, yt.peer.rtt,
#    yt.queue.depth, yt.tx.duration
# O4 the embedded rppd's instruments go on the same meter (rppd.contexts)
# O5 the pipeline trace (phase 4): the table is on_commit_python, and the rppd
#    function the commit fired is a span in the transaction's yt.tx trace
# O6 ...and the function sees its own span as TRACE, in that same trace
#
# Not here: a trace through an etcd /q/ queue into rppd (the queue does not
# carry one yet).
#
# Timing: ~5 min (a restart to turn it on, one to turn it off).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/skv_lib.sh"   # leader
echo "== OpenTelemetry: spans and metrics from every node to a collector =="

OT_IMAGE="${OT_IMAGE:-otel/opentelemetry-collector:0.111.0}"
OT_KEEP="${OT_KEEP:-0}"
TMP="$(mktemp -d)"

CLEANED=0
on_exit() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	if [ "$OT_KEEP" = 1 ]; then echo "  OT_KEEP=1: the collector (otelcol) and settings stay"; return 0; fi
	rh "docker rm -f otelcol >/dev/null 2>&1; true"
	local n
	for n in "${NODES[@]}"; do
		for k in open_telemetry open_telemetry_uri otel_sample_ratio otel_metrics_sec; do cfg_delete "$n" "$k" C >/dev/null 2>&1; done
		q "$n" "drop table if exists ot_t; drop table if exists ot_seen; delete from rppd_function where id = 9241;" >/dev/null 2>&1
		cfg_delete "$n" public.ot_t A >/dev/null 2>&1
	done
	rm -rf "$TMP"
	echo "  cleanup: collector removed, OpenTelemetry off; restarting"
	restart_all
	await_cluster
}
trap on_exit EXIT

# ── the collector ────────────────────────────────────────────────────────────
rh "cat > /tmp/otelcol.yaml" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      exporters: [debug]
YAML
rh "docker rm -f otelcol >/dev/null 2>&1; docker run -d --name otelcol --network $YX_NET \
	-v /tmp/otelcol.yaml:/etc/otelcol/config.yaml $OT_IMAGE >/dev/null" \
	|| { bad "the collector did not start ($OT_IMAGE)"; summary; }
sleep 3
case "$(rh "docker inspect -f '{{.State.Running}}' otelcol" 2>/dev/null)" in
	true) ok "an OpenTelemetry Collector runs on $YX_NET ($OT_IMAGE)" ;;
	*) bad "the collector is not running"; rh "docker logs otelcol 2>&1 | tail -5"; summary ;;
esac

# ── turn it on ───────────────────────────────────────────────────────────────
# O5/O6: ot_t fires a python function on commit, which records the TRACE it sees
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'on_commit_python' | tail -1)"
[ -n "$CFG" ] || bad "--encode-table-cfg 'on_commit_python' produced nothing"
OT_FN="try:
    t = TRACE
except NameError:
    t = None
cur = DB.cursor()
cur.execute(\"insert into ot_seen (tp) values (%s)\", (t,))
DB.commit()"
for n in "${NODES[@]}"; do
	q "$n" "create table if not exists rppd_config (id serial primary key, host varchar(64) not null unique,
	    host_name varchar(64) not null unique, active_since timestamptz default current_timestamp,
	    max_db_connections int not null default 10, master bool unique);
	  create table if not exists rppd_function (id serial primary key, code text not null, checksum varchar(64) not null,
	    schema_table varchar(64) not null, topic varchar(64) not null default '', priority int not null default 1,
	    queue bool not null default true, cleanup_logs_min int not null default 0, fn_logging bool not null default false,
	    verbose_debug bool not null default false, env json, sign json);
	  create table if not exists rppd_function_log (id bigserial primary key, node_id int not null, fn_id int not null,
	    trig_value json, trig_type int not null default 0, started_at timestamptz not null default current_timestamp,
	    took_ms bigint, output text, error_msg text);
	  drop table if exists ot_seen; create table ot_seen (id serial primary key, tp text);
	  delete from rppd_function where id = 9241;
	  insert into rppd_function (id, code, checksum, schema_table, topic) values (9241, \$fn\$$OT_FN\$fn\$, 'na', 'public.ot_t', '');" >/dev/null
done
for n in "${NODES[@]}"; do
	cfg_write "$n" open_telemetry C true
	cfg_write "$n" open_telemetry_uri C "http://otelcol:4317"
	cfg_write "$n" otel_sample_ratio C 1
	cfg_write "$n" otel_metrics_sec C 5
	cfg_write "$n" serve_rppd C true   # O4: rppd's instruments
	q "$n" "drop table if exists ot_t; create table ot_t (id bigint primary key, v text);" >/dev/null
done
register_table public.ot_t "$CFG"
restart_all
await_cluster
L="$(leader)"
W=""; for n in "${NODES[@]}"; do [ "$n" != "$L" ] && ! is_spare_node "$n" && { W="$n"; break; }; done
wait_writable "$W" "$L" ot_t || bad "cluster writes to ot_t never succeeded"

# one transaction of two statements, from a follower
q "$W" "begin; insert into ot_t values (1, 'a'); insert into ot_t values (2, 'b'); select yt_complete(true); commit;" >/dev/null
check "the transaction reached the leader" "2" "$(q "$L" "select count(*) from ot_t where id > 0")"
sleep 12   # spans batch (5 s), metrics push every 5 s

rh "docker logs otelcol 2>&1" > "$TMP/otel.log"
# spans as: instance <tab> trace <tab> parent (- for a root) <tab> name
awk '
	/service\.instance\.id:/ { s = $0; sub(/.*Str\(/, "", s); sub(/\).*/, "", s); inst = s }
	/Trace ID/ { tr = $NF }
	/Parent ID/ { p = $0; sub(/.*: */, "", p); gsub(/ /, "", p); par = (p == "" ? "-" : p) }
	/^ +Name +:/ { if (tr != "") { nm = $0; sub(/.*: /, "", nm); print inst "\t" tr "\t" par "\t" nm; tr = "" } }
' "$TMP/otel.log" > "$TMP/spans.tsv"
grep -oE -- '-> Name: [a-z._]+' "$TMP/otel.log" | awk '{print $3}' | sort -u > "$TMP/metrics.txt"
echo "     the collector got $(wc -l < "$TMP/spans.tsv") span(s), $(wc -l < "$TMP/metrics.txt") metric name(s)"

# ── O1 ───────────────────────────────────────────────────────────────────────
TX="$(awk -F'\t' '$4 == "yt.tx"' "$TMP/spans.tsv")"
[ -n "$TX" ] && ok "O1 the nodes export spans: $(echo "$TX" | wc -l) yt.tx root span(s)" \
	|| { bad "O1 no yt.tx span reached the collector"; tail -40 "$TMP/otel.log" | sed 's/^/     /'; }
grep -q 'service.name: Str(ytserv)' "$TMP/otel.log" && ok "O1 ...under service.name ytserv" || bad "O1 no service.name ytserv"

# ── O2 ───────────────────────────────────────────────────────────────────────
cross="$(awk -F'\t' '
	$4 == "yt.tx" { root[$2] = $1 }
	$3 != "-" && ($4 == "modify" || $4 == "commit") { kid[$2] = kid[$2] " " $1 }
	END { for (t in root) { n = split(kid[t], k, " "); for (i = 1; i <= n; i++) if (k[i] != "" && k[i] != root[t]) { print t; break } } }
' "$TMP/spans.tsv" | head -1)"
[ -n "$cross" ] && ok "O2 one transaction is one trace across nodes: trace $cross has the origin's yt.tx and a peer's call in it" \
	|| { bad "O2 no peer span joined a yt.tx trace"; awk -F'\t' '{print "     "$0}' "$TMP/spans.tsv" | head -20; }

# ── O3, O4 ───────────────────────────────────────────────────────────────────
for m in yt.term yt.leader yt.peer.rtt yt.queue.depth yt.tx.duration; do
	grep -qx "$m" "$TMP/metrics.txt" && ok "O3 metric $m pushed" || bad "O3 metric $m not seen"
done
grep -qx rppd.contexts "$TMP/metrics.txt" && ok "O4 the embedded rppd's rppd.contexts is on the same meter" \
	|| bad "O4 rppd.contexts not seen (rppd's instruments)"

# ── O5, O6: the pipeline trace ───────────────────────────────────────────────
TXT="$(awk -F'\t' '$4 == "yt.tx" {print $2}' "$TMP/spans.tsv" | sort -u)"
PPT="$(awk -F'\t' '$4 == "public.ot_t" {print $2}' "$TMP/spans.tsv" | sort -u)"
JOINED="$(comm -12 <(echo "$TXT") <(echo "$PPT") | grep -v '^$')"
joined="$(echo "$JOINED" | head -1)"
[ -n "$joined" ] && ok "O5 the rppd function the commit fired is a span in the transaction's trace ($joined)" \
	|| { bad "O5 no rppd span (public.ot_t) in a yt.tx trace: rppd spans in [${PPT:-none}]"; }
# every TRACE the function recorded - wait_writable's probes commit on ot_t too, each
# its own transaction and trace - by trace id
SEEN="$(for n in "${NODES[@]}"; do q "$n" "select tp from ot_seen where tp is not null"; done \
	| grep '^00-' | cut -d- -f2 | sort -u)"
in_tx="$(comm -12 <(echo "$JOINED" | sort -u) <(echo "$SEEN") | grep -v '^$' | head -1)"
if [ -n "$in_tx" ]; then ok "O6 the function saw its own span as TRACE, in its transaction's trace ($in_tx)"
elif [ -n "$SEEN" ]; then bad "O6 TRACE in trace(s) [$(echo $SEEN)], none of them a joined yt.tx trace [$(echo $JOINED)]"
else bad "O6 the function saw no TRACE"; fi

summary
