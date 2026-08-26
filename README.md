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

## When Fusion MCP misbehaves, do this

**Run `~/claude-code-fusion-mcp-check/check.sh` and do what it says.** It names the
broken layer and prints the exact command. Nothing below needs to be remembered — this
section exists so you do not have to re-derive it.

| What you see | What it means | What to do |
|---|---|---|
| `check.sh` exits 0, but an agent cannot see the Fusion tools | That session is stale. Reloading the add-in or restarting Fusion **deregisters** the tools from every already-running Claude Code session — the transport recovers by itself, the client does not | Restart that session; `claude --continue` keeps the conversation |
| Layer 2 fails, `wslrelay.exe` holds the port | Something bound 27182 before the server, so it silently moved to a random port | Stop the proxy, restart the server (**Preferences → General → API → untick and re-tick "Fusion MCP Server"**), rerun `install.sh`. `check.sh` prints these in order |
| Layer 2 fails, nothing is listening | Fusion is closed, or the "Fusion MCP Server" preference is off | Open Fusion 360 with a document; tick **Preferences → General → API → "Fusion MCP Server"** (the port is set right there — must be 27182) |
| Layer 3 fails after a Windows reboot | The WSL gateway IP changed and the `netsh` rule still points at the old one | Run the `delete`/`add` pair `check.sh` prints, in an **Administrator** PowerShell |
| After switching WSL to **mirrored** networking, nothing listens on 27182 and reloading the add-in does nothing | A leftover NAT-era portproxy rule's `0.0.0.0` listener covers loopback and steals the bind from the add-in every time it starts | Delete the rule(s) `check.sh` prints (Administrator PowerShell), **then** reload the add-in. This bit for real on 2026-08-25 |
| `ECONNRESET`, or `curl` hangs instead of being refused | A forwarding loop, not a dead server | `check.sh` layer 4 distinguishes these; follow it |

### Things that are easy to get wrong later

- **Start order no longer matters.** The proxy waits for the add-in and hands the port
  back when it leaves. Open and close Fusion whenever you like; don't sequence anything.
- **The portproxy rule's fate depends on the WSL networking mode** — check
  `wslinfo --networking-mode` before touching it. **NAT**: never delete it as
  "redundant"; the add-in binds `127.0.0.1` only, so that rule is the only path in
  from WSL. **Mirrored**: the opposite — every portproxy rule on 27182 must go. A
  leftover `0.0.0.0` one steals the add-in's bind outright, and a gateway-IP one now
  names the LAN router. `check.sh` knows the mode and checks the right invariant.
- **Use the literal `127.0.0.1` in every URL, never the name `localhost`.** The name
  resolves IPv6-first to `::1`, which hangs against these IPv4-only listeners.
- **Two processes co-binding `127.0.0.1:27182` is normal**, not a symptom. WSL
  republishes our own listener as `wslrelay.exe`.
- **`ss` is aliased to `gnome-screenshot`** in some interactive shells here, so
  `ss -ltnp | grep 27182` can print nothing while the socket is perfectly healthy. Use
  `/bin/ss` or `/proc/net/tcp`; `check.sh` already does.
- **Agents should run `check.sh` and report, not fix.** This is also enforced by
  `~/.claude/CLAUDE.md` and this repo's `CLAUDE.md`. Ad-hoc workarounds applied from
  project directories are what left a stray portproxy rule and a port-racing proxy
  behind, and cost hours to untangle. Fixes belong in this repo.

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

That diagram describes **NAT** networking (the WSL default). Under **mirrored**
networking (`wslinfo --networking-mode`) WSL shares the Windows loopback: neither hop
exists, `127.0.0.1:27182` reaches the add-in directly with the right Host header, and
leftovers of either hop actively break the link. `check.sh` and `install.sh` detect the
mode and do the right thing for each.

None of this applies if Claude Code runs natively on Windows, or if Fusion and Claude
Code are on the same side — there the add-in is already on real loopback and the default
config works.

## The two things the server does

A note on names: this document says "the add-in" for Autodesk's own MCP server
(`NsMCP10.dll`), which the **Preferences → General → API → "Fusion MCP Server"**
checkbox controls — that is the ONLY MCP server sanctioned on this machine. Do not
confuse it with third-party MCP add-ins installed under `API\AddIns`: one of those
(port 8765) derailed a whole debugging session on 2026-08-25 before being removed.
Anything answering MCP from Fusion whose serverInfo is not "MCP Server Adapter" is an
intruder to remove, not a fallback to use.

Both facts below were established by reading `NsMCP10.dll` directly, not guessed:

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

**The fix is in `install.sh`.** The proxy never binds until it has confirmed
`Fusion360.exe` holds Windows `127.0.0.1:27182`, and it hands the port straight back
when the add-in lets go, so the add-in reclaims 27182 on its next start instead of
drifting to a dynamic port. The unit stays resident and supervises this itself, polling
every 5s — a `netstat` poll costs ~35ms, and being quick to release is what lets a full
Fusion restart recover without anyone intervening.

Two details that are easy to get wrong if you rewrite this:

- **Windows lets `wslrelay.exe` co-bind the same `127.0.0.1:27182` as the add-in**, so
  netstat legitimately lists two holders and their order is *not* stable. Asking "is the
  same PID still the holder?" flip-flops and tears the proxy down every ~45s. The stable
  question is "is `Fusion360.exe` among the holders?" — a co-bound relay is harmless,
  because whoever bound first keeps receiving the traffic.
- **The unit being `active` does not mean the port is bound.** The supervisor stays
  active while waiting for the add-in. `check.sh` asks `/proc/net/tcp` instead. Note
  that `ss` is aliased to `gnome-screenshot` in some interactive shells here, so a
  manual `ss -ltnp | grep 27182` can print nothing while the socket is perfectly fine.

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
| 1 | Which networking mode, and does WSL have a route to Windows? | — |
| 2 | Does Fusion's MCP server own Windows `127.0.0.1:27182`, or did something else take it (a `0.0.0.0` wildcard bind included)? | no |
| 3 | NAT: does the portproxy rule exist and point at the current gateway? Mirrored: are there ZERO portproxy rules on the port? | no |
| 4 | Is the server reachable from WSL (refused vs. loop vs. answering)? | — |
| 5 | NAT: is the loopback proxy running and durable? Mirrored: is it absent? | yes |
| 6 | Does a full MCP handshake return tools? | — |
| 7 | Does some registration point at `http://127.0.0.1:27182/mcp` and connect? | yes |

It exits non-zero at the first genuinely broken layer. Layers 2 and 3 can only be fixed
on the Windows side, so those instructions are printed under a bright
`ON WINDOWS (not in WSL):` heading with the exact command or menu path — including
whether it needs an Administrator PowerShell. Layer 2 also probes for the add-in's
fallback port, so "the add-in is loaded but homeless on 62095" is distinguished from
"the add-in is not running", which need completely different fixes.

Layer 7 accepts any registration name (machines differ) but requires the URL to be the
literal `http://127.0.0.1:27182/mcp`, and flags every entry — user scope or per-project —
that uses anything else: gateway IPs are stale (403 in NAT, the LAN router in mirrored)
and `localhost` resolves IPv6-first to `::1`, which hangs against this IPv4-only
listener. Stale per-project entries present as Fusion working in some directories and
not others.

## Making the failure impossible instead of survivable

The supervisor above *handles* the port race. If you would rather the race could not
exist, the root enabler is WSL republishing our listener onto Windows as `wslrelay.exe`.
Turning that off means nothing can ever take 27182 from the add-in. In
`C:\Users\<you>\.wslconfig`, then `wsl --shutdown` from PowerShell:

```ini
[wsl2]
localhostForwarding=false
```

Everything here keeps working unchanged — the proxy still listens on WSL loopback and
the portproxy rule still bridges the gateway. The cost is that Windows can no longer
reach WSL-hosted dev servers at `localhost`, which is a real loss if you use that. It is
not required; it just removes the failure mode by construction.

## The alternative: mirrored networking

WSL2 on Windows 11 22H2+ supports `networkingMode=mirrored`, which maps WSL's loopback
onto the Windows loopback. That removes the need for both the proxy and the portproxy
rule, because `127.0.0.1:27182` reaches the add-in directly with the right Host header.
`check.sh` and `install.sh` detect the mode automatically and check/install accordingly.

Trade-offs before switching: it changes networking for **every** WSL distro, it
interacts badly with some VPN and container setups, and applying it requires
`wsl --shutdown`, which kills every running WSL session. To switch, put this in
`C:\Users\<you>\.wslconfig` and run `wsl --shutdown` from PowerShell:

```ini
[wsl2]
networkingMode=mirrored
```

**After switching, remove every piece of NAT plumbing — it does not just become
redundant, it turns hostile.** The registered URL is already `127.0.0.1` so it needs no
repointing, but run `install.sh` (it removes the proxy unit in mirrored mode) and delete
every portproxy rule on 27182 in an Administrator PowerShell. The failure this prevents
is nasty: a leftover `0.0.0.0:27182` rule steals the bind from the add-in on every
start, so the add-in silently lands on a random port and no amount of reloading fixes
it. That exact sequence cost a day's debugging on 2026-08-25; `check.sh` layer 2 now
names it directly.

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
