# claude-code-fusion-mcp-check

Connecting Claude Code to the Fusion 360 MCP add-in fails in a way that looks like
several different problems. This repo diagnoses it in one command and makes the fix
permanent.

```sh
./check.sh      # diagnose, layer by layer
./install.sh    # make it durable (run once)
```

## The setup this is for

**Claude Code runs inside WSL2. Fusion 360 and its MCP add-in run on Windows.** That
split is the whole source of the problem — the two are on opposite sides of a network
boundary, and the add-in rejects connections that cross it.

```
   WSL2                                  Windows
   ────                                  ───────
   Claude Code                           Fusion 360
        │                                     │
        │ http://127.0.0.1:27182/mcp          │ MCP add-in (NsMCP10.dll)
        ▼                                     ▼
   socat proxy  ──────────────────────►  127.0.0.1:27182
                  gateway (172.17.x.1)
```

None of this applies if Claude Code runs natively on Windows, or if Fusion and Claude
Code are on the same side — there the add-in is already on real loopback and the
default config works.

## The actual problem

The Fusion add-in (`NsMCP10.dll`) does DNS-rebinding protection. It accepts **only**
`Host: 127.0.0.1:27182`.

From WSL, the Windows host is reachable at the NAT gateway IP, so the natural config is
`http://172.17.64.1:27182/mcp`. That sends `Host: 172.17.64.1:27182`, and the server
answers:

```
HTTP/1.1 403 Forbidden
{"error": "Invalid Host header"}
```

The server is running and healthy. It just refuses the header. Because the add-in is a
compiled DLL, there is no `allowedHosts` setting to relax — the fix has to be on the
WSL side.

## The fix

A loopback proxy on WSL's `127.0.0.1:27182` forwarding to the gateway. The client then
sends `Host: 127.0.0.1:27182` — exactly what the add-in accepts — and Claude Code is
pointed at `http://127.0.0.1:27182/mcp`.

`install.sh` sets this up as a systemd **user** unit with `Restart=always`, and
registers the MCP server at **user scope** so it applies to every project instead of
being added one directory at a time.

## Four things that cost time to work out

1. **The gateway IP is not stable.** `172.17.64.1` changes between reboots under NAT
   networking. The proxy script resolves it from `ip route` at start time; hardcoding it
   is a fix that silently breaks later.

2. **`tools/list` returns an empty array unless you carry the session id.** `initialize`
   returns an `Mcp-Session-Id` header, and subsequent calls must echo it back. Without
   it you get a valid `200` with **0 tools**, which reads like "the add-in is broken"
   rather than "the handshake is incomplete". Claude Code's client does this correctly —
   this only bites hand-rolled `curl` probes.

3. **MCP servers attach at session start.** Fixing the config inside a running Claude
   Code session does nothing for that session. Restart it.

4. **Fusion must be running.** The add-in only listens while Fusion is open, and the
   tools need an active document to act on.

## What `check.sh` checks

| Layer | Question |
|---|---|
| 1 | Does WSL have a route to the Windows host? |
| 2 | Is the Fusion MCP server answering on the gateway? |
| 3 | Is the loopback proxy running, and durable? |
| 4 | Does a full MCP handshake return tools? |
| 5 | Does Claude Code report `fusion` as connected? |

It exits non-zero at the first genuinely broken layer and prints the specific command to
fix it. Layer 5 also flags any per-project entries still pointing at a gateway IP, since
those 403 while the user-scope entry works — which presents as Fusion working in some
directories and not others.

## The alternative: mirrored networking

WSL2 on Windows 11 22H2+ supports `networkingMode=mirrored`, which maps WSL's loopback
onto the Windows loopback. That removes the need for a proxy at all, because
`127.0.0.1:27182` reaches the add-in directly with the right Host header.

It is not the default recommendation here: it changes networking for **every** WSL
distro, it interacts badly with some VPN and container setups, and applying it requires
`wsl --shutdown`, which kills every running WSL session. The proxy is contained and
reversible. If you want to try mirrored mode anyway, put this in
`C:\Users\<you>\.wslconfig` and run `wsl --shutdown` from PowerShell:

```ini
[wsl2]
networkingMode=mirrored
```

Then repoint nothing — the URL is already `127.0.0.1`, so you can just
`systemctl --user disable --now fusion-mcp-proxy.service`.

## Uninstall

```sh
systemctl --user disable --now fusion-mcp-proxy.service
rm ~/.config/systemd/user/fusion-mcp-proxy.service ~/.local/bin/fusion-mcp-proxy.sh
claude mcp remove fusion --scope user
```

## License

MIT — see [LICENSE](LICENSE).
