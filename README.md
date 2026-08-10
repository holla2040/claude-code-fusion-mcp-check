# claude-code-fusion-mcp-check

Connecting Claude Code to the Fusion 360 MCP add-in fails in a way that looks like
several different problems. This repo diagnoses it in one command and makes the fix
permanent.

```sh
./check.sh      # diagnose, layer by layer
./install.sh    # make it durable (run once)
```

`check.sh` is safe to call from any directory — other projects run it when Fusion tools
start misbehaving, and every command it suggests is printed as an absolute path.

## The setup this is for

**Claude Code runs inside WSL2. Fusion 360 and its MCP add-in run on Windows.** That
split is the whole source of the problem — the two are on opposite sides of a network
boundary, and the add-in is bound to the far side of it.

```
   WSL2                                       Windows
   ────                                       ───────
   Claude Code                                Fusion 360
        │                                          ▲
        │ http://127.0.0.1:27182/mcp               │ MCP add-in (NsMCP10.dll)
        ▼                                          │ bound to 127.0.0.1:27182 ONLY
   socat proxy ────────────────────►  netsh portproxy
                 gateway (172.17.x.1)   gateway:27182 -> 127.0.0.1:27182
```

Both hops are load-bearing. The portproxy rule gets you *to* the add-in; the socat proxy
makes the request *acceptable* to it. Removing either one breaks the connection.

None of this applies if Claude Code runs natively on Windows, or if Fusion and Claude
Code are on the same side — there the add-in is already on real loopback and the default
config works.

## The two things the add-in does

Both were established by reading `NsMCP10.dll` directly, not guessed:

1. **It binds `127.0.0.1` only.** The string `0.0.0.0` does not appear in the DLL. So
   nothing outside Windows can reach it without a `netsh interface portproxy` rule
   bridging the WSL gateway address to Windows loopback. That rule needs an elevated
   PowerShell, lives in the registry, and survives reboots — but it is pinned to one
   gateway IP, and that IP changes across reboots under NAT networking.

2. **It does DNS-rebinding protection** and accepts **only** `Host: 127.0.0.1:27182`.
   Anything else gets:

   ```
   HTTP/1.1 403 Forbidden
   {"error": "Invalid Host header"}
   ```

   from a completely healthy server. The socat proxy on WSL loopback exists purely so
   the client sends the one Host value the add-in accepts.

   The DLL does read `FUSION_MCP_HOST_ALLOWLIST` and `FUSION_MCP_ORIGIN_ALLOWLIST` from
   the environment, so this is relaxable in principle — but the value would have to name
   the gateway IP, which changes across reboots. Fixing the header in the proxy is the
   stabler side to fix it on.

## The failure that comes back

This is the one worth understanding, because it recurs on its own and every symptom
points somewhere unhelpful.

The add-in **does not fail loudly when 27182 is taken** — it silently binds a random
port instead (`Bound to dynamic port` is right there in the DLL). And WSL's localhost
forwarding republishes any WSL listener on `127.0.0.1:27182` back onto the *Windows*
side as `wslrelay.exe`.

Put those together with a proxy that starts at boot:

```
socat binds 27182 in WSL  ->  wslrelay claims Windows 127.0.0.1:27182
                          ->  Fusion starts later, add-in finds 27182 taken
                          ->  add-in silently moves to a dynamic port
                          ->  portproxy forwards gateway:27182 into wslrelay
                          ->  wslrelay forwards back into WSL socat
                          ->  socat forwards to gateway:27182  ->  loop
```

What you see: `ECONNRESET` in Claude Code, `curl` hanging until timeout rather than being
refused, and a socat process with a large memory peak and constant `waitpid` warnings
from the fork storm. What it looks like: a broken add-in. What it actually is: **startup
order**, and it reassembles itself on every reboot, since the systemd unit starts long
before anyone opens Fusion.

The refused-vs-timeout distinction is the tell. Both show up as HTTP code `000`, but
`curl` exit 7 (refused) means nobody is home, while exit 28 (timeout) means something
accepted the connection and never answered — a loop, not an absence. `check.sh`
separates them.

**The fix is in `install.sh`:** the proxy never binds until it has confirmed
`Fusion360.exe` owns Windows `127.0.0.1:27182`, and a watchdog releases the port within
30s of the add-in letting go, so the add-in can reclaim 27182 on its next start instead
of drifting to a dynamic port. Until Fusion is up, the unit just exits and retries every
15s — an idle restart loop is the normal resting state, not a failure.

## Four other things that cost time to work out

1. **The gateway IP is not stable.** `172.17.64.1` changes between reboots under NAT
   networking. The proxy resolves it from `ip route` at start time; the portproxy rule
   on the Windows side cannot, so `check.sh` compares the two and prints the exact
   `delete`/`add` pair when they drift apart.

2. **`tools/list` returns an empty array unless you carry the session id.** `initialize`
   returns an `Mcp-Session-Id` header, and subsequent calls must echo it back. Without
   it you get a valid `200` with **0 tools**, which reads like "the add-in is broken"
   rather than "the handshake is incomplete". Claude Code's client does this correctly —
   this only bites hand-rolled `curl` probes.

3. **MCP servers attach at session start.** Fixing the config inside a running Claude
   Code session does nothing for that session. Restart it (`claude --continue` keeps the
   conversation).

4. **Fusion must be running.** The add-in only listens while Fusion is open, and the
   tools need an active document to act on.

## What `check.sh` checks

| Layer | Question | Fixable from WSL? |
|---|---|---|
| 1 | Does WSL have a route to the Windows host? | — |
| 2 | Does the Fusion add-in own Windows `127.0.0.1:27182`, or did something else take it? | no |
| 3 | Does the portproxy rule exist, and does it point at the current gateway? | no |
| 4 | Is the server reachable from WSL (refused vs. loop vs. answering)? | — |
| 5 | Is the loopback proxy running, and durable? | yes |
| 6 | Does a full MCP handshake return tools? | — |
| 7 | Does Claude Code report `fusion` as connected? | yes |

It exits non-zero at the first genuinely broken layer. Layers 2 and 3 can only be fixed
on the Windows side, so those instructions are printed under a bright
`ON WINDOWS (not in WSL):` heading with the exact command or menu path — including
whether it needs an Administrator PowerShell. Layer 2 also probes for the add-in's
fallback port, so "the add-in is loaded but homeless on 62095" is distinguished from
"the add-in is not running", which need completely different fixes.

Layer 7 flags any per-project entries still pointing at a gateway IP, since those 403
while the user-scope entry works — which presents as Fusion working in some directories
and not others.

## The alternative: mirrored networking

WSL2 on Windows 11 22H2+ supports `networkingMode=mirrored`, which maps WSL's loopback
onto the Windows loopback. That removes the need for both the proxy and the portproxy
rule, because `127.0.0.1:27182` reaches the add-in directly with the right Host header.

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

and, in an Administrator PowerShell on Windows:

```powershell
netsh interface portproxy delete v4tov4 listenaddress=<gateway> listenport=27182
```

## License

MIT — see [LICENSE](LICENSE).
