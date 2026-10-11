#!/usr/bin/env bash
# [§2.6d] yt_setup must register a table on EVERY node, leader or not.
#
# This is the one test that deliberately uses `yt_setup` rather than env.sh's
# `register_table`. The rest of the suite uses the helper precisely because
# yt_setup could not do this job; this test is what proves the product fix, so
# using the helper here would test the workaround instead of the thing fixed.
#
# The bug: yt_setup created the trigger and wrote the module-A row in ONE
# transaction. With yt_config itself synced, that write is a cluster write and is
# refused on a non-leader ("require call from cluster leader") - and the rollback
# took the CREATE TRIGGER with it. The node ended up with NEITHER, while the
# leader's config said the table was registered. Every write there then failed
# with `yt_complete: not connected`, naming neither the table nor the reason, and
# which nodes were affected depended on who won the last election.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== yt_setup: registration works on every node, not just the leader =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists su_t; create table su_t (id bigint primary key, v text);" >/dev/null
done

# Confirm the precondition, or this test proves nothing: the config table must
# itself be synced, because that is what makes writing to it a cluster write.
# Without this, every node is trivially "the leader" for config purposes and the
# old code would pass too.
#
# Counts NODES THAT HAVE THE SYNC TRIGGER, not triggers. Two fixes over the
# first version, both of which this run caught:
#
#   * `yt_join_gate` is a second, legitimate trigger on the config table
#     ([skv] 6.4), so summing every non-internal trigger reported 14 on a
#     7-node cluster and failed a precondition that was actually satisfied.
#   * The expected value was hardcoded to 6. A fixture is parameterised now;
#     a literal there is a test that only works on one shape of cluster.
#
# And the ROW trigger only ((tgtype & 1) = 1): yt_setup also installs a
# statement-level TRUNCATE trigger (`zytsynct_*`, 31_commit C13).
cfgtrg=0
for n in "${NODES[@]}"; do
	c="$(q "$n" "select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
	             where c.relname='${YX_CFG#*.}' and not t.tgisinternal
	               and t.tgname <> 'yt_join_gate' and (t.tgtype & 1) = 1")"
	[ "${c:-0}" -gt 0 ] && cfgtrg=$((cfgtrg + 1))
done
check "the config table is synced on every node (the precondition)" "${#NODES[@]}" "$cfgtrg"

leader=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster | head -1)" in
		*Leader) leader="$n";;
	esac
done
echo "  leader is ${leader:-unknown}; every OTHER node is the case that used to fail"

echo "  calling yt_setup on each node..."
for n in "${NODES[@]}"; do
	out="$(q "$n" "select yt_setup('public.su_t','',true,'$YX_CFG')" 2>&1)"
	case "$out" in
		*"require call from cluster leader"*)
			bad "$n: yt_setup still refused by the leader gate" ;;
	esac
done

# BOTH halves, on EVERY node. Checking only one is how the original bug hid: the
# leader looked fine and reported the table registered for the whole cluster.
# The trigger half is two triggers: the row trigger and the statement-level
# TRUNCATE one (31_commit C13) - one of each.
for n in "${NODES[@]}"; do
	t="$(q "$n" "select count(*) filter (where (t.tgtype & 1) = 1) || '/' ||
	                    count(*) filter (where (t.tgtype & 32) = 32)
	             from pg_trigger t join pg_class c on c.oid=t.tgrelid
	             where c.relname='su_t' and not t.tgisinternal")"
	r="$(q "$n" "select count(*) from $YX_CFG where module='A' and name='public.su_t'")"
	if [ "${t:-}" = "1/1" ] && [ "${r:-0}" = "1" ]; then
		ok "$n has both triggers (row, truncate) and the config row"
	else
		bad "$n is half-registered — row/truncate triggers=${t:-0} cfg_row=${r:-0}"
	fi
done

# Calling it twice must not duplicate the row: yt_config has no unique
# constraint on (name, module), so a double insert is silently accepted and the
# startup loader then picks one of them arbitrarily.
q n3 "select yt_setup('public.su_t','',true,'$YX_CFG')" >/dev/null 2>&1
check "a second yt_setup does not duplicate the config row" "1" \
	"$(q n3 "select count(*) from $YX_CFG where module='A' and name='public.su_t'")"

restart_all
await_cluster
wait_writable n1 n2 su_t || { bad "cluster never became writable"; summary; }

# The real proof: a write ORIGINATING on a node that is not the leader. That is
# the node the old code left inert.
writer=n3
[ "$leader" = "n3" ] && writer=n5
q "$writer" "begin; insert into su_t values (1,'from-$writer'); select yt_complete(true); commit;" >/dev/null
for _ in $(seq 1 12); do
	[ "$(q n1 "select count(*) from su_t where id=1")" = "1" ] && break
	sleep 5
done
for n in "${NODES[@]}"; do
	check "the write from $writer reached $n" "from-$writer" "$(q "$n" "select v from su_t where id=1")"
done

summary
