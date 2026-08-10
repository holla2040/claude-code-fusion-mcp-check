# Fix: the Fusion MCP loopback proxy on WSL cycles and drops the connection

## Environment

WSL2 on Windows. The Fusion 360 MCP add-in (`NsMCP10.dll`) runs on the Windows
side. The link has three layers:

1. **Add-in**: binds `127.0.0.1:27182` on Windows *only* — there is no `0.0.0.0`
   bind in the DLL. It also enforces DNS-rebinding protection and accepts only
   the header `Host: 127.0.0.1:27182`.
2. **netsh portproxy** on Windows bridges `172.17.64.1:27182 -> 127.0.0.1:27182`
   so WSL can reach it at the gateway IP.
3. **WSL-side socat proxy** listens on `127.0.0.1:27182` and forwards to the
   gateway. This exists so the MCP client sends the required `Host:` header.

Files involved:
- `~/.local/bin/fusion-mcp-proxy.sh`
- `~/.config/systemd/user/fusion-mcp-proxy.service` (user unit, `Restart=always`, `RestartSec=15`)
- `~/claude-code-fusion-mcp-check/check.sh` and `install.sh`

## Symptom

The proxy will not stay up. `systemctl --user is-active fusion-mcp-proxy.service`
reports `activating` indefinitely, nothing listens on `127.0.0.1:27182`, and the
unit restarts on a 15-second loop. Fusion MCP calls from Claude Code fail with
`Unable to connect` / `socket connection was closed unexpectedly`, sometimes
mid-session after working briefly.

Journal shows the proxy tearing *itself* down:

```
fusion-mcp-proxy.sh[109502]: add-in released 27182 (holder: 22004); releasing proxy
socat[109522] W exiting on signal 15
fusion-mcp-proxy.service: Main process exited, code=exited, status=1/FAILURE
```

## Root cause (already diagnosed — verify, don't re-derive)

**Two processes co-bind `127.0.0.1:27182` on Windows simultaneously**, and
netstat's ordering between them is not stable:

```
$ /mnt/c/Windows/System32/NETSTAT.EXE -ano | tr -d '\r' \
    | awk '$1=="TCP" && $2 ~ /:27182$/ && $4=="LISTENING" {print $2, $5}'
127.0.0.1:27182 37260      <- Fusion360.exe   (the real add-in)
127.0.0.1:27182 22004      <- wslrelay.exe    (WSL localhost forwarding)
172.17.64.1:27182 8288     <- the netsh portproxy
```

`wslrelay.exe` is WSL republishing our *own* socat listener back onto the Windows
side. So the moment the proxy binds, a second holder appears.

The proxy's health check asked **"is the same PID still the holder?"** — it took
the first netstat match at startup and compared it every 30 s. Because the two
holders' order is unstable, that check flip-flops, hits its miss threshold, and
the script exits deliberately. `Restart=always` brings it back, it binds, the
relay reappears, and it kills itself again. A self-inflicted oscillation.

The correct question is **"is Fusion360.exe among the holders?"** — a co-bound
relay is harmless, because whoever bound *first* keeps receiving the traffic, and
the script already refuses to start until the add-in holds the port.

## Task

1. **First inspect the current state of `fusion-mcp-proxy.sh`** — it may already
   contain a fix along these lines. Do not blindly re-apply.
2. Make the health check membership-based rather than identity-based, and make
   the startup gate use the same predicate.
3. Verify the fix actually holds under load, which is the part that was never
   confirmed:
   - `~/claude-code-fusion-mcp-check/check.sh` returns all green.
   - The proxy stays `active (running)` for **at least 15 minutes continuously**
     while MCP calls are being made — not just at one instant after a restart.
     Watch `journalctl --user -u fusion-mcp-proxy.service -f` for any
     "releasing proxy" line.
   - `ss -ltnp | grep 27182` shows a stable socat listener the whole time.
4. Consider whether the 30 s poll plus `RestartSec=15` is the right cadence. A
   teardown costs a 15-second outage that surfaces to the user as a hard MCP
   failure mid-task, so false positives are expensive.

## Also worth fixing if cheap

When the add-in restarts (or Fusion is restarted), a **running Claude Code
session loses the Fusion tools entirely** — they get deregistered, not just
disconnected, and the session must be restarted to get them back. If the proxy
can survive an add-in bounce and re-establish without the client noticing, that
removes the most disruptive failure mode. If it can't, `check.sh` should say so
explicitly so the user knows a Claude Code restart is required rather than
guessing.

## Out of scope

Don't change the Fusion add-in, the netsh portproxy rule, or the MCP client
config unless the diagnosis shows they are the actual fault.
