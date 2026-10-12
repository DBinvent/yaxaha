#!/usr/bin/env bash
# [tpl2] Bring up three clusters on one docker network and link them.
#
# Same order as the single-cluster fixture, for the same reason: every node's
# postgres first, THEN all the config rows, and only then ytserv electing. A node
# that saw a half-written roster would elect on it.
#
# What is different, and is the whole point:
#
# - three DIFFERENT cluster uuids, so "external" means something;
# - each cluster's `N` roster carries its own members AND the nodes it links to,
#   because a link IS a peer entry - ytserv has no separate foreign-node concept;
# - `min_cluster_size` is a majority of the MEMBERS (2 of 3), never of the roster,
#   so a cluster survives losing one node - which 70_failover requires - while a
#   merged quorum still shows up as one leader across nine nodes;
# - module-`Z` carries `<az>.link.<other_az>` rows: the relation layer.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

rh "docker network inspect $YX_NET >/dev/null 2>&1 || docker network create $YX_NET >/dev/null"

# YX_COV_MOUNT: a coverage run's volume for the instrumented ytserv's counts
# (nightly/coverage.sh); unset otherwise.
start_node() { # start_node <node>: a fresh container for it
	local n="$1" u
	u="$(node_uuid "$n")"
	rh "docker rm -f $n >/dev/null 2>&1; true"
	rh "docker run -d --name $n --hostname $n --network $YX_NET \
		-e NODE_UUID=$u -e DB=$YX_DB -e CFG_TABLE=$YX_CFG ${YX_COV_MOUNT:-} \
		$YX_IMAGE >/dev/null"
}
echo "Starting ${#NODES[@]} nodes in ${#CLUSTERS[@]} clusters..."
for n in "${NODES[@]}"; do start_node "$n"; done

# A node whose container is not there is started again, once per wait. Twice a
# node of this fixture was gone between its `docker run` and the first query
# (2026-10-10: a2, then b3 - "No such container") and the whole suite failed on
# it, every script after 10_up reading a cluster without a leader.
echo "Waiting for postgres on each node..."
for n in "${NODES[@]}"; do
	for i in $(seq 1 60); do
		[ "$(q "$n" 'select 1')" = "1" ] && break
		if [ $((i % 15)) = 0 ] && [ "$(rh "docker inspect -f '{{.State.Running}}' $n 2>/dev/null || echo missing")" != "true" ]; then
			echo "  WARN: $n's container is not running - starting it again"
			start_node "$n"
		fi
		sleep 2
	done
	printf "  %-3s postgres=%s\n" "$n" "$(q "$n" 'select 1')"
done

# Which foreign nodes each cluster needs in its roster.
#
# The upper cluster rosters every lower node, because rule 1 says an upper node
# links to the lower cluster's LEADER and which node that is changes - so the
# roster has to contain all the candidates while the dial gate picks the one that
# currently leads. The lower clusters roster the upper nodes (their own leader
# dials up) and each other (the NEIGHBOR edge, leader to leader).
# The upper cluster rosters NOTHING extra: it holds no address for a child, so it
# has nothing to put in a roster. Its children appear as peers only when they
# connect in, identified by the sign-in key.
#
# The lower clusters roster the upper nodes (their leader dials up, avoiding the
# upper leader) and each other (the NEIGHBOR edge, leader to leader), because those
# are the clusters they DIAL.
declare -A LINKED=(
	[upper]=""
	[east]="${CL_UPPER[*]} ${CL_WEST[*]}"
	[west]="${CL_UPPER[*]} ${CL_EAST[*]}"
)

echo "Writing config (N: members + links, C: per-cluster uuid, Z: az/tier/link)..."
for n in "${NODES[@]}"; do
	c="${NODE_CLUSTER[$n]}"
	sql=""
	# N: this cluster's members...
	for p in ${CLUSTER_NODES[$c]}; do
		sql+="insert into $YX_CFG (name, module, value) select '$(node_uuid "$p")','N','$p:$YX_PORT' "
		sql+="where not exists (select 1 from $YX_CFG where name='$(node_uuid "$p")' and module='N');"
	done
	# ...and the nodes it links to. Counted in the roster, excluded from quorum by
	# the relation rows below - that separation is what the fixture exists to test.
	for p in ${LINKED[$c]}; do
		sql+="insert into $YX_CFG (name, module, value) select '$(node_uuid "$p")','N','$p:$YX_PORT' "
		sql+="where not exists (select 1 from $YX_CFG where name='$(node_uuid "$p")' and module='N');"
	done

	sql+="delete from $YX_CFG where module='C' and name in "
	sql+="('min_cluster_size','log_level','cfg_ready','az','cluster','tcp_timeout_ms');"
	# A MAJORITY of the members: 2 of 3. Not 9 (the roster), and not 3 either.
	#
	# 3 of 3 is what the first version used, and it leaves zero fault tolerance - so
	# 70_failover stopped the east leader and east could never re-elect on the two
	# nodes that remained. "A cluster of 3 that cannot survive losing 1" is not the
	# property under test here.
	#
	# The merge this fixture guards against is still caught: a merged quorum shows up
	# as ONE leader across nine nodes, which 30_quorum asserts against directly.
	sql+="insert into $YX_CFG (name,module,value) values ('min_cluster_size','C','2');"
	# the cluster identity - distinct per cluster, which is what makes a link a link
	sql+="insert into $YX_CFG (name,module,value) values ('cluster','C','${CLUSTER_UUID[$c]}');"
	sql+="insert into $YX_CFG (name,module,value) values ('log_level','C','warning');"
	# nine PostgreSQL+ytserv pairs on one host: the compiled 100ms ping deadline is
	# far too tight, same as the six-node fixture only more so.
	sql+="insert into $YX_CFG (name,module,value) values ('tcp_timeout_ms','C','2000');"
	sql+="insert into $YX_CFG (name,module,value) values ('az','C','${NODE_AZ[$n]}');"

	# Z: this cluster's own node->az rows, the tiers, and the catalogue of OTHER
	# clusters as this cluster sees them.
	sql+="delete from $YX_CFG where module='Z';"
	# Own members always. Plus the nodes of any cluster we hold addresses for, so an
	# inbound or outbound peer from there can be attributed to its cluster - for a
	# LOWER cluster we hold neither, which is the point.
	for p in ${CLUSTER_NODES[$c]} ${LINKED[$c]}; do
		sql+="insert into $YX_CFG (name,module,value) values ('$(node_uuid "$p")','Z','${NODE_AZ[$p]}');"
	done
	for az in "${!AZ_TIER[@]}"; do
		sql+="insert into $YX_CFG (name,module,value) values ('$az.tier','Z','${AZ_TIER[$az]}');"
	done
	# the other-cluster catalogue: "<az>:<LEVEL>:<hosts...>:"
	for entry in ${OTHERS[$c]}; do
		oaz="${entry%%:*}"
		rest="${entry#*:}"
		olevel="${rest%%:*}"
		ohosts="${rest#*:}"; ohosts="${ohosts%:}"
		sql+="insert into $YX_CFG (name,module,value) values ('$oaz.level','Z','$olevel');"
		if [ -n "$ohosts" ]; then
			# a cluster we DIAL: addresses
			hl=""
			for h in $ohosts; do hl="${hl:+$hl,}$h:$YX_PORT"; done
			sql+="insert into $YX_CFG (name,module,value) values ('$oaz.host','Z','$hl');"
		fi
		if [ "$olevel" = "LOWER" ]; then
			# a cluster that DIALS us: a sign-in key, and deliberately no address
			sql+="insert into $YX_CFG (name,module,value) values ('$oaz.pub','Z','${AZ_PUBKEY[$oaz]}');"
		fi
	done
	# written LAST, and the entrypoint waits for it - see node-entrypoint.sh
	sql+="insert into $YX_CFG (name,module,value) values ('cfg_ready','C','1');"
	q "$n" "$sql" >/dev/null
	printf "  %-3s cluster=%-5s az=%-5s N=%s Z=%s\n" "$n" "$c" "${NODE_AZ[$n]}" \
		"$(q "$n" "select count(*) from $YX_CFG where module='N'")" \
		"$(q "$n" "select count(*) from $YX_CFG where module='Z'")"
done

echo "Restarting ytserv everywhere (synchronised - three cold starts at once)..."
for n in "${NODES[@]}"; do rh "docker restart $n >/dev/null"; done
sleep 30

# The config table's own trigger, post-start. Same reasoning as the single-cluster
# fixture: registering the CONFIG TABLE is self-referential, so it is done directly
# on every node rather than through yt_setup.
echo "Installing the config-table trigger (post-start)..."
register_table "$YX_CFG"
sleep 5

await_clusters

echo "Cluster state:"
for c in "${CLUSTERS[@]}"; do
	l="$(leader_of "$c")"
	printf "  %-5s uuid=%s leader=%s\n" "$c" "${CLUSTER_UUID[$c]:0:8}" "${l:-<none>}"
	for n in ${CLUSTER_NODES[$c]}; do
		printf "    %-3s az=%-5s %s\n" "$n" "${NODE_AZ[$n]}" "$(info "$n" O cluster)"
	done
done
