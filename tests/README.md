# Fixture tests

All suites copy a temporary fixture root and run the scripts with controlled
fake commands from `fixtures/bin-vps` and `fixtures/bin-openwrt`.  Nothing
touches a real VPS or router, and no target init script is ever executed
(the fixture namespace records init intent and emulates rc.d links).

| Suite | Covers |
| --- | --- |
| `test-milestone1.sh` | read-only discover/plan/status, helper fingerprint, hard blocks, private backups, clean-baseline READY/OK path |
| `test-vps-install.sh` | VPS .deb install/render/configtest/health, idempotent apply, caddy mode, 1Panel patch with failed `-t` restore |
| `test-openwrt-core.sh` | package + tailscale-core, disable-only for the unsafe stock service, fw4 zone transaction ordering, join (file: key, no `--reset`, multi-Headscale stop) |
| `test-openwrt-subnet.sh` | LAN CIDR discovery math, overlap hard checks, forwarding transaction, disable path, WAN UDP rule on/off |
| `test-update-rollback.sh` | users/keys/route approval, minor-sequential updates, one-snapshot rollback, cleanup/purge on both sides |
| `test-failure-injection.sh` | DNS/port/configtest/deb/opkg/auth failures, apply x3 idempotency, reboot steady state |

Requirements: POSIX `sh`, `jq`, `sha256sum`, and common Unix tools.  The
OpenWrt suites need `/dev/net/tun` on the host (they link it into the fixture
root for the `[ -c ]` check); without it those cases are skipped with a
message.

Failure injection is env-driven on the fakes, e.g. `FAKE_FAIL_FW4_CHECK=1`,
`FAKE_FAIL_OPENRESTY_T=1`, `FAKE_FAIL_CONFIGTEST=1`, `FAKE_FAIL_OPKG=1`,
`FAKE_FAIL_AUTH=1`, `FAKE_FAIL_TS_UP=1`, `FAKE_MISMATCH_DEB=1`,
`FAKE_LOCAL_HEALTH=503`, `FAKE_RELEASE_TAGS="..."`.
