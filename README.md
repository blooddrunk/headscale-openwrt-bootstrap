# Headscale + OpenWrt bootstrap

This project is being implemented from the sibling `PLAN.md` and the checked-in
working references.  The current build is Milestone 1 only:

- `discover` reads facts without changing the target;
- `plan` validates ownership and safety boundaries and returns non-zero when a
  hard conflict is found;
- `status` performs read-only health and safety checks;
- `verify` is a read-only Milestone 1 alias for `status`;
- `backup` creates a private, timestamped snapshot with `manifest.sha256`.

The remaining commands are explicit fail-closed placeholders.  They do not
install packages, call init scripts, invoke `network reload`, execute
`tailscale up --reset`, write UCI, reload fw4, touch DNS, or modify Headscale.

Examples:

```sh
./headscale-vps.sh discover
./headscale-vps.sh --domain hs.example.com --expected-public-ip 203.0.113.10 plan
./headscale-vps.sh backup

./tailscale-openwrt.sh discover
./tailscale-openwrt.sh --login-server https://hs.example.com plan
./tailscale-openwrt.sh backup
```

For offline checks, `--root DIR` makes absolute target paths resolve below a
fixture root.  It does not sandbox external commands; tests should provide a
controlled `PATH` for commands such as `tailscale`, `uci`, `ss`, and `docker`.

Backups contain sensitive operational data by design.  They are created with a
private umask and permissions, are never printed, and must remain outside Git.
