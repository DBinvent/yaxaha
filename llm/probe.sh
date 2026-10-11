#!/usr/bin/env bash
# Is the model service there to test against? Each model the test asks - the
# default one (sql and df), LLM_MODEL_ROUTE and LLM_MODEL_CH - has to answer a
# one-token chat completion through the mutual-TLS proxy. /health is not enough:
# the proxy has answered it 200 while every completion got 502.
#
#   ./probe.sh     # exit 0: every model answered; 77: the suite is skipped
#
# A model that is loading (503) or down (502, 000 = no connection) is asked
# again every 10 s for up to PROBE_WAIT seconds (default 300) in all. When one
# never answers, the yt_llm test says nothing about yaxaha - it is skipped, not
# failed.
. "$(dirname "$0")/lib.sh"

skip() { say "SKIP llm: $* - the yt_llm suite is not run"; exit 77; }

for f in "$LLM_CA" "$LLM_CLIENT_CERT" "$LLM_CLIENT_KEY"; do
    [ -r "$f" ] || skip "the model service's client bundle: $f is not readable"
done
resolve=(); [ -n "$LLM_HOST_IP" ] && resolve=(--resolve "$LLM_HOST:$LLM_HOST_IP")
wait="${PROBE_WAIT:-300}"
deadline=$(( $(date +%s) + wait ))
for p in "" "$LLM_MODEL_ROUTE/" "$LLM_MODEL_CH/"; do
    url="https://$LLM_HOST/${p}v1/chat/completions"
    while :; do
        r=$(curl -s -o /dev/null -w '%{http_code} %{time_total}s' --max-time 180 --cacert "$LLM_CA" \
            --cert "$LLM_CLIENT_CERT" --key "$LLM_CLIENT_KEY" "${resolve[@]}" \
            -H 'Content-Type: application/json' \
            -d '{"messages":[{"role":"user","content":"ping"}],"max_tokens":1}' "$url")
        if [ "${r%% *}" = 200 ]; then say "== model ${p:-default/} answers: $r"; break; fi
        [ "$(date +%s)" -lt "$deadline" ] || skip "the model service is not answering: $url gave HTTP ${r%% *} (asked for ${wait}s)"
        sleep 10
    done
done
