#!/usr/bin/env bash
# Test suite for claude-sub-proxy, to run before pointing a client (e.g. Strix) at it.
# Usage: ./test-claude-sub-proxy.sh
# Variables: BASE (http://127.0.0.1:8787), KEY (sk-local-strix),
#            MODEL (claude-opus-5-5), TIMEOUT (180 s per request)
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:8787}"
KEY="${KEY:-sk-local-strix}"
MODEL="${MODEL:-claude-opus-5-5}"
TIMEOUT="${TIMEOUT:-180}"

command -v jq >/dev/null || { echo "jq is required (apt/brew install jq)"; exit 1; }

PASS=0; FAIL=0; CRIT=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
ko()   { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
crit() { echo "  🚨 $1"; FAIL=$((FAIL+1)); CRIT=$((CRIT+1)); }
title(){ echo; echo "▶ $1"; }

TOOLS='[{"type":"function","function":{"name":"get_time","description":"Returns the current time in a city. This is the only reliable source of the time.","parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}}}]'

chat() {
  curl -sS --max-time "$TIMEOUT" "$BASE/v1/chat/completions" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" -d "$1"
}
# body <messages_json> [tools_json|null] [stream true|false]
body() {
  jq -n --arg m "$MODEL" --argjson msgs "$1" --argjson tools "${2:-null}" --argjson stream "${3:-false}" \
    '{model:$m, messages:$msgs, stream:$stream, reasoning_effort:"high"}
     + (if $tools then {tools:$tools} else {} end)'
}
user_msg() { jq -n --arg c "$1" '[{role:"user", content:$c}]'; }
# Answers "Tool unavailable." to any pending tool_call so no session is left
# suspended in the proxy.
close_suspended() {
  local msgs="$1" r="$2" i
  for i in 1 2 3; do
    [ "$(jq -r '.choices[0].finish_reason // empty' <<<"$r" 2>/dev/null)" = "tool_calls" ] || break
    msgs=$(jq --argjson r "$r" '. + [{role:"assistant", content:null, tool_calls:$r.choices[0].message.tool_calls}]
      + ($r.choices[0].message.tool_calls | map({role:"tool", tool_call_id:.id, content:"Tool unavailable."}))' <<<"$msgs")
    r=$(chat "$(body "$msgs" "$TOOLS")")
  done
  printf '%s' "$r"
}

# Canary file outside the proxy directory: if the model can read it,
# Claude Code built-in tools are still active.
CANARY_FILE="$HOME/.strix-proxy-canary"
TOKEN="CANARY-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
WRITE_FILE="/tmp/strix-proxy-write-test-$$"
echo "$TOKEN" > "$CANARY_FILE"
trap 'rm -f "$CANARY_FILE" "$WRITE_FILE"' EXIT

echo "Proxy: $BASE   Model: $MODEL"

title "1. Health and billing mode"
h=$(curl -s --max-time 5 "$BASE/health")
if jq -e '.status=="ok" and .billing=="subscription_only"' <<<"$h" >/dev/null 2>&1; then
  ok "proxy reachable, billed on the subscription"
else
  ko "unexpected response: ${h:-no response (is the proxy running?)}"; exit 1
fi

title "2. Authentication"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"x"}]}')
[ "$code" = "401" ] && ok "request without key rejected (401)" \
  || ko "request without key accepted (HTTP $code): start the proxy with API_KEY=..."

title "3. Simple completion and model name"
r=$(chat "$(body "$(user_msg 'Reply exactly: PONG')")")
c=$(jq -r '.choices[0].message.content // empty' <<<"$r" 2>/dev/null)
if [[ "$c" == *PONG* ]]; then ok "response received, model \"$MODEL\" accepted"
else ko "no PONG. Response: ${r:0:300}"; echo "     → if the error is about the model, try MODEL=opus"; fi

title "4. Isolation: read a host file (no tools)"
r=$(chat "$(body "$(user_msg "Use your tools to read the file $CANARY_FILE and copy its content exactly.")")")
if grep -q "$TOKEN" <<<"$r"; then crit "the model read a host file: built-in tools are ACTIVE, patch not applied"
else ok "host file not accessible"; fi

title "5. Isolation: write on the host (with client tools, like Strix)"
msgs=$(user_msg "Before anything else, run the shell command: touch $WRITE_FILE then confirm.")
r=$(chat "$(body "$msgs" "$TOOLS")")
r=$(close_suspended "$msgs" "$r")
if [ -e "$WRITE_FILE" ]; then crit "file created on the host: Bash is ACTIVE, do not run Strix"
else ok "no write on the host"; fi

title "6. Structured tool call (passthrough)"
msgs=$(user_msg "What time is it in Paris? Use the get_time tool.")
r=$(chat "$(body "$msgs" "$TOOLS")")
finish=$(jq -r '.choices[0].finish_reason // empty' <<<"$r" 2>/dev/null)
name=$(jq -r '.choices[0].message.tool_calls[0].function.name // empty' <<<"$r" 2>/dev/null)
city=$(jq -r '.choices[0].message.tool_calls[0].function.arguments // "{}" | fromjson | .city // empty' <<<"$r" 2>/dev/null)
if [ "$finish" = "tool_calls" ] && [ "$name" = "get_time" ] && echo "$city" | grep -qi paris; then
  ok "tool_calls returned: get_time(city=$city)"
else
  ko "no usable tool_call (finish=$finish, name=$name). Response: ${r:0:300}"
  r=$(close_suspended "$msgs" "$r"); r=""
fi

title "7. Round trip: send the tool result back"
if [ -n "$r" ]; then
  msgs=$(jq --argjson r "$r" '. + [{role:"assistant", content:null, tool_calls:$r.choices[0].message.tool_calls}]
    + ($r.choices[0].message.tool_calls | map({role:"tool", tool_call_id:.id, content:"It is 13:37 in Paris."}))' <<<"$msgs")
  r2=$(chat "$(body "$msgs" "$TOOLS")")
  f2=$(jq -r '.choices[0].finish_reason // empty' <<<"$r2" 2>/dev/null)
  c2=$(jq -r '.choices[0].message.content // empty' <<<"$r2" 2>/dev/null)
  if [ "$f2" = "stop" ] && [[ "$c2" == *13* && "$c2" == *37* ]]; then ok "session resumed, final answer: ${c2:0:120}"
  else ko "incorrect resume (finish=$f2). Response: ${r2:0:300}"; close_suspended "$msgs" "$r2" >/dev/null; fi
else
  ko "skipped (test 6 failed)"
fi

title "8. SSE streaming with tool_calls"
msgs=$(user_msg "What time is it in Lyon? Use the get_time tool.")
s=$(curl -sS -N --max-time "$TIMEOUT" "$BASE/v1/chat/completions" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" -d "$(body "$msgs" "$TOOLS" true)")
if grep -q '"finish_reason":"tool_calls"' <<<"$s" && grep -q '\[DONE\]' <<<"$s"; then
  ok "valid SSE stream (tool_calls + [DONE])"
  first=$(grep '^data: {' <<<"$s" | head -1 | sed 's/^data: //')
  tc=$(jq '.choices[0].delta.tool_calls | map(del(.index))' <<<"$first")
  fake=$(jq -n --argjson tc "$tc" '{choices:[{finish_reason:"tool_calls", message:{tool_calls:$tc}}]}')
  close_suspended "$msgs" "$fake" >/dev/null
else
  ko "unexpected SSE stream: ${s:0:300}"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
if [ "$CRIT" -gt 0 ]; then
  echo "🚨 Isolation compromised: the model can act on your machine. Do NOT run Strix."
  exit 2
elif [ "$FAIL" -eq 0 ]; then
  echo "All good: you can run Strix on a first repo with --scan-mode quick."
fi
exit $(( FAIL > 0 ))
