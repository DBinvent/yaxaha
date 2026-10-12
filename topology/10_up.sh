#!/usr/bin/env bash
# [topology] Start the six nodes and write the cluster config rows.
#
# Order matters: every node's postgres comes up first, THEN the N/C/Z rows are
# written everywhere, and only then does ytserv start electing. A node that saw
# a half-written roster would elect on it.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

rh "docker network inspect $YX_NET >/dev/null 2>&1 || docker network create $YX_NET >/dev/null"

echo "Starting ${#NODES[@]} nodes..."
for n in "${NODES[@]}"; do
	u="$(node_uuid "$n")"
	rh "docker rm -f $n >/dev/null 2>&1; true"
	# [P6c/db-local] A spare node reaches its PostgreSQL over TCP, so it can
	# never be Main (membership.md, Forever-Spare) while staying a full etcd
	# and rppd member. `?host=` is omitted, which is what makes the URL TCP —
	# see rmc.rs::db_is_unix_socket, and note the `?host=` test comes FIRST
	# there because sqlx_host_fix inserts `localhost` into socket URLs.
	dbu=""
	if is_spare_node "$n"; then
		dbu="-e DB_URL=postgresql://postgres@127.0.0.1:5432/$YX_DB"
		echo "  $n: TCP-attached PostgreSQL (forever-Spare)"
	fi
	# YX_COV_MOUNT: a coverage run's volume for the instrumented ytserv's counts
	# (nightly/coverage.sh); unset otherwise.
	rh "docker run -d --name $n --hostname $n --network $YX_NET \
		-e NODE_UUID=$u -e DB=$YX_DB -e CFG_TABLE=$YX_CFG -e SECRET=$YX_SECRET $dbu ${YX_COV_MOUNT:-} \
		$YX_IMAGE >/dev/null"
done

echo "Waiting for postgres on each node..."
for n in "${NODES[@]}"; do
	for _ in $(seq 1 60); do
		[ "$(q "$n" 'select 1')" = "1" ] && break
		sleep 2
	done
	printf "  %s postgres=%s\n" "$n" "$(q "$n" 'select 1')"
done

echo "Writing cluster config (N: roster, C: tuning, Z: az map + tiers)..."
for n in "${NODES[@]}"; do
	sql=""
	# N rows: the whole roster on every node, keyed by the deterministic uuid.
	for p in "${NODES[@]}"; do
		sql+="insert into $YX_CFG (name, module, value) select '$(node_uuid "$p")','N','$p:$YX_PORT' "
		sql+="where not exists (select 1 from $YX_CFG where name='$(node_uuid "$p")' and module='N');"
	done
	# C: a 6-node cluster needs its own minimum, not the compiled default of 3.
	sql+="delete from $YX_CFG where module='C' and name in ('min_cluster_size','log_level','cfg_ready','az','serve_etcd','cluster');"
	# [P6c] Spare nodes are in the ROSTER but never in the quorum, so the
	# minimum counts only the nodes that can actually participate. A 7-node
	# roster with one forever-Spare must still form a 6-node cluster - that IS
	# the assertion 24_db_local.sh makes.
	sql+="insert into $YX_CFG (name,module,value) values ('min_cluster_size','C','${YX_MIN_CLUSTER:-$(( ${#NODES[@]} - ${#SPARE_NODES[@]} ))}');"
	# [P6] SKV and every queue flow need the embedded etcd; the compiled
	# default is OFF, so without this `skv_etcd()` returns None and every SKV
	# test is a silent no-op that passes.
	sql+="insert into $YX_CFG (name,module,value) values ('serve_etcd','C','true');"
	# [peering] ONE cluster uuid, shared by every node.
	#
	# Left unset - which is what `yxctl --batch` produces and what this fixture
	# did - each node calls `Uuid::new_v4()` for its own cluster id, peering
	# compares those and refuses every peer, and the embedded etcd is a kv of
	# one per node. Nothing said so; the only trace was a `wrong cluster` line
	# per peer per attempt.
	sql+="insert into $YX_CFG (name,module,value) values ('cluster','C','$YX_CLUSTER_UUID');"
	# log_level: the default is debug and costs ~11% - "warning", not "warn".
	sql+="insert into $YX_CFG (name,module,value) values ('log_level','C','warning');"
	# Six PostgreSQL+ytserv pairs share one host here, so the compiled 100ms ping
	# deadline is far too tight: under a multi-statement transaction the node is
	# busy applying, pings miss it, peers flap to "switched off", and select_party
	# then cannot find enough up() peers - the write aborts with "Not enought
	# working nodes". A 1-row write slips through and a 20-row one does not, which
	# is what made this look like a multi-row replication bug.
	sql+="delete from $YX_CFG where module='C' and name='tcp_timeout_ms';"
	sql+="insert into $YX_CFG (name,module,value) values ('tcp_timeout_ms','C','2000');"
	# Z: node -> az, and <az>.tier -> n. Replicated like any config row, so every
	# node ends up with the same placement map without asking anyone.
	sql+="delete from $YX_CFG where module='Z';"
	for p in "${NODES[@]}"; do
		sql+="insert into $YX_CFG (name,module,value) values ('$(node_uuid "$p")','Z','${NODE_AZ[$p]}');"
	done
	for az in "${!AZ_TIER[@]}"; do
		sql+="insert into $YX_CFG (name,module,value) values ('$az.tier','Z','${AZ_TIER[$az]}');"
	done
	# each node's own az: az_map says where every node is, SmCfg.az says which
	# one THIS process is
	sql+="delete from $YX_CFG where module='C' and name='az';"
	sql+="insert into $YX_CFG (name,module,value) values ('az','C','${NODE_AZ[$n]}');"
	# written LAST, and the entrypoint waits for it - see node-entrypoint.sh
	sql+="insert into $YX_CFG (name,module,value) values ('cfg_ready','C','1');"
	q "$n" "$sql" >/dev/null
	printf "  %s: %s N rows, %s Z rows\n" "$n" \
		"$(q "$n" "select count(*) from $YX_CFG where module='N'")" \
		"$(q "$n" "select count(*) from $YX_CFG where module='Z'")"
done

echo "Restarting ytserv everywhere (synchronised - a 6-node cold start needs it)..."
for n in "${NODES[@]}"; do rh "docker restart $n >/dev/null"; done
sleep 25

# [cfgsync] The config table's OWN trigger, installed only once ytserv answers -
# the same post-start step `yxctl --batch` now performs (actions/config_trigger.rs).
# Without it a config change reaches one node and only at its next restart.
#
# This is the ONE registration that cannot use yt_setup, and it is the origin of
# the whole §2.6d mess: yt_setup writes the module-A row through the config
# table, so registering the CONFIG TABLE ITSELF is self-referential. The first
# node to get the trigger makes the write consensus-gated for everyone else, so
# the call succeeded on some nodes and failed on others - and the errors were
# swallowed by `2>/dev/null`, which is why it looked fine for weeks.
#
# Measured before this changed: n1 failed, n2-n6 succeeded, leaving n1 the only
# node whose config table had NO trigger - so the next yt_setup in a test
# succeeded on n1 alone, and five of six nodes could not originate a write.
#
# register_table creates the trigger directly on every node and writes the row
# with the trigger disabled, so the outcome does not depend on who won the
# election.
echo "Installing the config-table trigger (post-start)..."
register_table "$YX_CFG"
sleep 5
# The SYNC trigger only. `yt_join_gate` ([skv] 6.4) is a second, legitimate
# trigger on this table, and counting it made every node look misconfigured -
# "WARN: n6 has 2 trigger(s)" was this, not a real problem. Nor is the
# statement-level TRUNCATE trigger register_table adds: row triggers only.
for n in "${NODES[@]}"; do
	t="$(q "$n" "select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
	             where c.relname='${YX_CFG#*.}' and not t.tgisinternal
	               and t.tgname <> 'yt_join_gate' and (t.tgtype & 1) = 1")"
	[ "${t:-0}" = "1" ] || echo "  WARN: $n has ${t:-0} sync trigger(s) on $YX_CFG" >&2
done
echo "Cluster state:"
for n in "${NODES[@]}"; do
	printf "  %-4s az=%-5s %s\n" "$n" "${NODE_AZ[$n]}" \
		"$(info "$n" O cluster)"
done
# what run_a.sh's pre-case puts back before every test case (env.sh pre_case)
cfg_baseline_save
