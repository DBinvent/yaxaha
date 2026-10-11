#!/usr/bin/env bash
# [alert] Does anything actually reach yt_alert? The sink is built and
# unit-tested but until now no live scenario exercised it - the same shape of
# gap that let recon's repair path sit broken for a day.
#
# The deterministic trigger is a SPLIT VOTE: diverge half the nodes one way and
# half the other, so recon finds no majority, refuses to guess, blocks the row
# and files a critical alert. That is the exact path recon::notify takes.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== alert: an unrepairable row is blocked and filed to yt_alert =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists al_t; create table al_t (id bigint primary key, v text);" >/dev/null
	q "$n" "delete from public.yt_alert" >/dev/null
done

CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'recon=repair; recon_rows=1; recon_max_attempts=1' | tail -1)"
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in ONE transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - rolling the CREATE
# TRIGGER back with it. The node then has neither, and every write there dies
# with `yt_complete: not connected`. See env.sh.
register_table public.al_t "$CFG"
restart_all
await_cluster

# settle after restart_all before writing: a node still loading WAL and electing
# answers pings slowly, peers flap to "switched off", and select_party then
# cannot fill a party - the write aborts with "Not enought working nodes"
sleep 15
wait_writable n1 n2 al_t || { bad "cluster never became writable"; summary; }

SEED=10
# Single-row transactions, not one multi-row insert.
#
# The multi-row form replicated to n1/n2/n5/n6 and NOT to n3/n4 - and because
# the seed was verified on n5 alone, the test walked straight into asserting
# against n4's empty table and reported `expected [SPLIT-B] got []`, which reads
# as "the out-of-band update failed" rather than "the seed never arrived". Same
# trap 70_reshape had: the seed is SETUP, so it must not be the flakiest part of
# the test, and it must be checked where the test actually looks.
echo "  seeding $SEED rows, one transaction each..."
for i in $(seq 1 $SEED); do
	q n1 "begin; insert into al_t values ($i,'base-'||$i); select yt_complete(true); commit;" >/dev/null
	[ "$(q n1 "select count(*) from al_t where id=$i")" = "1" ] ||
		q n1 "begin; insert into al_t values ($i,'base-'||$i); select yt_complete(true); commit;" >/dev/null
done
# EVERY node, because the split below diverges n4/n5/n6 and asserts on n4 and n1.
# A seed present on only some nodes makes this test report the wrong failure.
for _ in $(seq 1 18); do
	all=1
	for n in "${NODES[@]}"; do
		[ "$(q "$n" "select count(*) from al_t where id > 0")" = "$SEED" ] || all=0
	done
	[ "$all" = "1" ] && break
	sleep 5
done
for n in "${NODES[@]}"; do
	check "seed reached $n" "$SEED" "$(q "$n" "select count(*) from al_t where id > 0")"
done

# ── split the cluster's opinion of row 3 down the MIDDLE ───────────────────
#
# An exact tie is the whole premise: recon must find no majority, refuse to
# guess, block the row and file an alert. Anything else is repairable, and a
# repairable row is the feature working — not the case under test.
#
# Half of `NODES`, computed rather than the literal `n4 n5 n6` this used to
# carry. On the seven-node fixture that literal produced 3-vs-4, recon found a
# majority and CORRECTLY repaired the row, and the test reported a failure for
# a cluster that had just done the right thing:
#
#   row [3] repaired from 05..0c59d3 (2 distinct value(s) across 7 node(s))
#
# An odd cluster cannot tie at all, so one node is left out of the vote
# entirely and the tie is struck across the even remainder.
vote_n=${#NODES[@]}
(( vote_n % 2 )) && vote_n=$(( vote_n - 1 ))
half=$(( vote_n / 2 ))
split_b=( "${NODES[@]:half:half}" )
echo "  splitting row 3 ${half}-vs-${half} across ${vote_n} node(s), out of band"
if [ "${#NODES[@]}" -ne "$vote_n" ]; then
	echo "  (${NODES[*]:vote_n} left out of the vote: an odd cluster cannot tie)"
	# ...and it must not hold either value, or it breaks the tie from outside.
	for n in "${NODES[@]:vote_n}"; do
		trg="$(q "$n" "select tgname from pg_trigger where tgrelid='al_t'::regclass and not tgisinternal and (tgtype & 1) = 1 limit 1")"
		q "$n" "alter table al_t disable trigger $trg;
		        delete from al_t where id=3;
		        alter table al_t enable trigger $trg;" >/dev/null
	done
fi
for n in "${split_b[@]}"; do
	trg="$(q "$n" "select tgname from pg_trigger where tgrelid='al_t'::regclass and not tgisinternal and (tgtype & 1) = 1 limit 1")"
	q "$n" "alter table al_t disable trigger $trg;
	        update al_t set v='SPLIT-B' where id=3;
	        alter table al_t enable trigger $trg;" >/dev/null
done
check "${split_b[0]} holds the B value" "SPLIT-B" \
	"$(q "${split_b[0]}" "select v from al_t where id=3")"
check "${NODES[0]} holds the A value" "base-3" \
	"$(q "${NODES[0]}" "select v from al_t where id=3")"

echo "  making the table due..."
q n1 "begin; insert into al_t values (77,'due'); select yt_complete(true); commit;" >/dev/null

# wait for an alert to appear anywhere
found=""
for _ in $(seq 1 30); do
	for n in "${NODES[@]}"; do
		c="$(q "$n" "select count(*) from public.yt_alert where source='recon'")"
		if [ "${c:-0}" != "0" ]; then found="$n"; break 2; fi
	done
	sleep 5
done

if [ -n "$found" ]; then
	ok "an alert row was filed on $found"
	echo "  alert:"
	q "$found" "select class||' '||source||' '||subject||' pk='||coalesce(pk,'')||' '||detail from public.yt_alert limit 3" | sed 's/^/     /'
	# Every assertion scoped to THE alert under test, never to the whole table.
	#
	# `yt_alert` is a shared node-local sink: the health monitor files into it
	# too, and an incidental `2 health cerr pre-warn` row is entirely normal on a
	# busy test cluster. An unscoped `where resolved is null` therefore counted
	# 2 and failed with `expected [1] got [2]` - reporting the health alert as a
	# defect in the recon one. Only the row this test caused may be asserted on.
	AL="from public.yt_alert where source='recon' and subject like '%al_t%'"
	check "it is CRITICAL (class 3)" "3" "$(q "$found" "select class $AL limit 1")"
	check "it names the table"       "1" "$(q "$found" "select count(*) $AL")"
	check "it is unresolved"         "1" "$(q "$found" "select count(*) $AL and resolved is null")"
	check "yt_info('E') shows it open" "1" \
		"$(info "$found" E | python3 -c "
import json,sys
rows=json.load(sys.stdin)
print(1 if any(r['name'].startswith('alert.') for r in rows) else 0)" 2>/dev/null)"

	# ── [sqlstate] the refusal a CLIENT sees ───────────────────────────────
	#
	# Asserted here rather than in a script of its own, because this is the one
	# place in the suite that reliably produces a blocked row - a second setup
	# elsewhere reproduced the recon conditions unreliably and spent its time
	# reporting "recon never blocked the row" instead of testing the thing.
	#
	# Until this landed every ytserv refusal reached the client as
	# `08006 connection_failure`, the one code `yaxaha.c` hard-coded, so "this
	# row needs an audit", "the cluster is short of nodes" and "the socket
	# dropped" were indistinguishable and no driver could decide whether to
	# retry. ytserv now prefixes `<sqlstate>: ` and the extension PARSES it
	# (`yaxaha_error_sqlstate`), so one .so serves every future code.
	#
	# 55000 is object_not_in_prerequisite_state and is PERMANENT - the refusal
	# is `is_permanent()` already and retrying cannot help, so a class-40 code
	# would tell a driver exactly the wrong thing.
	# ## Read the code from its FIELD, never with `*55000*`
	#
	# The first cut of this assertion globbed `*55000*` over the whole psql
	# output and passed while the real SQLSTATE was still `08006` - because the
	# ytserv-side prefix was sitting in the message TEXT, which is precisely the
	# defect. A glob over an error message cannot distinguish the field a driver
	# reads from prose a human reads, so it can only ever confirm that the digits
	# exist somewhere. `-v VERBOSITY=verbose` puts the real field right after
	# `ERROR:  `, and that fixed offset is the only honest place to read it.
	echo "  checking the SQLSTATE a client gets for the blocked row..."
	sqlstate_out="$(printf '%s\n' \
		"begin; update al_t set v='after-block' where id=3; select yt_complete(true); commit;" \
		| rh "docker exec -i -u postgres -e PGOPTIONS='-c lock_timeout=30s' \
			n1 psql -v VERBOSITY=verbose -d $YX_DB 2>&1")"
	# `|| true`: grep reports "no match" as exit 1, and under this file's
	# `set -euo pipefail` that killed the script outright - on the one path that
	# means "the blocked row ACCEPTED a write", i.e. exactly the failure these
	# lines exist to report. It would have died silently instead of saying so.
	err_line="$(printf '%s\n' "$sqlstate_out" | { grep -m1 '^ERROR:' || true; })"
	code="$(printf '%s' "$err_line" | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p')"
	if [ -z "$err_line" ]; then
		bad "the blocked row ACCEPTED a write"
	else
		case "$code" in
			55000) ok "the blocked row is refused with SQLSTATE 55000, not 08006" ;;
			08006) bad "still 08006 - ytserv did not prefix, the wrapper buried the \
prefix behind a label again (AppError Display), or this image's .so predates the parse" ;;
			"")    bad "no SQLSTATE field at all in: $err_line" ;;
			*)     bad "refused with SQLSTATE $code: $err_line" ;;
		esac
	fi
	# The code belongs in the error's own field and NOT also in the text: a
	# message that carries it twice is one a human reads and a driver still
	# cannot act on. `msg` is what follows the field.
	msg="$(printf '%s' "$err_line" | sed 's/^ERROR:  [0-9A-Z]\{5\}: //')"
	case "$msg" in
		*"55000"*|*"Network:"*)
			bad "the ytserv-side prefix or wrapper leaked into the message text: $msg" ;;
		"")  bad "the refusal has no message text at all" ;;
		*)   ok "the message text is clean of the prefix" ;;
	esac
else
	bad "no alert row was filed on any node within 150s"
	for n in n1 n4; do
		printf "  %s recon: %s\n" "$n" "$(info $n E recon)"
		rh "docker logs $n 2>&1 | grep -iE 'recon|alert' | tail -3" 2>/dev/null | sed 's/^/     /'
	done
fi
summary
