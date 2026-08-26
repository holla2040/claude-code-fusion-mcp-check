#!/usr/bin/env bash
# Make the Fusion MCP connection survive reboots, and register it for every project.
# Idempotent -- safe to re-run.
set -euo pipefail

PORT=27182
URL="http://127.0.0.1:${PORT}/mcp"
BIN="$HOME/.local/bin/fusion-mcp-proxy.sh"
UNIT="$HOME/.config/systemd/user/fusion-mcp-proxy.service"
SYS=/mnt/c/Windows/System32

register() { # user scope, so every project gets it without per-project setup
  if claude mcp list 2>/dev/null | grep -q "$URL"; then
    echo "claude: a registration already points at $URL"
  else
    claude mcp add --scope user --transport http fusion "$URL"
  fi
}

# Mirrored networking shares the Windows loopback: 127.0.0.1:27182 reaches the
# add-in directly with the right Host header, so the socat proxy and the netsh
# portproxy rule are not just unnecessary -- leftovers of either actively break
# the link (a stale 0.0.0.0 rule steals the add-in's bind; a WSL proxy would
# fight it for the shared port). Install nothing; remove what a NAT-era run left.
MODE=$(wslinfo --networking-mode 2>/dev/null || echo nat)
if [ "$MODE" = "mirrored" ]; then
  echo "mirrored WSL networking: no proxy or portproxy needed -- removing NAT-era leftovers"
  systemctl --user disable --now fusion-mcp-proxy.service 2>/dev/null || true
  rm -f "$BIN" "$UNIT"
  systemctl --user daemon-reload 2>/dev/null || true
  if [ -x "$SYS/netsh.exe" ]; then
    LEFTOVER=$("$SYS/netsh.exe" interface portproxy show all 2>/dev/null | tr -d '\r' \
      | awk -v p="$PORT" '$2==p {print $1}')
    if [ -n "$LEFTOVER" ]; then
      echo
      echo "ON WINDOWS (Administrator PowerShell) -- stale portproxy rules that will steal"
      echo "the add-in's bind; delete them, then reload the MCP add-in in Fusion:"
      for a in $LEFTOVER; do
        echo "  netsh interface portproxy delete v4tov4 listenaddress=$a listenport=$PORT"
      done
    fi
  fi
  register
  echo
  echo "Done. Verify with ./check.sh"
  exit 0
fi

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

SOCAT=""
start_socat() {
  socat TCP-LISTEN:$PORT,bind=127.0.0.1,fork,reuseaddr "TCP:$GW:$PORT" &
  SOCAT=$!
}
stop_socat() {
  [ -n "$SOCAT" ] || return 0
  kill "$SOCAT" 2>/dev/null
  wait "$SOCAT" 2>/dev/null
  SOCAT=""
}
trap 'stop_socat; exit 0' INT TERM

# Supervise in-process instead of exiting and leaning on Restart=always. Both ends
# of a teardown are user-visible: every second we keep 27182 after the add-in drops
# it is a second the add-in can lose the port to WSL's relay on its way back, and
# every second before we rebind is a failing MCP call. A RestartSec pause sits in
# the middle of both, so the loop stays resident and handles the transitions itself.
#
# A netstat poll costs ~35ms, so 5s cadence is nearly free -- and it is fast enough
# to hand the port back before a restarting Fusion tries to claim it, which is what
# makes a full Fusion restart survivable without human intervention.
POLL=5
MISS_LIMIT=2   # consecutive bad readings before believing the add-in is really gone
MISSES=0
WAITING=0

while true; do
  if fusion_holds; then
    MISSES=0
    if [ -n "$SOCAT" ] && ! kill -0 "$SOCAT" 2>/dev/null; then
      echo "socat exited unexpectedly; rebinding" >&2
      SOCAT=""
    fi
    if [ -z "$SOCAT" ]; then
      start_socat
      echo "add-in holds $PORT; listening on 127.0.0.1:$PORT -> $GW:$PORT" >&2
      WAITING=0
    fi
  else
    MISSES=$((MISSES + 1))
    if [ "$MISSES" -ge "$MISS_LIMIT" ]; then
      if [ -n "$SOCAT" ]; then
        echo "add-in released $PORT (holders: $(holders | tr '\n' ' ')); handing the port back" >&2
        stop_socat
      fi
      if [ "$WAITING" = 0 ]; then
        echo "waiting for the Fusion add-in to hold 127.0.0.1:$PORT" >&2
        WAITING=1
      fi
    fi
  fi
  sleep "$POLL"
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
systemctl --user enable fusion-mcp-proxy.service
# restart, not "enable --now": --now is a no-op on an already-running unit, which
# silently leaves the OLD proxy script resident after this script rewrites it.
systemctl --user restart fusion-mcp-proxy.service

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

register

echo
echo "Done. Verify with ./check.sh"
echo "Restart any running Claude Code session -- MCP servers attach at session start."
