#!/usr/bin/env bash
# [tpl2] Sideways behaves like a shard boundary on another cluster.
#
# `no_up` / `no_down` describe a TIER hop, and a NEIGHBOR edge is same-tier: there
# is no up or down to allow or forbid, so the sideways rule had to be decided
# rather than derived. The decision (the owner's, recorded here because the code
# alone cannot explain why): **a neighbour link acts like a shard, on another
# cluster.**
#
# Two consequences, and both are tested:
#
# 1. a SHARDED table may cross a neighbour link, and which rows cross is then the
#    ordinary per-row shard decision - the same filter that applies between two
#    nodes of one cluster;
# 2. an UNSHARDED table may not cross it at all. There is no filter to apply, so
#    crossing would replicate a whole table into another cluster - the second
#    unscoped mesh that rule 2 exists to prevent.
#
# The second is the assertion that matters. Before the rule existed, `direction_to`
# returned None for a same-tier peer and `az_crosses_to` read that as "no tier
# restriction, so cross" - i.e. sideways carried everything, silently.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== neighbor: sharded crosses sideways, unsharded does not =="

enc() { "$REPO_ROOT"/target/release/yxctl --encode-table-cfg "$1" 2>/dev/null | tail -1; }
# `q` drops psql's stderr, so a refused write came back as an empty string and the
# FAIL line could not say why. This keeps it: the refusal reason is the diagnosis.
qerr() { # qerr <node> <sql>
	if [ "$YX_HOST" = "local" ]; then
		printf '%s\n' "$2" | docker exec -i -u postgres "$1" psql -tAq -d "$YX_DB" 2>&1
	else
		printf '%s\n' "$2" | "${YX_SSH[@]}" "$YX_HOST" \
			"docker exec -i -u postgres $1 psql -tAq -d $YX_DB 2>&1"
	fi
}

# Both tables are held by BOTH same-tier azs. The only difference between them is
# whether a shard rule exists, which is exactly the variable under test.
# `shard=owner` WITHOUT `outer=pin`. `outer=pin` selects the `az_node_uuid`
# strategy, where the shard column must contain a NODE UUID - so a row whose owner
# is the string 'east' is owned by nobody and every node correctly refuses to write
# it ("row is owned by another node - this az may read it, not write it"). That is
# the shard rule working, and it made this file look like a link failure.
#
# Ring-hash with the default outer policy is what this test wants: any value maps to
# some owner, and the only variable left is whether the table is SHARDED at all -
# which is what the sideways rule keys off. The default outer is `reject` (yxctl
# model.rs), so a non-owner neither stores nor writes the row: only the key's HRW
# owner may originate a write, under every outer policy (`Outer::writes()`).
CFG_SHARDED="$(enc 'az=eastc,westc; shard=owner')"
CFG_PLAIN="$(enc 'az=eastc,westc')"
[ -n "$CFG_SHARDED" ] && [ -n "$CFG_PLAIN" ] \
	&& ok "both configurations encode (sharded / unsharded, same az set)" \
	|| { bad "--encode-table-cfg produced nothing"; summary; }

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists n_sh; create table n_sh (id bigint primary key, owner text, v text);
	        drop table if exists n_pl; create table n_pl (id bigint primary key, v text);" >/dev/null
done
register_table public.n_sh "$CFG_SHARDED"
register_table public.n_pl "$CFG_PLAIN"
restart_all 30
await_clusters

EA="$(leader_of east)"; WE="$(leader_of west)"
[ -n "$EA" ] && [ -n "$WE" ] \
	&& ok "both same-tier clusters elected (east=$EA west=$WE)" \
	|| { bad "need a leader on each side of the sideways edge: east=[$EA] west=[$WE]"; summary; }

# the relation really is NEIGHBOR, or neither assertion below means anything
ext="$(info "$EA" E az_external)"
case "$ext" in
	*NEIGHBOR*) ok "east sees west across a NEIGHBOR edge" ;;
	*) bad "no NEIGHBOR relation on $EA, so this file is testing nothing: [$ext]" ;;
esac

# ── 1. an UNSHARDED table does not cross sideways ──────────────────────────
echo "  writing to the unsharded table in eastc..."
q "$EA" "begin; insert into n_pl values (1,'east'); select yt_complete(true); commit;" >/dev/null 2>&1 || true
sleep 12

check "the unsharded row is present in its own cluster" "east" "$(q "$EA" "select v from n_pl where id=1")"
crossed=""
for n in ${CLUSTER_NODES[west]}; do
	[ "$(q "$n" "select count(*) from n_pl where id=1")" != "0" ] && crossed="$crossed $n"
done
[ -z "$crossed" ] \
	&& ok "an unsharded table did NOT cross the neighbour link" \
	|| bad "an unsharded table crossed sideways to:$crossed - with no shard rule there \
is no per-row filter, so this replicates a whole table into another cluster"

# ── 2. a SHARDED table may cross, and the shard rule decides which rows ────
#
# `shard=owner` routes by a hash of the owner column, so each value belongs to some
# node of the live ring. That is the same decision made between two nodes of one
# cluster; the point here is only that the boundary does not veto it.
echo "  seeding the sharded table on both sides (out of band)..."
for c in east west; do
	for n in ${CLUSTER_NODES[$c]}; do
		trg="$(q "$n" "select tgname from pg_trigger where tgrelid='n_sh'::regclass and not tgisinternal and (tgtype & 1) = 1 limit 1")"
		q "$n" "alter table n_sh disable trigger ${trg:-user};
		        insert into n_sh (id, owner, v)
		          select g, case when g %% 2 = 0 then 'east' else 'west' end, 'seed'
		          from generate_series(1,20) g
		        on conflict do nothing;
		        alter table n_sh enable trigger ${trg:-user};" >/dev/null
	done
done

# The per-peer gate is what this asserts: for a NEIGHBOR peer, `az_crosses_to`
# permits a sharded table and refuses an unsharded one. Observable as the sharded
# table having a party that includes the far cluster at all - which shows up as the
# write being accepted rather than refused for want of participants.
#
# Only the key's owner may write it, so the write is tried from each east member
# in turn and exactly one - the owner of 'east' in east's live ring - commits.
# Writing from the leader alone passed only when the leader happened to own the
# key (on this fixture a4 of a1-a4 owns 'east'). If NO east member can write it,
# the ring put the owner outside eastc - a link counted as a member.
echo "  writing to the sharded table in eastc, from the row's owner..."
wrote=""; out=""
for n in ${CLUSTER_NODES[east]}; do
	o="$(qerr "$n" "begin; insert into n_sh values (101,'east','x'); select yt_complete(true); commit;" || true)"
	if [ "$(q "$n" "select count(*) from n_sh where id=101")" = "1" ]; then wrote="$n"; break; fi
	out="$out [$n: $(printf '%s' "$o" | tr '\n' ' ' | cut -c1-160)]"
done
[ -n "$wrote" ] \
	&& ok "a sharded table accepts a write from its row's owner ($wrote) with a neighbour link present" \
	|| bad "no east member could write the sharded row:${out} -- a local write to a sharded \
table must commit within its own cluster with a NEIGHBOR link present. Rows cross a \
boundary by the relay since ytserv 0.20.22, outside consensus, and nothing is relayed \
sideways - so a refusal here means the commit path (the party, or the shard ring that \
picks the owner) counted a linked cluster's nodes as members, which is a bug, not a \
missing carrier."

# And the difference between the two tables is visible in the placement catalog,
# which is the surface a planner reads - so the rule is inspectable rather than
# only observable by its effects.
plc_sh="$(info "$EA" P "$YX_DB.public.n_sh")"
plc_pl="$(info "$EA" P "$YX_DB.public.n_pl")"
case "$plc_sh" in
	# `"shard":{"column"...`, not just `"shard"`: every placement row has the key,
	# an unsharded one as `"shard":null`, so matching the key alone passed for both
	*'"shard":{"column"'*) ok "the placement catalog reports n_sh as sharded" ;;
	*) bad "n_sh is not reported as sharded, so the sideways rule had nothing to key \
off: $plc_sh" ;;
esac
case "$plc_pl" in
	*'"shard":null'*|*'"shard":{}'*) ok "...and n_pl as unsharded" ;;
	*) bad "n_pl is not reported as unsharded (\"shard\":null expected): ${plc_pl:-<empty>}" ;;
esac

summary
