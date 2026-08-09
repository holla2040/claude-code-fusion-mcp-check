#!/usr/bin/env bash
# Diagnose the Claude Code -> Fusion MCP connection from WSL, one layer at a time.
# Exits non-zero on the first layer that is actually broken, and says what to do.
#
# Usage: ./check.sh [--quiet]
set -uo pipefail

PORT=27182
URL="http://127.0.0.1:${PORT}/mcp"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
step() { [ "$QUIET" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }
fix()  { printf '       \033[36m->\033[0m %s\n' "$1"; }

rpc() { # rpc <body> [session-id] ; prints body, sets RPC_CODE
  local body="$1" sid="${2:-}" args=(-s -m 10 -o /dev/stdout -w '\n%{http_code}'
    -X POST "$URL" -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream')
  [ -n "$sid" ] && args+=(-H "Mcp-Session-Id: $sid")
  curl "${args[@]}" -d "$body" 2>/dev/null
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"fusion-mcp-check","version":"1"}}}'

# ---------------------------------------------------------------- 1. gateway
step "1. WSL -> Windows host"
GW=$(ip route show default | awk '{print $3; exit}')
if [ -z "$GW" ]; then
  fail "no default gateway; WSL has no route to the Windows host"
  exit 1
fi
pass "gateway $GW"

# ------------------------------------------------------------ 2. Fusion side
step "2. Fusion MCP server (Windows side, port $PORT)"
HOSTCODE=$(curl -s -m 6 -o /dev/null -w '%{http_code}' -X POST "http://${GW}:${PORT}/mcp" \
  -H 'Host: 127.0.0.1:'"$PORT" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -d "$INIT" 2>/dev/null)
if [ "$HOSTCODE" != "200" ]; then
  fail "no MCP server answering on ${GW}:${PORT} (got '${HOSTCODE:-no response}')"
  fix "Start Fusion 360 on Windows and make sure the MCP add-in is loaded."
  fix "The add-in only listens while Fusion is running."
  exit 1
fi
pass "Fusion MCP server is up and accepting Host: 127.0.0.1:$PORT"

# ------------------------------------------------------------------ 3. proxy
step "3. Loopback proxy (127.0.0.1:$PORT -> ${GW}:${PORT})"
# The add-in does DNS-rebinding protection: it accepts ONLY "Host: 127.0.0.1:27182".
# A direct WSL connection to the gateway IP sends "Host: <gw>:27182" and gets
# 403 {"error": "Invalid Host header"}. The proxy exists purely to fix that header.
DIRECT=$(curl -s -m 6 -o /dev/null -w '%{http_code}' -X POST "http://${GW}:${PORT}/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d "$INIT" 2>/dev/null)
[ "$DIRECT" = "403" ] && pass "confirmed: direct gateway URL is rejected (403), proxy is required"

if systemctl --user is-active --quiet fusion-mcp-proxy.service 2>/dev/null; then
  pass "systemd unit fusion-mcp-proxy.service is active"
elif pgrep -f "socat TCP-LISTEN:${PORT}" >/dev/null 2>&1; then
  warn "a manual socat is running, but no systemd unit -- it dies on reboot"
  fix "./install.sh   # make it durable"
else
  fail "nothing is listening on 127.0.0.1:$PORT"
  fix "./install.sh   # installs and starts the proxy"
  exit 1
fi

# ------------------------------------------------------- 4. MCP handshake
step "4. MCP handshake through the proxy"
HDRS=$(curl -s -m 8 -D - -o /dev/null -X POST "$URL" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -d "$INIT" 2>/dev/null)
SID=$(printf '%s' "$HDRS" | grep -i 'mcp-session-id' | tr -d '\r' | awk '{print $2}')
if [ -z "$SID" ]; then
  fail "initialize returned no Mcp-Session-Id"
  exit 1
fi
pass "initialize -> session $SID"

# tools/list returns an EMPTY list unless the session id is carried. Claude Code's
# client does this correctly; hand-rolled curl probes are what trip over it.
curl -s -m 6 -o /dev/null -X POST "$URL" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null

TOOLS=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "$SID" | head -n -1)
NAMES=$(printf '%s' "$TOOLS" | python3 -c '
import json,sys
try: t=json.load(sys.stdin)["result"]["tools"]
except Exception: sys.exit(1)
print("\n".join(x["name"] for x in t))
' 2>/dev/null)
COUNT=$(printf '%s' "$NAMES" | grep -c . || true)
if [ "${COUNT:-0}" -eq 0 ]; then
  fail "tools/list returned 0 tools"
  fix "Usually means the session id was not carried, or Fusion has no document open."
  exit 1
fi
pass "$COUNT tools exposed"
[ "$QUIET" = 1 ] || printf '%s\n' "$NAMES" | sed 's/^/         - /'

# ------------------------------------------------- 5. Claude Code registration
step "5. Claude Code registration"
if claude mcp list 2>/dev/null | grep -q '^fusion:.*Connected'; then
  pass "claude mcp list reports fusion connected"
else
  fail "Claude Code does not report fusion as connected"
  fix "claude mcp add --scope user --transport http fusion $URL"
  exit 1
fi

STALE=$(python3 - <<'PY' 2>/dev/null
import json,os
p=os.path.expanduser('~/.claude.json')
try: d=json.load(open(p))
except Exception: raise SystemExit
for k,v in (d.get('projects') or {}).items():
    f=((v.get('mcpServers') or {}).get('fusion') or {})
    if f.get('url') and '127.0.0.1' not in f['url']:
        print(f"{k} -> {f['url']}")
PY
)
if [ -n "$STALE" ]; then
  warn "project entries still pointing at the gateway IP (these will 403):"
  printf '%s\n' "$STALE" | sed 's/^/         /'
  fix "Repoint them at $URL, or delete them -- the user-scope entry covers every project."
fi

printf '\n\033[32mFusion MCP is reachable.\033[0m\n'
printf 'If the tools are missing inside a running Claude Code session, restart it:\n'
printf 'MCP servers attach at session start, so a mid-session fix is not picked up.\n'
