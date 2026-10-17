#!/usr/bin/env bash
# [§8b] The rest of the merge: counters, text, and arrays by position.
#
# 96_jsonb_merge.sh covers the bare `merge` - jsonb patches to disjoint KEYS
# commute, a patch to the same key is refused with 55409. This script covers
# what `ClusterCommitMerge` adds on top (ytserv/merge.md 2.1-2.3):
#
#   (a) `merge_all_fields` - every changed number is applied as an INCREMENT
#       (`n = n + (new - old)`, no precondition), so writers on different nodes
#       incrementing one counter all survive instead of refusing each other;
#   (b) `merge_text=body`  - a text column is merged as a 3-way LINE patch onto
#       the value the receiver holds; an edit of the same line is refused - of
#       the same words of it: a line both sides rewrote merges word by word;
#   (c) bare `merge` arrays - a same-length array is patched element by element,
#       a pure append is appended only to an array of the length its writer read
#       (two appends would land in each node's own arrival order), and any other
#       array change (a middle insert) is merged 3-way by position (diff-doc-rs) or
#       refused - a middle insert over an element changed further on is refused;
#       an array of objects that all carry a unique `id` merges by key (c4, c5;
#       merge.md §5, 2026-10-16, not run yet).
#
# ## Staged, like 96 §3
#
# (b) and (c), and the first half of (a), stage the concurrent writer OUT OF
# BAND: one node's copy is changed with the table's triggers off, which to the
# merge path is indistinguishable from another writer whose patch got there
# first. Then ONE ordinary write runs against it. No race, no held transaction -
# the outcome is deterministic, every run. The staged node keeps its own
# out-of-band edit (nothing ever replicates it), so the assertion is "the staged
# node holds BOTH edits, every other node holds the in-band one".
#
# (b) and (c) run under `cluster_commit=all` so the staged node is certainly in
# the party: a refusal is party-scoped (merge.md 4.3). (a) runs under the cluster
# default (`half`): its second half races real writers, and ALL would put them in
# a distributed row-lock cycle (96 explains it).
#
# The racing half of (a) runs LAST. A younger writer of the row is refused with
# 40001 at once ([wait-die]) and retries, as a driver does (YX_MERGE_RETRIES,
# default 20); before that the losers of the row-lock race timed out and left
# holes. YX_MERGE_WRITERS (default 3) nodes race, YX_MERGE_ROUNDS (default 3)
# writes each.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== merge: counters (all_fields), text (text_col), arrays by position =="

YXCTL="$REPO_ROOT/target/release/yxctl"
CNT_CFG="$("$YXCTL" --encode-table-cfg 'merge_all_fields' | tail -1)"
TXT_CFG="$("$YXCTL" --encode-table-cfg 'merge_text=body; cluster_commit=all' | tail -1)"
ARR_CFG="$("$YXCTL" --encode-table-cfg 'merge; cluster_commit=all' | tail -1)"
for v in "$CNT_CFG" "$TXT_CFG" "$ARR_CFG"; do
	[ -n "$v" ] || { bad "yxctl --encode-table-cfg gave an empty value - is $YXCTL built from this tree?"; summary; }
done

# `doc` second: wait_writable probes with `insert ... values (<id>, '{}')`, which
# must be a legal value for the second column.
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists mm_cnt, mm_txt, mm_arr;
	        create table mm_cnt (id int primary key, doc jsonb, n bigint);
	        create table mm_txt (id int primary key, body text);
	        create table mm_arr (id int primary key, doc jsonb);" >/dev/null
done
register_table public.mm_cnt "$CNT_CFG"
register_table public.mm_txt "$TXT_CFG"
register_table public.mm_arr "$ARR_CFG"
restart_all
await_cluster
for t in mm_cnt mm_txt mm_arr; do
	wait_writable n1 n2 "$t" || { bad "cluster never became writable for $t"; summary; }
done

# ── helpers (96's, for the same reasons: see there) ─────────────────────────
gap_of() { # gap_of <node> -> subterms still missing, or -1 if unknown
	local m g
	m="$(info "$1" E health.metrics)"
	if [ -z "$m" ]; then printf '%s' "-1"; return; fi
	g="$(printf '%s' "$m" | sed -n 's/.*wal_gap \([0-9][0-9]*\).*/\1/p')"
	if [ -z "$g" ]; then printf '%s' "-1"; else printf '%s' "$g"; fi
}
worst_gap() {
	local n g worst=0 unknown=0
	for n in "${NODES[@]}"; do
		g="$(gap_of "$n")"
		if [ "$g" = "-1" ]; then unknown=1
		elif [ "$g" -gt "$worst" ]; then worst="$g"; fi
	done
	if [ "$worst" -eq 0 ] && [ "$unknown" -eq 1 ]; then printf '%s' "-1"
	else printf '%s' "$worst"; fi
}
wait_gaps_closed() { # bounded; 0 = every node reported, and all caught up
	local i
	for i in $(seq 1 "${1:-24}"); do
		[ "$(worst_gap)" = "0" ] && return 0
		sleep 5
	done
	return 1
}
# The SQLSTATE from its own field, never a glob over the message (96).
sqlstate_of() {
	printf '%s\n' "$1" | { grep -m1 '^ERROR:' || true; } \
		| sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p'
}
# One cluster write on <node>, verbose, its whole output (an ERROR line or none).
# `|| true`: the outcome is read from the output, and under `set -e` a failed
# docker exec would otherwise end the script with no assertion made.
write_on() { # write_on <node> <statement>
	printf '%s\n' "begin; $2 select yt_complete(true); commit;" \
		| rh "docker exec -i -u postgres -e PGOPTIONS='-c lock_timeout=30s' $1 \
			psql -v VERBOSITY=verbose -d $YX_DB 2>&1" || true
}
# A write_on output's first ERROR line, if any.
error_of() { printf '%s\n' "$1" | { grep -m1 '^ERROR:' || true; }; }
# Committed = psql printed the COMMIT tag and no ERROR (a COMMIT of an aborted
# transaction answers ROLLBACK; an unreachable node prints nothing at all).
committed() { [ -z "$(error_of "$1")" ] && printf '%s\n' "$1" | grep -qx 'COMMIT'; }
# Change <node>'s copy with the table's triggers off: nothing replicates it. In
# ONE transaction - if the ALTER cannot take its lock, the update does not run
# with the trigger still on (which would replicate the "divergence").
stage_on() { # stage_on <node> <table> <statement>
	q "$1" "begin; alter table $2 disable trigger user; $3 alter table $2 enable trigger user; commit;" >/dev/null || true
}
# Poll <node> until <sql> answers <want> (~15s), then print what it answers -
# the in-band write reaches a node outside its party by the async apply.
settle() { # settle <node> <sql> <want>
	local i v=""
	for i in $(seq 1 15); do
		v="$(q "$1" "$2")"
		[ "$v" = "$3" ] && break
		sleep 1
	done
	printf '%s' "$v"
}
# The write must COMMIT: no ERROR line.
expect_commit() { # expect_commit <desc> <output>
	if committed "$2"; then ok "$1"
	else bad "$1 - not committed: $(error_of "$2")$(printf '%s' "$2" | tail -1)"; fi
}
# The write must be REFUSED with 55409 - not committed, not class 40, not 08006.
expect_55409() { # expect_55409 <desc> <output>
	local c; c="$(sqlstate_of "$2")"
	echo "    -> [${c:-committed}]"
	case "$c" in
		55409) ok "$1" ;;
		"")    bad "$1 - the intersecting write COMMITTED: merged over a value it never saw" ;;
		40*)   bad "$1 - refused with class 40 ($c): every driver RETRIES that, and a retry \
cannot converge an intersecting write (merge.md 4.1)" ;;
		*)     bad "$1 - refused with $c, expected 55409: $(error_of "$2")" ;;
	esac
}
# Every node but <except> answers <sql> with <want> (settled).
on_others() { # on_others <desc> <except> <want> <sql>
	local n v bad_on=""
	for n in "${NODES[@]}"; do
		[ "$n" = "$2" ] && continue
		v="$(settle "$n" "$4" "$3")"
		[ "$v" = "$3" ] || bad_on="$bad_on $n=[$v]"
	done
	[ -z "$bad_on" ] && ok "$1" || bad "$1 - expected [$3] on:$bad_on"
}
# Seed one row through the cluster and see it everywhere.
seed() { # seed <table> <values> <check-sql> <want>
	local out n missing=""
	out="$(write_on n1 "insert into $1 values $2;")"
	expect_commit "seed of $1 committed" "$out"
	for n in "${NODES[@]}"; do
		[ "$(settle "$n" "$3" "$4")" = "$4" ] || missing="$missing $n"
	done
	[ -z "$missing" ] || bad "the $1 seed did not reach$missing - every assertion on it would be vacuous"
}

if wait_gaps_closed 24; then
	ok "every node's apply path is caught up before the test writes"
else
	bad "a node still has a subterm gap (or never reported one) after 120s - writes \
below would be measuring the gap"
fi

# ── 0. the config is ON, with its fields ─────────────────────────────────────
#
# Every staged assertion below fails on a table without these fields, but the
# racing half of (a) could pass by luck - so check in band first. yt_info prints
# `all_fields=<bool> text_col=<count> inc_col=<count>` for a merge table, `-` without.
cfg_ok=1
for n in "${NODES[@]}"; do
	c="$(info "$n" "a:public.mm_cnt" merge)"
	t="$(info "$n" "a:public.mm_txt" merge)"
	a="$(info "$n" "a:public.mm_arr" merge)"
	case "$c" in *all_fields=true*) ;; *) cfg_ok=0; bad "$n: mm_cnt merge is [${c:-<absent>}], want \
all_fields=true - the module-A value did not load (a restart reads it)";; esac
	case "$t" in *text_col=1*) ;; *) cfg_ok=0; bad "$n: mm_txt merge is [${t:-<absent>}], want text_col=1";; esac
	case "$a" in -|"") cfg_ok=0; bad "$n: mm_arr has merge OFF [${a:-<absent>}]";; esac
done
[ "$cfg_ok" = 1 ] && ok "merge config loaded everywhere: mm_cnt [$(info n1 a:public.mm_cnt merge)], \
mm_txt [$(info n1 a:public.mm_txt merge)], mm_arr [$(info n1 a:public.mm_arr merge)]"

# ── (b) merge_text=body: a line patch composes, the same line is refused ─────
echo "  (b) text: a line patch onto a text that changed elsewhere..."
seed mm_txt "(1, E'line1\nline2\nline3\nline4\nline5')" \
	"select body = E'line1\nline2\nline3\nline4\nline5' from mm_txt where id=1" "t"

# n4's line 2 moves out from under the writer; line 4 is two lines away from it
# (adjacent lines intersect - merge.md 2.3).
stage_on n4 mm_txt "update mm_txt set body = replace(body, 'line2', 'line2 by n4') where id=1;"
check "n4 holds a divergent line 2" "t" \
	"$(q n4 "select body = E'line1\nline2 by n4\nline3\nline4\nline5' from mm_txt where id=1")"

out="$(write_on n1 "update mm_txt set body = replace(body, 'line4', 'line4 by n1') where id=1;")"
expect_commit "an edit of a DIFFERENT line commits over the diverged text" "$out"
# Under a whole-column CAS this write matched 0 rows on n4 and was dropped there.
check "n4 holds BOTH edits - its own line 2 and n1's line 4" "t" \
	"$(settle n4 "select body = E'line1\nline2 by n4\nline3\nline4 by n1\nline5' from mm_txt where id=1" t)"
on_others "every other node holds n1's line 4 over the original line 2" n4 "t" \
	"select body = E'line1\nline2\nline3\nline4 by n1\nline5' from mm_txt where id=1"

out="$(write_on n1 "update mm_txt set body = replace(body, 'line2', 'line2 by n1') where id=1;")"
expect_55409 "an edit of the SAME line as n4's is refused with 55409" "$out"
check "the refused edit left no trace on its origin" "t" \
	"$(q n1 "select body = E'line1\nline2\nline3\nline4 by n1\nline5' from mm_txt where id=1")"
check "...and n4 kept its own line" "t" \
	"$(q n4 "select body like '%line2 by n4%' and body like '%line4 by n1%' from mm_txt where id=1")"

# A line both sides rewrote merges word by word (merge.md 2.3): n4's copy of
# line 4 changes its first word, n1's write its last.
stage_on n4 mm_txt "update mm_txt set body = replace(body, 'line4 by n1', 'LINE4 by n1') where id=1;"
out="$(write_on n1 "update mm_txt set body = replace(body, 'line4 by n1', 'line4 by N1') where id=1;")"
expect_commit "an edit of ANOTHER WORD of a line n4 also changed commits" "$out"
check "n4 holds both words of line 4 - its LINE4, n1's N1 - beside its own line 2" "t" \
	"$(settle n4 "select body = E'line1\nline2 by n4\nline3\nLINE4 by N1\nline5' from mm_txt where id=1" t)"
on_others "every other node holds n1's N1 alone" n4 "t" \
	"select body = E'line1\nline2\nline3\nline4 by N1\nline5' from mm_txt where id=1"

# ── (c) arrays by position ──────────────────────────────────────────────────
echo "  (c) arrays: element-wise, append, and a middle insert..."
seed mm_arr "(1, '{\"l\": [\"a\", \"b\", \"c\", \"d\", \"e\"], \"q\": [1, 2, 3]}')" \
	"select doc->'l'->>4 || (doc->'q'->>2) from mm_arr where id=1" "e3"

# (c1) n4's element 3 moves; n1 updates element 1 - only l[1] is compared.
stage_on n4 mm_arr "update mm_arr set doc = jsonb_set(doc, '{l,3}', '\"D by n4\"') where id=1;"
out="$(write_on n1 "update mm_arr set doc = jsonb_set(doc, '{l,1}', '\"B by n1\"') where id=1;")"
expect_commit "an element update at index 1 commits over a diverged index 3" "$out"
# Without positional merge the array was one value: this matched 0 rows on n4.
want='["a", "B by n1", "c", "D by n4", "e"]'
check "n4 holds n1's element 1 AND its own element 3" "$want" \
	"$(settle n4 "select doc->'l' from mm_arr where id=1" "$want")"
on_others "every other node holds n1's element 1" n4 '["a", "B by n1", "c", "d", "e"]' \
	"select doc->'l' from mm_arr where id=1"

# (c2) n4's `q` grew by an append nobody else saw; n1 appends too. Both landing
# "after whatever is there" gave n4 [.., n4, 4] and the others [.., 4, n4] once
# n4's own append reached them - the order of two appends is not a consensus.
# An append needs the length its writer read: refused.
stage_on n4 mm_arr "update mm_arr set doc = jsonb_set(doc, '{q}', (doc->'q') || '[\"n4\"]') where id=1;"
out="$(write_on n1 "update mm_arr set doc = jsonb_set(doc, '{q}', (doc->'q') || '[4]') where id=1;")"
expect_55409 "an append onto an array that grew elsewhere is refused with 55409" "$out"
check "the refused append left no trace on its origin" '[1, 2, 3]' \
	"$(q n1 "select doc->'q' from mm_arr where id=1")"
# (c2b) ...but an element update below the end composes with that append
out="$(write_on n1 "update mm_arr set doc = jsonb_set(doc, '{q,0}', '10') where id=1;")"
expect_commit "an element update commits over an array that grew elsewhere" "$out"
want='[10, 2, 3, "n4"]'
check "n4 holds n1's element 0 AND its own append" "$want" \
	"$(settle n4 "select doc->'q' from mm_arr where id=1" "$want")"
on_others "every other node holds n1's element 0" n4 '[10, 2, 3]' \
	"select doc->'q' from mm_arr where id=1"

# (c3) a middle insert shifts every element after it: a whole-array value, with
# the whole array as its precondition - n4's l differs at index 3, so refused.
out="$(write_on n1 "update mm_arr set doc = jsonb_insert(doc, '{l,2}', '\"X\"') where id=1;")"
expect_55409 "a middle insert against a diverged array is refused with 55409" "$out"
check "the refused insert left no trace on its origin" '["a", "B by n1", "c", "d", "e"]' \
	"$(q n1 "select doc->'l' from mm_arr where id=1")"

# (c4) [merge-keyed] objects that all carry a unique `id`: merged by key. n4 put
# element 9 in front of its copy; n1 changes element 2. By position that is an
# element write under a shift - by key, two disjoint edits.
seed mm_arr "(2, '{\"items\": [{\"id\": 1, \"v\": \"a\"}, {\"id\": 2, \"v\": \"b\"}]}')" \
	"select jsonb_array_length(doc->'items') from mm_arr where id=2" "2"
stage_on n4 mm_arr "update mm_arr set doc = jsonb_set(doc, '{items}', '[{\"id\": 9, \"v\": \"z\"}]'::jsonb || (doc->'items')) where id=2;"
out="$(write_on n1 "update mm_arr set doc = jsonb_set(doc, '{items,1,v}', '\"B by n1\"') where id=2;")"
expect_commit "a keyed element update commits over an element put in front elsewhere" "$out"
check "n4 holds its element 9 AND n1's change of element 2, by key" "t" \
	"$(settle n4 "select doc->'items' = '[{\"id\": 9, \"v\": \"z\"}, {\"id\": 1, \"v\": \"a\"}, {\"id\": 2, \"v\": \"B by n1\"}]'::jsonb from mm_arr where id=2" t)"
on_others "every other node holds n1's element 2" n4 "t" \
	"select doc->'items' = '[{\"id\": 1, \"v\": \"a\"}, {\"id\": 2, \"v\": \"B by n1\"}]'::jsonb from mm_arr where id=2"

# (c5) ...and n1 removing an element n4 changed is an intersect: refused
stage_on n4 mm_arr "update mm_arr set doc = jsonb_set(doc, '{items,1,v}', '\"A by n4\"') where id=2;"
out="$(write_on n1 "update mm_arr set doc = jsonb_set(doc, '{items}', (doc->'items') - 0) where id=2;")"
expect_55409 "removing an element changed elsewhere is refused with 55409" "$out"
check "the refused removal left no trace on its origin" "2" \
	"$(q n1 "select jsonb_array_length(doc->'items') from mm_arr where id=2")"

# ── (a) merge_all_fields: counters ──────────────────────────────────────────
echo "  (a) counters: increments compose, staged and raced..."
seed mm_cnt "(1, '{\"c\": 0.5, \"tag\": \"x\"}', 0)" \
	"select n::text || '/' || (doc->>'c') from mm_cnt where id=1" "0/0.5"

# (a1) staged: n4's counter already holds +100 (and its leaf +10.0) nobody else
# saw; n1 adds 1 and 0.1. An increment has no precondition on the counter, so n4
# must end at 101 / 10.6 (the others at 1 / 0.6) - under a CAS it matched 0 rows
# there, and under the bare merge's path CAS it would be REFUSED.
stage_on n4 mm_cnt "update mm_cnt set n = n + 100,
	doc = jsonb_set(doc, '{c}', to_jsonb((doc->>'c')::numeric + 10.0)) where id=1;"
out="$(write_on n1 "update mm_cnt set n = n + 1,
	doc = jsonb_set(doc, '{c}', to_jsonb((doc->>'c')::numeric + 0.1)) where id=1;")"
expect_commit "an increment commits over a counter that moved elsewhere (no 55409)" "$out"
check "n4 added n1's delta to ITS value (column and jsonb leaf)" "t" \
	"$(settle n4 "select n = 101 and (doc->>'c')::numeric = 10.6 from mm_cnt where id=1" t)"
on_others "every other node added the same delta to its own value" n4 "t" \
	"select n = 1 and (doc->>'c')::numeric = 0.6 from mm_cnt where id=1"
# put n4 back in line, out of band, so the race below compares like with like
stage_on n4 mm_cnt "update mm_cnt set n = 1, doc = jsonb_set(doc, '{c}', '0.6') where id=1;"

# (a2) raced: writers on different nodes add distinct amounts at the same
# instant, several rounds each. Every write's outcome is captured: what committed
# must be in the total on every caught-up node, exactly - Postgres's numeric
# arithmetic, so 0.1 steps add up with no float residue. Every write commits:
# a 40001 (the younger writer of the row, [wait-die]) is retried; anything else
# fails - 55409 most of all, increments carry no precondition that could
# intersect.
writers=( "${NODES[@]:0:${YX_MERGE_WRITERS:-3}}" )
rounds="${YX_MERGE_ROUNDS:-3}"
echo "    ${#writers[@]} nodes x $rounds rounds incrementing one row at once..."
dir="$(mktemp -d)"
pids=()
for i in "${!writers[@]}"; do
	w="${writers[$i]}"; k=$((i + 1))
	(
		for r in $(seq 1 "$rounds"); do
			a=0
			while :; do
				a=$((a + 1))
				write_on "$w" "update mm_cnt set n = n + $k,
					doc = jsonb_set(doc, '{c}', to_jsonb((doc->>'c')::numeric + $k * 0.1)) where id=1;" \
					> "$dir/$w.$r" 2>&1 || true
				{ [ "$(sqlstate_of "$(cat "$dir/$w.$r")")" = "40001" ] && [ "$a" -lt "${YX_MERGE_RETRIES:-20}" ]; } || break
				sleep "0.$(( RANDOM % 4 + 1 ))"
			done
			echo "$a" > "$dir/$w.$r.tries"
		done
	) &
	pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done

acked=0; won=0; lost=(); merge_refused=""; retried=0
for i in "${!writers[@]}"; do
	w="${writers[$i]}"; k=$((i + 1))
	for r in $(seq 1 "$rounds"); do
		o="$(cat "$dir/$w.$r" 2>/dev/null || true)"
		c="$(sqlstate_of "$o")"
		retried=$(( retried + $(cat "$dir/$w.$r.tries" 2>/dev/null || echo 1) - 1 ))
		if committed "$o"; then
			acked=$((acked + k)); won=$((won + 1))
		else
			lost+=("$w#$r:${c:-?}")
			[ "$c" = "55409" ] && merge_refused="$merge_refused $w#$r"
		fi
	done
done
rm -rf "$dir"
echo "    committed $won of $(( ${#writers[@]} * rounds )) ($retried retries on 40001), sum of committed increments: $acked"
[ ${#lost[@]} -eq 0 ] || echo "    refused:  ${lost[*]}"
[ -z "$merge_refused" ] \
	&& ok "no increment was refused as an intersect (55409)" \
	|| bad "increment(s)$merge_refused were refused with 55409 - an increment carries no \
precondition on the counter, so the merge is comparing it"
# Before [wait-die] the race committed 0 of 9: every writer timed out (55P03 /
# 08006) in a row-lock cycle across nodes.
[ "$won" -eq $(( ${#writers[@]} * rounds )) ] \
	&& ok "all $won concurrent increments committed" \
	|| bad "only $won of $(( ${#writers[@]} * rounds )) concurrent increments committed - refused: ${lost[*]}"

wait_gaps_closed 24 || true
settled=(); behind=()
for n in "${NODES[@]}"; do
	g="$(gap_of "$n")"
	if [ "$g" = "0" ]; then settled+=("$n"); else behind+=("$n:$g"); fi
done
echo "    settled:   ${settled[*]:-none}"
[ ${#behind[@]} -eq 0 ] || echo "    behind:    ${behind[*]}"
[ "${#settled[@]}" -ge 2 ] \
	&& ok "${#settled[@]} of ${#NODES[@]} nodes caught up - enough to compare" \
	|| bad "only ${#settled[@]} node(s) caught up - nothing below is a real comparison"

# THE counter property: on a node with no gap, the total is base + every
# committed increment - none lost (a CAS drops the later of two), none doubled.
for n in "${settled[@]}"; do
	v="$(q "$n" "select n::text || '/' || (doc->>'c')::numeric::text from mm_cnt where id=1")"
	[ "$(q "$n" "select n = 1 + $acked and (doc->>'c')::numeric = 0.6 + $acked * 0.1 from mm_cnt where id=1")" = "t" ] \
		&& ok "$n (no gap) holds every committed increment: $v" \
		|| bad "$n has NO gap and holds [$v], want [$((1 + acked))/0.6+$acked*0.1] - an \
increment was lost or applied twice"
done
for n in "${settled[@]:1}"; do
	check_same "${settled[0]} and $n hold the identical counter row" "${settled[0]}" "$n" \
		"select md5(n::text || doc::text) from mm_cnt where id = 1" 1 mm_cnt
done

# ── cleanup ─────────────────────────────────────────────────────────────────
# Tables and their module-A rows; the next script restarts with its own config.
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists mm_cnt, mm_txt, mm_arr;" >/dev/null || true
	for t in mm_cnt mm_txt mm_arr; do cfg_delete "$n" "public.$t" A || true; done
done

summary
