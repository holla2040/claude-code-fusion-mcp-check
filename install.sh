#!/usr/bin/env bash
# Make the Fusion MCP connection survive reboots, and register it for every project.
# Idempotent -- safe to re-run.
set -euo pipefail

PORT=27182
URL="http://127.0.0.1:${PORT}/mcp"
BIN="$HOME/.local/bin/fusion-mcp-proxy.sh"
UNIT="$HOME/.config/systemd/user/fusion-mcp-proxy.service"
SYS=/mnt/c/Windows/System32

command -v socat >/dev/null || { echo "socat is required: sudo apt install socat" >&2; exit 1; }

mkdir -p "$(dirname "$BIN")" "$(dirname "$UNIT")"

cat > "$BIN" <<'EOF'
#!/bin/sh
# Fusion MCP runs on the Windows host. Two things about the add-in (NsMCP10.dll)
# shape everything here:
#
#   1. It binds 127.0.0.1 ONLY. There is no 0.0.0.0 anywhere in the DLL, so WSL
#      cannot reach it at the gateway IP without a netsh portproxy rule on the
#      Windows side bridging gateway:27182 -> 127.0.0.1:27182.
#   2. It does DNS-rebinding protection and accepts ONLY "Host: 127.0.0.1:27182",
#      so we have to listen on WSL loopback to make the client send that header.
#
# The trap: WSL's localhost forwarding republishes our listener back onto the
# Windows side as wslrelay.exe. If we bind 27182 before the add-in does, the
# add-in finds the port taken and SILENTLY falls back to a random port, and the
# portproxy rule then forwards traffic into wslrelay -> us -> gateway -> loop.
# So we never bind until the add-in already owns the Windows side, and we let go
# the moment it does not.
PORT=27182
SYS=/mnt/c/Windows/System32

GW=$(ip route show default | awk '{print $3; exit}')
[ -n "$GW" ] || { echo "no default gateway" >&2; exit 1; }

# Windows lets wslrelay.exe co-bind 127.0.0.1:27182 alongside the add-in, so netstat
# routinely lists TWO holders and their order is not stable. Asking "who is the
# holder" therefore flip-flops; the only stable question is "is Fusion among them".
# Whoever bound FIRST keeps receiving the traffic, which is why the wait below
# matters: as long as the add-in got there first, a co-bound relay is harmless.
holders() {
  "$SYS/NETSTAT.EXE" -ano 2>/dev/null | tr -d '\r' \
    | awk -v a="127.0.0.1:$PORT" '$1=="TCP" && $2==a && $4=="LISTENING" {print $5}'
}
owner_name() {
  [ -n "$1" ] || return 1
  "$SYS/tasklist.exe" /FI "PID eq $1" /FO CSV /NH 2>/dev/null | tr -d '\r' \
    | head -n1 | cut -d, -f1 | tr -d '"'
}
fusion_holds() {
  for p in $(holders); do
    [ "$(owner_name "$p")" = "Fusion360.exe" ] && return 0
  done
  return 1
}

if ! fusion_holds; then
  echo "waiting: Fusion add-in does not hold 127.0.0.1:$PORT yet (holders: $(holders | tr '\n' ' '))" >&2
  exit 1   # Restart=always retries; the port stays free for the add-in meanwhile
fi

socat TCP-LISTEN:$PORT,bind=127.0.0.1,fork,reuseaddr "TCP:$GW:$PORT" &
SOCAT=$!
trap 'kill $SOCAT 2>/dev/null' INT TERM EXIT

# Release the port as soon as the add-in lets go of it -- otherwise the next
# Fusion restart finds 27182 occupied by us and drifts to a dynamic port again.
# Tolerate one bad reading: tearing the proxy down costs a 15s outage, and a
# single hiccup in the netstat pipeline is not evidence the add-in went away.
MISSES=0
while sleep 30; do
  kill -0 "$SOCAT" 2>/dev/null || exit 1
  if fusion_holds; then
    MISSES=0
  else
    MISSES=$((MISSES + 1))
    if [ "$MISSES" -ge 2 ]; then
      echo "add-in released $PORT (holders: $(holders | tr '\n' ' ')); releasing proxy" >&2
      exit 1
    fi
  fi
done
EOF
chmod +x "$BIN"

cat > "$UNIT" <<'EOF'
[Unit]
Description=Fusion MCP loopback proxy (WSL -> Windows host)
After=network.target
# The proxy exits on purpose whenever Fusion is not holding the port, so restarts
# are the normal idle state, not a failure. Never give up on them.
StartLimitIntervalSec=0

[Service]
ExecStart=%h/.local/bin/fusion-mcp-proxy.sh
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
EOF

# A hand-started socat would hold the port and the unit would fail to bind.
pkill -f "socat TCP-LISTEN:${PORT}" 2>/dev/null || true
sleep 1

systemctl --user daemon-reload
systemctl --user enable --now fusion-mcp-proxy.service

# The Windows half cannot be installed from here: the portproxy rule needs an
# elevated shell. Say so explicitly rather than leaving it to check.sh to find.
if [ -x "$SYS/netsh.exe" ]; then
  GW=$(ip route show default | awk '{print $3; exit}')
  # columns: listen-address  listen-port  connect-address  connect-port
  RULE=$("$SYS/netsh.exe" interface portproxy show all 2>/dev/null | tr -d '\r' \
    | awk -v p="$PORT" '$2==p && $3=="127.0.0.1" {print $1; exit}')
  if [ "$RULE" != "$GW" ]; then
    echo
    echo "ON WINDOWS (Administrator PowerShell) -- the add-in is loopback-only, so this"
    echo "rule is what lets WSL reach it at all:"
    [ -n "$RULE" ] && echo "  netsh interface portproxy delete v4tov4 listenaddress=$RULE listenport=$PORT"
    echo "  netsh interface portproxy add v4tov4 listenaddress=$GW listenport=$PORT connectaddress=127.0.0.1 connectport=$PORT"
  fi
fi

# User scope, so every project gets it without being registered one at a time.
if claude mcp list 2>/dev/null | grep -q '^fusion:'; then
  echo "claude: fusion already registered"
else
  claude mcp add --scope user --transport http fusion "$URL"
fi

echo
echo "Done. Verify with ./check.sh"
echo "Restart any running Claude Code session -- MCP servers attach at session start."
