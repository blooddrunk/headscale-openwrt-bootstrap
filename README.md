# Headscale + OpenWrt bootstrap

这是一个按 [PLAN.md](PLAN.md) 和 `reference/` 已验证基线逐 Milestone
开发的安全引导脚本项目。当前仓库实现的是 Milestone 1：只读发现、规划、
状态检查和私有备份。

脚本不会把“安装”误当成“检查”。当前所有写操作命令都显式
fail-closed；它们不会安装软件包、改写配置、启动/重启服务、reload
netifd 或 fw4、执行 `tailscale up --reset`、改 DNS，或改变 Headscale/
OpenWrt 网络。

## 从仓库运行

在 VPS 上：

~~~sh
git clone https://github.com/blooddrunk/headscale-openwrt-bootstrap.git
cd headscale-openwrt-bootstrap

sudo ./headscale-vps.sh discover
sudo ./headscale-vps.sh \
  --domain hs.example.com \
  --expected-public-ip 203.0.113.10 \
  plan
sudo ./headscale-vps.sh status
sudo ./headscale-vps.sh backup
~~~

在 OpenWrt 上可以直接复制仓库目录（不要求路由器安装 Git）：

~~~sh
scp -r headscale-openwrt-bootstrap root@192.168.1.1:/root/
ssh root@192.168.1.1
cd /root/headscale-openwrt-bootstrap

./tailscale-openwrt.sh \
  --login-server https://hs.example.com \
  discover
./tailscale-openwrt.sh \
  --login-server https://hs.example.com \
  plan
./tailscale-openwrt.sh status
./tailscale-openwrt.sh backup
~~~

真实 VPS/OpenWrt 的备份需要 root。`discover`、`plan`、`status` 本身是
只读的，但仍建议使用能读取目标配置、服务和网络信息的账号运行。
脚本依赖目标系统已有的 POSIX `sh` 及常见只读工具；VPS 会按可用性检查
`headscale`、`systemctl`、`ss`、`ip`、`getent`、`curl`、`docker` 等，
OpenWrt 会检查 `opkg`/`apk`、`uci`、`ubus`、`fw4`、`nft`、`ip`、`ss`
和 Tailscale CLI。缺少工具会报告为 unknown/blocked，不会自动安装。

## Milestone 1 命令

两个脚本都支持：

| 命令 | 行为 |
| --- | --- |
| `discover` | 收集当前事实，不写目标系统。 |
| `plan` | 根据安全边界展示后续计划；发现硬冲突时退出码为 `2`。 |
| `status` | 只读检查当前健康状态和安全前置条件；不安全、缺失或未验证时退出码为 `2`。 |
| `verify` | Milestone 1 中 `status` 的只读别名。 |
| `backup` | 创建不覆盖旧目录的私有时间戳快照，并生成 `manifest.sha256`。 |

使用 `--json` 获取机器可读输出，例如：

~~~sh
sudo ./headscale-vps.sh --json status > headscale-status.json
./tailscale-openwrt.sh --json status > openwrt-status.json
~~~

脚本还接受 `--quiet`、`--verbose` 和 `--dry-run`；在 Milestone 1 中
`--dry-run` 只是兼容参数，因为上述命令本来就不修改系统。`--yes` 也不会
绕过任何安全阻断。

常用参数：

- VPS：`--domain`、`--expected-public-ip`、`--proxy
  auto|1panel|caddy|nginx|none`、`--user`、三个 listen 地址参数、
  `--enable-embedded-derp true|false`。
- OpenWrt：`--login-server`、`--auth-key-file`、`--hostname`、
  `--service-mode auto|core|native`、`--accept-dns`、`--accept-routes`、
  `--subnet`、`--enable-subnet`、`--allow-wan-udp`。
- 两者：`--root DIR` 用于 fixture 根目录，`--backup-dir DIR` 指定备份
  目录，`--json` 输出 JSON。

`--auth-key-file` 只检查文件存在且权限为 `0400` 或 `0600`，不会读取、
打印或写入日志。不要把 auth key、`tailscaled.state`、Headscale 数据库
或 TLS 私钥复制进仓库。

## 备份与校验

默认位置为：

- VPS：`/var/backups/headscale-bootstrap/`
- OpenWrt：`/root/tailscale-bootstrap-backups/`

也可以显式指定绝对路径：

~~~sh
sudo ./headscale-vps.sh \
  --backup-dir /srv/private/headscale-backups \
  backup
./tailscale-openwrt.sh \
  --backup-dir /root/private/tailscale-backups \
  backup
~~~

每次备份都会新建 UTC 时间戳目录；同一秒重复运行会使用 `-1`、`-2`
等后缀，不会覆盖旧备份。目录权限默认为私有，备份输出不包含状态库、
数据库或 auth key 内容。备份失败时会保留 `.INCOMPLETE` 标记，不能把它
当作可回退快照使用。

成功后可在备份目录校验清单：

~~~sh
cd /var/backups/headscale-bootstrap/<timestamp>
sudo sha256sum -c manifest.sha256
~~~

VPS 快照包括 Headscale 配置/数据、systemd unit，以及检测到的
1Panel/Caddy 代理文件；OpenWrt 快照包括 Tailscale 状态目录、现有
init/helper、相关 UCI 配置和不含密钥内容的诊断摘要。备份本身仍属于
敏感运维数据，必须留在 Git 之外。

## 当前安全边界

VPS 检查会保护已验证的代理部署：Headscale 的 `8080`、`9090`、
`50443` 必须保持 loopback 监听，公网 HTTPS 由反向代理承载；会检查
Headscale `configtest`、DNS 与预期公网 IP、1Panel OpenResty host
network/挂载、代理到 loopback 的路径及 DERP `3478` 状态。不会擅自把
Headscale 端口改为公网监听，也不会在升级前跳过备份或配置校验。

OpenWrt 检查会保护 netifd、fw4/nftables 和现有多 Headscale 状态：不
创建默认 `network.tailscale`、不 reload 网络、不调用 stock
`/etc/init.d/tailscale`、不覆盖不同的现有 ControlURL、不启用 exit
node/default route、subnet route 或 WAN UDP。检测到危险 LuCI helper、
不同 ControlURL、已有冲突的 netifd section，或无法证明 fw4 归属时，
`plan/status` 会阻断。当前也不声明支持同时连接多个 Headscale 网络。

以下命令在本 Milestone 只会返回退出码 `2` 并说明
`fail-closed`，不会尝试执行：

~~~text
headscale-vps.sh: install apply update rollback cleanup purge
                  ensure-user issue-key approve-route
tailscale-openwrt.sh: install apply join update enable-subnet
                      disable-subnet allow-wan-udp rollback cleanup purge-identity
~~~

## Fixture 测试

测试使用临时复制的 fixture 根目录和受控的假命令，不调用目标 init
脚本，不触碰真实 VPS 或路由器：

~~~sh
./tests/test-milestone1.sh
~~~

需要 POSIX `sh`、BusyBox `ash`、`jq`、`sha256sum` 以及常见 Unix 工具。
手动使用 `--root DIR` 时要注意：它只把脚本访问的绝对目标路径映射到
fixture 根目录，并不是 chroot，也不会自动隔离外部命令。请像测试一样
通过受控 `PATH` 提供 `tailscale`、`uci`、`ss`、`docker` 等命令；不要
直接在已检出的 `tests/fixtures/` 内运行会生成备份的命令。

## 仓库内容与后续 Milestone

- `PLAN.md`：完整实施顺序、安全约束、幂等/回退/清理要求。
- `reference/`：已验证的 Headscale、1Panel/OpenResty、Tailscale、
  netifd 和 fw4 基线，按原样保留。
- `templates/`：后续写入操作使用的模板；Milestone 1 不会写入它们。
- `tests/`：只读探测、硬阻断和私有备份的 fixture 测试。

后续应严格按 M2（VPS）、M3（1Panel）、M4（OpenWrt core/join）、
M5（subnet）、M6（update/rollback/cleanup）、M7（失败注入与重启验证）
推进。任何写操作都必须先备份、校验语法/配置、原子替换并验证归属；
不能为了“方便运行”删除 netifd、fw4、1Panel、Headscale 升级或多
Headscale 网络的保护逻辑。
