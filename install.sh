#!/usr/bin/env bash
# Make the Fusion MCP connection survive reboots, and register it for every project.
# Idempotent -- safe to re-run.
set -euo pipefail

PORT=27182
URL="http://127.0.0.1:${PORT}/mcp"
BIN="$HOME/.local/bin/fusion-mcp-proxy.sh"
UNIT="$HOME/.config/systemd/user/fusion-mcp-proxy.service"

command -v socat >/dev/null || { echo "socat is required: sudo apt install socat" >&2; exit 1; }

mkdir -p "$(dirname "$BIN")" "$(dirname "$UNIT")"

cat > "$BIN" <<'EOF'
#!/bin/sh
# Fusion MCP runs on the Windows host. Its add-in (NsMCP10.dll) does DNS-rebinding
# protection and accepts ONLY "Host: 127.0.0.1:27182", so WSL cannot reach it
# directly at the gateway IP -- that returns 403 {"error": "Invalid Host header"}.
# Listening on WSL loopback makes the client send the one Host value it accepts.
# The gateway IP changes between reboots under NAT networking, so resolve it now.
GW=$(ip route show default | awk '{print $3; exit}')
[ -n "$GW" ] || { echo "no default gateway" >&2; exit 1; }
exec socat TCP-LISTEN:27182,bind=127.0.0.1,fork,reuseaddr "TCP:$GW:27182"
EOF
chmod +x "$BIN"

cat > "$UNIT" <<'EOF'
[Unit]
Description=Fusion MCP loopback proxy (WSL -> Windows host)
After=network.target

[Service]
ExecStart=%h/.local/bin/fusion-mcp-proxy.sh
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

# A hand-started socat would hold the port and the unit would fail to bind.
pkill -f "socat TCP-LISTEN:${PORT}" 2>/dev/null || true
sleep 1

systemctl --user daemon-reload
systemctl --user enable --now fusion-mcp-proxy.service
sleep 1
systemctl --user is-active --quiet fusion-mcp-proxy.service \
  && echo "proxy: active" || { echo "proxy failed to start" >&2; exit 1; }

# User scope, so every project gets it without being registered one at a time.
if claude mcp list 2>/dev/null | grep -q '^fusion:'; then
  echo "claude: fusion already registered"
else
  claude mcp add --scope user --transport http fusion "$URL"
fi

echo
echo "Done. Verify with ./check.sh"
echo "Restart any running Claude Code session -- MCP servers attach at session start."
