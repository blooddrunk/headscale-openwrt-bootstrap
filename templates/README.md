Templates written by the scripts during install/apply.  Every write is
preceded by a backup, validated (`procd`/`caddy validate`/`nginx -t`) before
any reload, and verified afterwards.  `tailscale-core.init` is the service
definition the fingerprint check expects.  `tailscale-failover.init` +
`tailscale-failover.watchdog.sh` deploy to /etc/init.d/tailscale-failover
and /usr/sbin/tailscale-failover; both carry fingerprint markers and are
restored from these templates when tampered.
