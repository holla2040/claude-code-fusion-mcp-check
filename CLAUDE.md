# Working on this repo — and using it from other projects

## If you are an agent in ANOTHER project and Fusion MCP is misbehaving

Run the check and report the result. Do not fix it yourself:

```sh
~/claude-code-fusion-mcp-check/check.sh
```

- **Exit 0** — the link is fine. If your session still cannot see the Fusion tools, your
  *session* is the problem, not the link: reloading the add-in or restarting Fusion
  deregisters the tools from already-running sessions. Restart with `claude --continue`.
- **Non-zero** — the script prints the specific broken layer and the exact command.
  Steps under an `ON WINDOWS (not in WSL):` heading cannot be done from WSL at all.
  **Tell the owner what it printed and stop.** Do not edit the proxy, the systemd unit,
  the `netsh` portproxy rule, or the MCP registration to work around it.

Every ad-hoc "fix" applied from a project directory is how this setup got broken before:
a stray portproxy rule and a proxy that raced the add-in for the port cost hours of
diagnosis. The failure modes here are counterintuitive and the diagnosis is already
encoded in `check.sh` — running it is cheap, re-deriving it is not.

## If you are working on this repo

Read the README first; it records what the add-in actually does, established by reading
`NsMCP10.dll`, not by inference. Two invariants that look wrong and are not:

1. The `netsh` portproxy rule is **required**. The add-in binds `127.0.0.1` only — there
   is no `0.0.0.0` bind in the DLL — so nothing outside Windows reaches it without that
   rule. Deleting it as "redundant" breaks the link permanently.
2. Two processes co-binding `127.0.0.1:27182` is **normal**. WSL republishes our own
   listener as `wslrelay.exe`. Any logic that asks "who is *the* holder" is wrong,
   because netstat's order between them is unstable; ask whether `Fusion360.exe` is
   among them.

The add-in never fails loudly when 27182 is taken — it silently binds a random port. So
"the add-in is broken" almost always means "something else took its port first".

Verify changes with `./check.sh` from a directory other than this one; other projects
call it, so every command it suggests must be an absolute path.
