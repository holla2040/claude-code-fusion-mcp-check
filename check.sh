#!/usr/bin/env bash
# Diagnose the Claude Code -> Fusion MCP connection from WSL, one layer at a time.
# Exits non-zero on the first layer that is actually broken, and says what to do --
# including the steps that can only be carried out on the Windows side.
#
# Usage: ./check.sh [--quiet]
set -uo pipefail

PORT=27182
URL="http://127.0.0.1:${PORT}/mcp"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# NAT and mirrored WSL networking need opposite plumbing. NAT: loopback is
# unreachable, so a Windows portproxy rule + a WSL socat proxy carry the traffic.
# Mirrored: WSL shares the Windows loopback, 127.0.0.1:27182 reaches the add-in
# directly, and any leftover NAT-era plumbing actively breaks the link (a stale
# 0.0.0.0 portproxy rule steals the add-in's bind -- that happened 2026-08-25).
MODE=$(wslinfo --networking-mode 2>/dev/null || echo nat)

# Other projects call this script from their own directory, so every command we
# suggest has to be runnable from wherever the caller happens to be standing.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL="$SELF_DIR/install.sh"

SYS=/mnt/c/Windows/System32
NETSTAT="$SYS/NETSTAT.EXE"
TASKLIST="$SYS/tasklist.exe"
NETSH="$SYS/netsh.exe"
WINCURL="$SYS/curl.exe"

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
step() { [ "$QUIET" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }
fix()  { printf '       \033[36m->\033[0m %s\n' "$1"; }
# Anything that cannot be done from inside WSL gets flagged loudly, because that is
# the class of failure that otherwise turns into a scavenger hunt.
winhdr() { printf '\n       \033[1;33mON WINDOWS (not in WSL):\033[0m %s\n' "$1"; }
wincmd() { printf '         \033[35m%s\033[0m\n' "$1"; }
winnote(){ printf '         %s\n' "$1"; }

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"fusion-mcp-check","version":"1"}}}'

rpc() { # rpc <body> [session-id] ; prints body then http code on the last line
  local body="$1" sid="${2:-}" args=(-s -m 10 -o /dev/stdout -w '\n%{http_code}'
    -X POST "$URL" -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream')
  [ -n "$sid" ] && args+=(-H "Mcp-Session-Id: $sid")
  curl "${args[@]}" -d "$body" 2>/dev/null
}

have_interop() { [ -x "$NETSTAT" ] && [ -x "$TASKLIST" ]; }

# Every PID listening on Windows loopback :PORT -- there can legitimately be more
# than one. No early awk exit: that closes the pipe under netstat and leaks
# "tr: write error: Broken pipe" into the output.
win_owner_pid() {
  "$NETSTAT" -ano 2>/dev/null | tr -d '\r' \
    | awk -v a="127.0.0.1:$PORT" '$1=="TCP" && $2==a && $4=="LISTENING" {print $5}'
}

win_proc_name() { # win_proc_name <pid>
  [ -n "${1:-}" ] || return 1
  "$TASKLIST" /FI "PID eq $1" /FO CSV /NH 2>/dev/null | tr -d '\r' \
    | head -n1 | cut -d, -f1 | tr -d '"'
}

wsl_listening() {
  awk -v p="$(printf '%04X' "$PORT")" \
    '$4=="0A" && $2=="0100007F:"p {f=1} END {exit !f}' /proc/net/tcp
}

fusion_pids() {
  "$TASKLIST" /FI "IMAGENAME eq Fusion360.exe" /FO CSV /NH 2>/dev/null | tr -d '\r' \
    | grep -i 'Fusion360.exe' | cut -d, -f2 | tr -d '"'
}

# A 0.0.0.0 listener covers loopback too, so it steals the bind from the add-in
# even though win_owner_pid (which matches 127.0.0.1:PORT exactly) sees nothing.
# In practice the culprit is svchost holding a stale "0.0.0.0 -> 127.0.0.1" netsh
# portproxy rule left over from a NAT-era install -- a self-loop that also hangs
# every connection it does receive.
win_wildcard_pid() {
  "$NETSTAT" -ano 2>/dev/null | tr -d '\r' \
    | awk -v a="0.0.0.0:$PORT" '$1=="TCP" && $2==a && $4=="LISTENING" {print $5}'
}

portproxy_listeners() { # every portproxy listen-address on $PORT, one per line
  "$NETSH" interface portproxy show all 2>/dev/null | tr -d '\r' \
    | awk -v p="$PORT" '$2==p {print $1}'
}

# When 27182 is already taken the add-in does not fail loudly -- it binds a random
# port instead. Finding that port is what proves "the add-in is loaded but homeless"
# rather than "the add-in is not running", which need completely different fixes.
# Fusion can host OTHER MCP servers in the same process (the AutodeskFusionMCP
# Python add-in lives on its own configured port, 8765 by default), so answering
# 200 is not enough -- only serverInfo "MCP Server Adapter" is this add-in.
addin_dynamic_port() {
  local pid ports prt body
  for pid in $(fusion_pids); do
    ports=$("$NETSTAT" -ano 2>/dev/null | tr -d '\r' \
      | awk -v p="$pid" '$1=="TCP" && $4=="LISTENING" && $5==p && $2 ~ /^127\.0\.0\.1:/ {sub(/.*:/,"",$2); print $2}')
    for prt in $ports; do
      [ "$prt" = "$PORT" ] && continue
      body=$("$WINCURL" -s -m 3 -X POST "http://127.0.0.1:$prt/mcp" \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -d "$INIT" 2>/dev/null | tr -d '\r')
      printf '%s' "$body" | grep -q '"name": *"MCP Server Adapter"' && { echo "$prt"; return 0; }
    done
  done
  return 1
}

# ---------------------------------------------------------------- 1. gateway
step "1. WSL -> Windows host"
GW=$(ip route show default | awk '{print $3; exit}')
if [ "$MODE" = "mirrored" ]; then
  # In mirrored mode the default gateway is the LAN router, NOT the Windows
  # host -- never aim anything at it. Loopback is the route to Windows.
  pass "mirrored networking -- WSL shares the Windows loopback (gateway $GW is the LAN router, ignore it)"
elif [ -z "$GW" ]; then
  fail "no default gateway; WSL has no route to the Windows host"
  exit 1
else
  pass "NAT networking -- Windows host at gateway $GW"
fi

if ! have_interop; then
  warn "no Windows interop (/mnt/c not mounted?) -- skipping Windows-side checks"
  warn "layers 2 and 3 are the ones that usually break; they cannot be checked from here"
fi

# ------------------------------------------- 2. who owns Windows loopback:PORT
# The add-in binds 127.0.0.1 ONLY (there is no 0.0.0.0 in NsMCP10.dll), and it
# silently falls back to a dynamic port when 27182 is occupied. Meanwhile WSL's
# localhost forwarding republishes any WSL listener on 127.0.0.1:27182 back onto
# the Windows side as wslrelay.exe. So if the WSL proxy binds before the add-in
# does, the add-in loses the port and every request loops WSL -> Windows -> WSL.
step "2. Windows side: who owns 127.0.0.1:$PORT"
if have_interop; then
  # Windows lets wslrelay.exe co-bind the same address:port as the add-in, so there
  # can be TWO holders and netstat's order between them is not stable. "Is Fusion
  # among the holders" is the only question with a stable answer.
  HOLDERS=$(win_owner_pid)
  FUSION_HOLDER=""
  OTHERS=""
  for p in $HOLDERS; do
    n=$(win_proc_name "$p")
    if [ "$n" = "Fusion360.exe" ]; then FUSION_HOLDER="$p"; else OTHERS="$OTHERS $n($p)"; fi
  done
  if [ -n "$FUSION_HOLDER" ]; then
    pass "Fusion add-in holds 127.0.0.1:$PORT (PID $FUSION_HOLDER)"
    [ -n "$OTHERS" ] && warn "co-bound:$OTHERS -- harmless, the add-in bound first and keeps the traffic"
  elif printf '%s' "$OTHERS" | grep -q wslrelay; then
      fail "wslrelay.exe holds 127.0.0.1:$PORT and the add-in does not -- WSL took the port"
      DYN=$(addin_dynamic_port) && \
        fix "The add-in IS loaded, but fell back to dynamic port $DYN. Fusion is fine; the port is the problem."
      fix "Cause: the WSL proxy bound $PORT before Fusion's add-in could. Order matters."
      fix "systemctl --user stop fusion-mcp-proxy.service   # release the port first"
      winhdr "then restart the MCP server so it can claim $PORT"
      winnote "Fusion 360 -> Preferences -> General -> API -> untick and re-tick 'Fusion MCP Server'"
      winnote "(or restart Fusion 360)."
      fix "$INSTALL   # reinstall the proxy so it waits for the add-in instead of racing it"
      exit 1
  elif [ -z "$HOLDERS" ]; then
    WILD=$(win_wildcard_pid)
    if [ -n "$WILD" ]; then
      # The classic post-mode-switch failure: a stale portproxy rule's 0.0.0.0
      # listener covers loopback, so the add-in can never (re)claim the port no
      # matter how many times it is reloaded. Reloading is useless until the
      # rule is gone -- print the deletes FIRST.
      WNAMES=""; for p in $WILD; do WNAMES="$WNAMES $(win_proc_name "$p")($p)"; done
      fail "0.0.0.0:$PORT is held by${WNAMES} -- a wildcard bind covers loopback, so the add-in cannot claim the port"
      fix "Almost always a stale netsh portproxy rule (svchost owns those listeners)."
      winhdr "delete the stale rule(s) in an Administrator PowerShell, THEN reload the add-in"
      PPADDRS=$(portproxy_listeners)
      if [ -n "$PPADDRS" ]; then
        for a in $PPADDRS; do
          wincmd "netsh interface portproxy delete v4tov4 listenaddress=$a listenport=$PORT"
        done
      else
        winnote "(no portproxy rule found -- stop the process holding 0.0.0.0:$PORT instead)"
      fi
      winnote "then: Fusion 360 -> Preferences -> General -> API -> untick and re-tick 'Fusion MCP Server'."
      exit 1
    fi
    if [ -n "$(fusion_pids)" ]; then
      fail "nothing is listening on Windows 127.0.0.1:$PORT, but Fusion 360 is running"
      DYN=$(addin_dynamic_port) && \
        fix "The add-in is on dynamic port $DYN -- something took $PORT while it was starting."
      winhdr "restart the MCP server"
      winnote "Fusion 360 -> Preferences -> General -> API -> untick and re-tick 'Fusion MCP Server'"
      winnote "(the port lives right there too -- it must match PORT=$PORT in this script)."
    else
      fail "Fusion 360 is not running on Windows"
      winhdr "start Fusion 360"
      winnote "The add-in only listens while Fusion is open, and its tools need an open document."
    fi
    exit 1
  else
    fail "${OTHERS# } holds 127.0.0.1:$PORT -- not the Fusion add-in"
    winhdr "stop that process, then reload the MCP add-in in Fusion 360"
    for p in $HOLDERS; do wincmd "taskkill /PID $p /F"; done
    exit 1
  fi
fi

# --------------------------------------------------- 3. Windows portproxy rule
# NAT: the add-in is loopback-only on the Windows side, so WSL cannot reach it at
# the gateway IP without a portproxy rule bridging gateway:PORT -> 127.0.0.1:PORT.
# That rule lives in the registry and survives reboots, but it is pinned to one
# gateway IP -- and that IP changes across reboots under NAT networking.
# Mirrored: the OPPOSITE. Loopback already reaches the add-in, and any rule on the
# port is a leftover that can only hurt -- a 0.0.0.0 one steals the add-in's bind
# outright, and a gateway-IP one now names the LAN router. None may exist.
if [ "$MODE" = "mirrored" ]; then
  step "3. Windows portproxy rules on :$PORT (mirrored mode: there must be none)"
  if have_interop; then
    PPADDRS=$(portproxy_listeners)
    if [ -n "$PPADDRS" ]; then
      fail "leftover NAT-era portproxy rule(s) exist on :$PORT -- mirrored mode neither needs nor tolerates them"
      winhdr "delete them in an Administrator PowerShell"
      for a in $PPADDRS; do
        wincmd "netsh interface portproxy delete v4tov4 listenaddress=$a listenport=$PORT"
      done
      exit 1
    fi
    pass "no portproxy rules on :$PORT"
  fi
else
  step "3. Windows portproxy rule (${GW}:${PORT} -> 127.0.0.1:${PORT})"
  if have_interop; then
    RULES=$("$NETSH" interface portproxy show all 2>/dev/null | tr -d '\r')
    # columns: listen-address  listen-port  connect-address  connect-port
    RULE_ADDR=$(printf '%s' "$RULES" | awk -v p="$PORT" '$2==p && $3=="127.0.0.1" {print $1; exit}')
    ADDCMD="netsh interface portproxy add v4tov4 listenaddress=$GW listenport=$PORT connectaddress=127.0.0.1 connectport=$PORT"
    if [ -z "$RULE_ADDR" ]; then
      fail "no portproxy rule forwarding to 127.0.0.1:$PORT"
      winhdr "add it in an Administrator PowerShell (needs elevation, survives reboots)"
      wincmd "$ADDCMD"
      exit 1
    elif [ "$RULE_ADDR" != "$GW" ]; then
      fail "portproxy rule points at $RULE_ADDR, but the gateway is now $GW (it changes across reboots)"
      winhdr "repoint it in an Administrator PowerShell"
      wincmd "netsh interface portproxy delete v4tov4 listenaddress=$RULE_ADDR listenport=$PORT"
      wincmd "$ADDCMD"
      exit 1
    fi
    pass "portproxy rule present: ${RULE_ADDR}:${PORT} -> 127.0.0.1:${PORT}"
  fi
fi

# ------------------------------------------------- 4. reachability from WSL
step "4. Fusion MCP server reachable from WSL"
if [ "$MODE" = "mirrored" ]; then
  # Mirrored: 127.0.0.1 IS the Windows loopback, so the Host header is right by
  # construction and no proxy sits in between -- probe the real URL directly.
  CODE=$(curl -s -m 6 -o /dev/null -w '%{http_code}' -X POST "$URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "$INIT" 2>/dev/null)
  RC=$?
  if [ "$CODE" != "200" ]; then
    case "$RC" in
      7)  fail "connection to $URL refused, though layer 2 saw the add-in holding the Windows port"
          fix "Mirrored loopback sharing may be broken -- re-run after 'wsl.exe --shutdown' from PowerShell." ;;
      28) fail "connection to $URL accepted but never answered (timeout)"
          fix "Something else is intercepting WSL loopback :$PORT -- check for a leftover proxy: systemctl --user status fusion-mcp-proxy.service" ;;
      *)  fail "no MCP server answering on $URL (http '${CODE:-none}', curl exit $RC)" ;;
    esac
    exit 1
  fi
  pass "server answers 200 on $URL (shared loopback, no proxy needed)"
else
  HOSTCODE=$(curl -s -m 6 -o /dev/null -w '%{http_code}' -X POST "http://${GW}:${PORT}/mcp" \
    -H 'Host: 127.0.0.1:'"$PORT" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -d "$INIT" 2>/dev/null)
  RC=$?
  if [ "$HOSTCODE" != "200" ]; then
    case "$RC" in
      # Refused and timed-out look identical in the HTTP code (both "000") but mean
      # opposite things: nobody home vs. somebody accepting and never answering.
      7)  fail "connection to ${GW}:${PORT} refused -- nothing is accepting there"
          fix "Layers 2 and 3 passed, so re-run $SELF_DIR/check.sh; the portproxy rule may have just been removed." ;;
      28) fail "connection to ${GW}:${PORT} accepted but never answered (timeout) -- this is a forwarding loop"
          fix "Traffic is going WSL -> gateway -> portproxy -> back into WSL instead of reaching Fusion."
          fix "systemctl --user stop fusion-mcp-proxy.service && $INSTALL" ;;
      *)  fail "no MCP server answering on ${GW}:${PORT} (http '${HOSTCODE:-none}', curl exit $RC)" ;;
    esac
    exit 1
  fi
  pass "server answers 200 to Host: 127.0.0.1:$PORT"
fi

# ------------------------------------------------------------------ 5. proxy
# NAT: the add-in does DNS-rebinding protection and accepts ONLY
# "Host: 127.0.0.1:27182"; a direct WSL connection to the gateway sends
# "Host: <gw>:27182" and gets 403. The socat proxy exists purely to fix that
# header. Mirrored: the proxy is not just unnecessary -- if it ever bound WSL
# loopback :27182 it would fight the add-in for the shared port, so the unit
# must be gone.
if [ "$MODE" = "mirrored" ]; then
  step "5. Loopback proxy (mirrored mode: there must be none)"
  if systemctl --user is-active --quiet fusion-mcp-proxy.service 2>/dev/null || \
     systemctl --user is-enabled --quiet fusion-mcp-proxy.service 2>/dev/null; then
    fail "the NAT-era fusion-mcp-proxy unit is still installed -- on shared loopback it can steal :$PORT from the add-in"
    fix "systemctl --user disable --now fusion-mcp-proxy.service"
    fix "rm -f ~/.config/systemd/user/fusion-mcp-proxy.service ~/.local/bin/fusion-mcp-proxy.sh && systemctl --user daemon-reload"
    exit 1
  fi
  pass "no proxy unit installed (correct for mirrored mode)"
else
  step "5. Loopback proxy (127.0.0.1:$PORT -> ${GW}:${PORT})"
  DIRECT=$(curl -s -m 6 -o /dev/null -w '%{http_code}' -X POST "http://${GW}:${PORT}/mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "$INIT" 2>/dev/null)
  [ "$DIRECT" = "403" ] && pass "confirmed: direct gateway URL is rejected (403), proxy is required"

  # "the unit is active" is NOT the same as "the port is bound": the supervisor stays
  # resident while it waits for the add-in, so ask the kernel rather than systemd.
  # (Note: `ss` is aliased to gnome-screenshot in some interactive shells here, which
  # makes a manual `ss -ltnp | grep 27182` silently print nothing. /proc is honest.)
  if wsl_listening; then
    pass "127.0.0.1:$PORT is bound in WSL"
    if ! systemctl --user is-active --quiet fusion-mcp-proxy.service 2>/dev/null; then
      warn "bound by something other than the systemd unit -- it will not survive a reboot"
      fix "$INSTALL   # make it durable"
    fi
  else
    fail "nothing is listening on 127.0.0.1:$PORT"
    if systemctl --user is-active --quiet fusion-mcp-proxy.service 2>/dev/null; then
      fix "The unit is running but has not bound -- it waits for the add-in to hold the"
      fix "Windows port before taking 27182. Layer 2 above says whether it does."
    else
      fix "$INSTALL   # installs and starts the proxy"
    fi
    exit 1
  fi
fi

# ------------------------------------------------------- 6. MCP handshake
step "6. MCP handshake on $URL"
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

# ------------------------------------------------- 7. Claude Code registration
# The registration name varies by machine ("fusion" here, "autodesk-fusion"
# elsewhere) -- what matters is that SOME entry points at $URL and connects.
step "7. Claude Code registration"
MCPLIST=$(claude mcp list 2>/dev/null)
REGLINE=$(printf '%s\n' "$MCPLIST" | grep -F "$URL" | head -n1)
if printf '%s' "$REGLINE" | grep -q 'Connected'; then
  pass "claude mcp list: ${REGLINE%%:*} -> $URL connected"
else
  if [ -z "$REGLINE" ]; then
    fail "no Claude Code registration points at $URL"
    fix "claude mcp add --scope user --transport http fusion $URL"
  else
    fail "registration exists but is not connected: $REGLINE"
    fix "claude mcp remove ${REGLINE%%:*} && claude mcp add --scope user --transport http ${REGLINE%%:*} $URL"
  fi
  exit 1
fi

# Any entry (any name, user scope or per-project) whose URL is not literally
# 127.0.0.1 for this port cannot be trusted: a gateway IP is NAT-era residue
# (403s in NAT, points at the LAN router in mirrored), and "localhost" resolves
# IPv6-first to ::1, which hangs against these IPv4-only listeners. Only the
# explicit IPv4 loopback works everywhere.
STALE=$(python3 - "$PORT" <<'PY' 2>/dev/null
import json,os,sys
port=sys.argv[1]
p=os.path.expanduser('~/.claude.json')
try: d=json.load(open(p))
except Exception: raise SystemExit
def scan(servers,where):
    for name,f in (servers or {}).items():
        u=(f or {}).get('url') or ''
        if f":{port}" in u and '127.0.0.1' not in u:
            print(f"{where}: {name} -> {u}")
scan(d.get('mcpServers'),'user scope')
for k,v in (d.get('projects') or {}).items():
    scan((v or {}).get('mcpServers'),k)
PY
)
if [ -n "$STALE" ]; then
  warn "entries not using 127.0.0.1 for :$PORT (gateway IPs are stale; localhost resolves to ::1 and hangs):"
  printf '%s\n' "$STALE" | sed 's/^/         /'
  fix "Repoint them at $URL, or delete them -- the user-scope entry covers every project."
fi

printf '\n\033[32mFusion MCP is reachable.\033[0m\n'
printf 'If a session still cannot see the tools, that session has to be restarted.\n'
printf 'Reloading the add-in or restarting Fusion DEREGISTERS the tools from every\n'
printf 'already-running Claude Code session -- the transport recovers on its own, the\n'
printf 'client does not. `claude --continue` keeps the conversation.\n'
