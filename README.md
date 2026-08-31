# Headscale + OpenWrt bootstrap

在一台 Debian/Ubuntu VPS 上部署自托管的 [Headscale](https://headscale.net)
控制服务器，并在一台 OpenWrt/Kwrt 路由器上把 Tailscale 客户端接入它——
通过两个脚本完成安装、配置、更新、校验、回退和清理。

项目在真实环境中按以下版本组合验证过：Headscale 0.29.3、Tailscale
1.98.3、Kwrt/OpenWrt 25.12（fw4/nftables）、Debian 13、1Panel OpenResty。

## 为什么安全

多个系统管理层（Headscale、反向代理、tailscaled、fw4、netifd、第三方
LuCI helper）叠加时，最常见的故障是"谁都在管同一个接口/IP/路由"。本
项目的脚本因此把每一步写操作都放进固定的事务流程：

> 发现 → 校验 → 备份 → 生成临时配置 → 语法/配置检查 → 应用 →
> 只重载必要的服务 → 验证 → 提交状态；失败则自动还原并以非零退出。

在此基础上内置了以下硬保护（不是文档约定，而是代码里的阻断逻辑）：

- **端口与 TLS**：Headscale 的 `8080/9090/50443` 只允许 loopback 监听，
  公网 HTTPS 由反向代理承载；80/443 被未知进程占用时直接阻断，从不抢
  端口、从不 kill 进程。
- **配置安全**：修改配置前必备份；`headscale configtest` 通过才允许
  restart；只改脚本托管的键，其余配置逐字保留。
- **升级顺序**：Headscale 升级不跨稳定 minor（逐级使用每个 minor 的
  最新 patch）；每步先备份 `/etc/headscale` + `/var/lib/headscale`，
  失败自动回退到升级前快照。
- **netifd 边界**：绝不创建 `network.tailscale` 接口，绝不执行
  `network reload`；`tailscale0` 的地址始终由 tailscaled 自己管理。
- **第三方服务边界**：检测到危险 LuCI helper（含
  `tailscale up --reset`、改写 network UCI 等指纹）时，stock
  `/etc/init.d/tailscale` 只会被 disable，**永远不会被 stop/reload/restart**，
  daemon 由本项目维护的 `tailscale-core` 服务管理。
- **防火墙事务**：所有 fw4 修改固定走 未提交 UCI → `fw4 check` →
  `uci commit firewall` → `/etc/init.d/firewall reload`，检查不过即整体
  回滚未提交变更。
- **单网络原则**：节点已注册到其他 Headscale 时，join 会硬停并给出三个
  明确选项（保留当前 / 切换 profile / `purge-identity` 重注册），
  绝不静默换网；已注册节点不用 `tailscale up --reset`，偏好通过
  `tailscale set` 幂等收敛。多网络仍以"同一时刻只有一个活动 tailnet"
  为前提——profile 登记与 failover 守护只在已注册的 profile 之间
  串行切换，从不并发连接，也从不在切换时使用 auth key（见
  "多 profile 与故障切换"）。
- **秘密不落日志**：auth key 只输出一次（stdout 或 0600 权限的文件），
  `tailscaled.state`、数据库、TLS 私钥永不打印。
- **默认最小权限**：exit node、IPv6 subnet routing 默认关闭（本版未实现）；
  embedded DERP 默认关闭，由 `enable-derp` 显式开启并纳入托管键（见
  "自建 DERP 中继"）；subnet router 使用 Tailscale 自身 SNAT，fw4
  tailscale zone 不额外开启 masquerade。

## 快速开始

### VPS 端（headscale-vps.sh）

```sh
git clone https://github.com/blooddrunk/headscale-openwrt-bootstrap.git
cd headscale-openwrt-bootstrap

# 1. 先看看环境是否满足前置条件（只读，不改任何东西）
sudo ./headscale-vps.sh --domain hs.example.com --expected-public-ip <你的VPS公网IP> plan

# 2. 安装 Headscale 并渲染安全基线配置
sudo ./headscale-vps.sh --domain hs.example.com --expected-public-ip <IP> install

# 3. 配置反向代理（见下节"反向代理模式"）并做最终校验
sudo ./headscale-vps.sh --domain hs.example.com apply
sudo ./headscale-vps.sh status

# 4. 建用户、发一次性注册密钥
sudo ./headscale-vps.sh ensure-user --user home
sudo ./headscale-vps.sh issue-key --user home --expiration 2h
```

### OpenWrt 端（tailscale-openwrt.sh）

```sh
scp -r headscale-openwrt-bootstrap root@192.168.1.1:/root/
ssh root@192.168.1.1
cd /root/headscale-openwrt-bootstrap

# 1. 只读体检：包、危险 helper、TUN、fw4、当前 ControlURL、
#    profile 列表与 failover 状态等
./tailscale-openwrt.sh --login-server https://hs.example.com discover
./tailscale-openwrt.sh --login-server https://hs.example.com plan

# 2. 安装 tailscale 包 + tailscale-core 服务（危险 stock 服务只会被 disable）
./tailscale-openwrt.sh --login-server https://hs.example.com install

# 3. 注册节点：下面两种 auth key 输入方式二选一
# 3a. 预先保存为 0400/0600 文件；注册成功后脚本自动删除
./tailscale-openwrt.sh --login-server https://hs.example.com \
    --auth-key-file /tmp/hs-auth-key join

# 3b. 直接从 stdin 读取一行；运行后粘贴 auth key 并按 Enter
./tailscale-openwrt.sh --login-server https://hs.example.com \
    --auth-key-stdin join

# 4. （可选）把 LAN 网段作为 subnet router 广播出去（remote-access 模式：
#    远程 Tailscale 客户端可以访问本站 LAN，本站 LAN 不访问他人）
./tailscale-openwrt.sh --login-server https://hs.example.com enable-subnet

# 5. （可选）升级为 site-to-site：本站 LAN 客户端也能访问其他 tailnet
#    节点和别的站点广播的网段（accept-routes=true + lan->tailscale）
./tailscale-openwrt.sh --login-server https://hs.example.com enable-site-to-site
./tailscale-openwrt.sh --login-server https://hs.example.com disable-site-to-site
```

`--auth-key-file` 和 `--auth-key-stdin` 互斥。`--auth-key-stdin` 不会把
key 放进命令参数或日志；脚本只读取一行非空内容，内部用 `0600` 临时文件
通过 `file:` 交给 Tailscale，并在成功或失败退出时清理该临时文件。若使用
管道，也可以这样调用：

```sh
printf '%s\n' "$AUTH_KEY" | ./tailscale-openwrt.sh \
    --login-server https://hs.example.com --auth-key-stdin join
```

`profile-add` 同样支持这两种输入方式；需要新登录时必须给出其中一种，
如果节点已经注册到目标网络，脚本会直接
收编当前 profile，不读取 stdin，也不需要 auth key。

`join`/`profile-add` 默认给 Tailscale 登录等待 120 秒，避免网络或服务端
异常时无限 pending；可用 `--login-timeout SEC` 调整。登录超时或 Ctrl+C
后，脚本会检查 ControlURL 和 live profile list，尽力切回原网络，并提示
是否可以不带 auth key 重跑 `profile-add` 完成收编。

`enable-subnet` 会自动从 `ubus` 读取 LAN 地址并正确计算网络 CIDR（例如
192.168.10.129/25 → 192.168.10.128/25），随后停在"已广告、等待批准"
状态，并打印 VPS 侧的批准命令：

```sh
# 在 VPS 上执行
sudo ./headscale-vps.sh approve-route --node-id <ID> --route 192.168.10.0/24
```

### subnet 两种模式：remote-access 与 site-to-site

`enable-subnet`（默认）与 `enable-site-to-site` 是两个显式的档位，脚本
不会偷偷改安全默认值：

```text
remote-access（enable-subnet）:
  accept-routes=false, tailscale -> lan
  仅远程 Tailscale 客户端访问本站 LAN

site-to-site（enable-site-to-site）:
  accept-routes=true, tailscale -> lan + lan -> tailscale
  本站 LAN 客户端还可以访问其他 tailnet 节点和其他站点广播的网段
```

`disable-site-to-site` 只退回 remote-access（撤掉 `lan -> tailscale`、
accept-routes=false），subnet 广播本身仍由 `enable-subnet`/
`disable-subnet` 单独管理。启用状态记录在
`/etc/config/tailscale-bootstrap`（`config site_to_site`）；此后的
`apply`/`join`/`switch-to`/`update` 以及 failover watchdog 切换都会按
该标记收敛 accept-routes，不会把它静默重置回 false。

两个现场教训已固化成代码与检查：

- **forwarding 永远不引用缺失的 zone**：`enable-subnet`/`apply`/`join`/
  `update`/`enable-site-to-site` 都先确保 `firewall.tailscale` zone
  存在再收敛 forwarding；`ts_to_lan` 存在但 zone 缺失会被 `status`/
  `verify` 判定为 `ts_to_lan-references-missing-zone`（BROKEN），并在
  下一次 mutating 命令中自动修复，而不是带病运行。
- **Headscale 批准 ≠ 对端接受路由**：Headscale 里 `Approved/Serving`
  只是服务端愿意分发该网段；每个参与站点自己的 `accept-routes` 必须
  为 true（即对端也执行 `enable-site-to-site`），否则回程不通。
  `status` 在有广告路由时会输出该提示，site-to-site 模式下还会校验
  `RouteAll` 与两条 forwarding 的一致性。

仍然不做的事：不给 tailscale zone 开 masquerade（Tailscale 自带 subnet
SNAT）、不创建 `network.tailscale`、不 reload network、不
`tailscale up --reset`；所有防火墙修改依旧走
`fw4 check -> commit -> firewall reload` 事务，managed section 全部使用
固定名字（`tailscale` / `ts_to_lan` / `lan_to_ts` / `ts_wan_udp`），
`cleanup` 也只删这四个。

## 多 profile 与故障切换（OpenWrt 端）

远程只能通过 tailnet 访问的路由器有一个现实风险：控制服务器一挂，
人就再也无法远程登录路由器去手动换网。profile 列表 + failover 守护
进程就是为这个场景准备的——它仍然**不会同时连接两个网络**（官方客户端
同一时刻只有一个活动 tailnet），只是把"已注册的多个网络"登记在路由器
上，由 watchdog 在当前网络失效时自动切换：

profile 列表保存在项目自有的 `/etc/config/tailscale-bootstrap`，与
`/etc/tailscale/tailscaled.state` 中的 Tailscale 身份分开保存。每个网络
一个 `config profile` 段（段名由 URL 主机名派生），记录 `login_server`、
`priority`（数字越小越优先）以及对应的 tailscale 客户端 profile
（`ts_profile`/`ts_id`，切换时按名字或 id 调 `tailscale switch`）。
首次执行 `profile-add` 时，如果这个 UCI 文件不存在，脚本会自动创建；
如果节点此前已经通过 `join` 注册到目标网络，仍需显式执行一次
`profile-add` 才会把现有注册收编进列表：

```sh
# 已通过 join 注册到当前网络时，不会重新登录，也不会读取 stdin
./tailscale-openwrt.sh --login-server https://hs-a.example.com \
    --priority 10 profile-add
```

```sh
# 1. 登记第一个网络（未注册时也可直接用 profile-add 代替 join）
./tailscale-openwrt.sh --login-server https://hs-a.example.com \
    --auth-key-file /tmp/key-a --priority 10 profile-add

# 2. 登记第二个网络（tailscale login 新建 profile，成功后自动切回 A，
#    远程会话不会被打断；重复登记会拒绝，不会静默换网）
./tailscale-openwrt.sh --login-server https://hs-b.example.com \
    --auth-key-file /tmp/key-b profile-add        # priority 默认追加 +10

# 3. 查看列表 / 手动切换
./tailscale-openwrt.sh profile-list
./tailscale-openwrt.sh --login-server https://hs-b.example.com switch-to

# 4. 启用自动故障切换
./tailscale-openwrt.sh enable-failover            # 可调参数见 --help
./tailscale-openwrt.sh status                     # 含 failover 健康项

# 5. 随时把某个网络从列表移除（加 --delete-identity 会同时注销该身份）
./tailscale-openwrt.sh --login-server https://hs-b.example.com profile-remove
```

`profile-remove` 自带保护：`--delete-identity` 在只剩最后一个 profile
时拒绝执行（注销后没有可落地的网络）；同一 URL 反复 login 产生的多个
tailscale profile 会被逐一 logout（最多 5 轮）；注销完成后自动切回
仍登记的上一个网络。不带 `--delete-identity` 移除"当前活动网络"时只
警告——节点仍注册在该网络，直到你 `switch-to` 别处。移除后列表剩不到
2 个网络时，failover 守护会自动停用。

`enable-failover` 的前置条件：至少 2 个已登记 profile，且路由器上有
可用的 HTTPS 探测工具（curl/wget/uclient-fetch）。启用前会实测每个网络
的 `--health-path`，全部不可达时拒绝启用一个"盲切"的 watchdog；当前
不可达的网络会被列出，并在连续 `recovery_threshold` 次探测正常后才会
重新成为切换候选。调参取值优先级：显式 flag > 已写入 UCI 的旧值 >
默认值（`check_interval` 60 秒且下限 10、`failure_threshold`/
`recovery_threshold` 各 3、`cooldown` 300 秒、`probe_timeout` 5 秒、
`health_path` /health）。

watchdog（`/usr/sbin/tailscale-failover`，procd 守护 `tailscale-failover`）
的行为边界：

- 每 `check_interval` 秒探测所有登记网络的 `login_server/health`
  （curl → wget → uclient-fetch，需要可用 CA 证书）；
- 活动网络连续 `failure_threshold` 次探测失败（或控制面可达但
  BackendState ≠ Running，例如节点被服务端吊销）即切换到优先级最高
  （数字最小）且连续 `recovery_threshold` 次探测正常的候选；近期切换
  失败达 3 次的候选会被暂停（成功一次即归零）；
- `--failback true` 才会回切更高优先级网络，默认保持稳定；
- `cooldown` 秒内不发生第二次切换，切换后立即收敛安全偏好
  （accept-dns=false；accept-routes 按 `site_to_site` 标记收敛——
  site-to-site 模式保持 true，否则 false，切换不会静默改变模式）；
- 手动切到列表之外的网络时，只要它健康 watchdog 就不干预；失效才接管；
- 运行状态（探测计数、最近切换时间、每次决策结果）在
  `/var/run/tailscale-failover`（tmpfs，重启清零，短阈值下无妨）；
  手动跑单个决策周期用 `/usr/sbin/tailscale-failover --once`，日志用
  `logread | grep tailscale-failover`；
- 它只调用 `tailscale switch`，从不 login、从不使用 auth key、
  从不改 netifd/fw4；配置与身份分离：列表在
  `/etc/config/tailscale-bootstrap`（项目自有文件），身份仍在
  `/etc/tailscale/tailscaled.state`；
- 守护文件带指纹校验，被篡改后 plan/status 会阻断，
  `enable-failover` 自动备份并从模板修复。

与备份/回退/清理的关系：`backup` 快照包含 profile 登记表与 watchdog
文件，`rollback` 按快照整体恢复（仅当快照里 failover 已启用且剩余
≥2 个 profile 时才重新启用守护）；`cleanup` 会移除 watchdog 与登记表，
但 `tailscaled.state` 里的全部身份（所有网络的注册）都保留。

注意事项：每个网络都需要一个你能访问的对端节点（手机/电脑同时加入
两个 tailnet，或两个网络各有一个 exit node），否则切换后依旧没有入口。
每台 Headscale 侧的路由批准（approve-route）是独立的，切换后如需
subnet router 需在新服务器重新批准。

## 命令参考

两个脚本都支持 `--json`、`--quiet` 机器可读输出；`discover`/`plan`/
`status` 永远只读，`plan` 发现硬冲突时退出码为 2。

| 命令                                              | 端      | 说明                                                                                        |
| ------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------- |
| `discover` / `plan` / `status` / `verify`         | 双端    | 只读检查环境、展示计划、校验健康                                                            |
| `backup`                                          | 双端    | 创建带 manifest 的私有时间戳快照，不停服务                                                  |
| `install`                                         | 双端    | 全新安装（VPS：.deb；OpenWrt：opkg/apk 包 + tailscale-core）                                |
| `apply`                                           | 双端    | 幂等收敛：已满足的状态不会重做、不会无谓重启                                                |
| `join`                                            | OpenWrt | 用 `file:` auth key（`--auth-key-file` 或 `--auth-key-stdin`）注册，拒绝静默切换 ControlURL |
| `profile-list` / `profile-add` / `profile-remove` | OpenWrt | 多网络登记表（增/删/查，`--priority` 数字越小越优先，`--delete-identity` 同时注销身份）  |
| `switch-to`                                       | OpenWrt | 手动切换到列表中的某个网络（经 ControlURL 校验）                                            |
| `enable-failover` / `disable-failover`            | OpenWrt | 安装/启动/停止按优先级与健康探测自动切换的 watchdog（需 ≥2 个 profile，启用前实测各网络 /health） |
| `enable-subnet` / `disable-subnet`                | OpenWrt | 广播/撤回 LAN 网段（remote-access 模式），附 fw4 forwarding 事务                        |
| `enable-site-to-site` / `disable-site-to-site`    | OpenWrt | 显式切换 site-to-site（accept-routes=true + lan->tailscale）/退回 remote-access          |
| `allow-wan-udp [false]`                           | OpenWrt | 添加/移除最窄的 WAN UDP 41641 入站规则                                                      |
| `update`                                          | 双端    | 升级（VPS 遵守 minor 顺序；OpenWrt 只重启 tailscale-core 并校验身份不变）                   |
| `rollback [BACKUP_ID]`                            | 双端    | 把配置+数据+（VPS）软件包、（OpenWrt）profile 登记表与 watchdog 作为一个快照整体恢复        |
| `cleanup`                                         | 双端    | 删除脚本自管的内容（OpenWrt 含 failover 守护与 profile 登记表），保留数据/身份/软件包       |
| `purge` / `purge-identity`                        | 双端    | 破坏性操作，必须 `--yes-i-understand`，执行前做最终备份                                     |
| `ensure-user` / `issue-key` / `approve-route`     | VPS     | 用户与注册密钥管理、路由批准                                                                |
| `enable-derp` / `disable-derp`                    | VPS     | 开/关内置 DERP 中继：托管 region 键与公网 IPv4，重启后验证 UDP STUN 与 `/derp/probe`        |
| `enable-magic-dns` / `disable-magic-dns`          | VPS     | 开/关 MagicDNS（默认基域 `ts.<域名>`，`--base-domain` 可指定）：托管 dns 键并保持全局解析器为空；`status` 对打包默认下发的全局解析器报 `dns-global-resolvers-pushed` |

常用参数：VPS 侧 `--domain`、`--expected-public-ip`、`--proxy`、
`--listen/--metrics-listen/--grpc-listen`、`--version`（跨 minor 的
`update` 还需 `--yes` 确认）、`--enable-embedded-derp`、
`--derp-region-code/--derp-region-name`、`--base-domain`
（enable-magic-dns 的 MagicDNS 基域）、`--user`、`--expiration`、`--output`、
`--node-id`、`--route`；OpenWrt 侧
`--login-server`、`--auth-key-file`、`--auth-key-stdin`、`--service-mode`、`--accept-dns`、
`--accept-routes`、`--subnet`、`--min-client-version`、`--priority`、
`--delete-identity`，以及 enable-failover 的
`--check-interval/--failure-threshold/--recovery-threshold/--failback/
--cooldown/--probe-timeout/--health-path`。完整列表见
`--help`。

## 反向代理模式（`--proxy`）

| 模式     | 行为                                                                                                                                                                                                               |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `1panel` | 检测 1Panel OpenResty 容器（host 网络 + 挂载），只补齐已有站点缺失的必要指令（如 `proxy_buffering off;` 与 DERP 长连接所需的 `proxy_read/send_timeout`），`openresty -t` 通过才 reload。站点和证书请先在 1Panel 界面创建（upstream 填 `http://127.0.0.1:8080`）。 |
| `caddy`  | 80/443 空闲时自动安装 Caddy，用 BEGIN/END 标记管理专属站点块，`caddy validate` 通过才重载。                                                                                                                        |
| `nginx`  | 写入 `/etc/nginx/conf.d/headscale-bootstrap.conf`（标记块）。TLS 证书请在模板标注处自行提供，`nginx -t` 不过即还原。                                                                                               |
| `none`   | 不管理任何反代；TLS 归属需自行明确。                                                                                                                                                                               |
| `auto`   | 默认。按上述顺序自动判断，判断不了就阻断而不是猜。                                                                                                                                                                 |

域名必须直接解析到 VPS（Cloudflare 请用 DNS Only 灰云）；脚本从不修改
DNS 记录，也从不读取 1Panel 保存的 Cloudflare token。

## 自建 DERP 中继（enable-derp）

概念：Tailscale 数据面优先打洞直连；失败时经 DERP 中继兜底。本部署默认
不开内置 DERP，`derp.urls` 保留官方 map——兜底流量会绕道 Tailscale 官方
节点（对中国大陆通常是东京或法兰克福），且不受自己控制。`enable-derp`
把中继收回到你自己的 VPS 上：

```sh
# region 身份从域名推导（hs-nosla.example.com -> "nosla"）
sudo ./headscale-vps.sh --domain hs.example.com --expected-public-ip <IP> enable-derp
# 或显式命名
sudo ./headscale-vps.sh --derp-region-code tokyo --derp-region-name 'Tokyo VPS' enable-derp
sudo ./headscale-vps.sh disable-derp
```

行为边界：

- **托管键**：`derp.server.enabled` + region code/name + `ipv4`。region
  code 默认取域名首标签并去掉 `hs-` 前缀，已被 apply/update 继承不会
  改名；`ipv4` 取 `--expected-public-ip` 或域名解析出的公网 IPv4。包内
  示例的文档地址 `198.51.100.1`/`2001:db8::1` 会被替换/注释（否则会
  进客户端 DERP map），真实自定义值不动。
- **事务与修复**：标准 备份 → configtest → 重启 → 验证 流程，并自动
  修复 `headscale configtest` 以 root 预生成 DERP 私钥导致的属主问题
  （不修则服务 crash-loop）。验证 = UDP STUN 监听 + 本地 `/derp/probe`
  200；`apply`/`update` 之后同样复验。`install`/`apply` 不带参数时
  **保持当前开关状态**（`--enable-embedded-derp true|false` 显式覆盖）。
- **反代**：DERP 是长连接。1panel 模式会补齐
  `proxy_read/send_timeout 3600s`；nginx 模板已含同样指令（apply 刷新
  托管块）；Caddy 默认无此问题。
- **不做的事**：不动防火墙/云安全组——自行放行 STUN 端口（默认
  udp/3478）入站；不改 `derp.urls`——官方 map 保留为兜底，客户端按
  实测延迟自动择优。想强制只走自建就删掉 urls 里的官方条目再重启，
  代价是失去第三方灾备。
- **客户端**：无需任何改动，region 随 netmap 自动下发；`tailscale
  netcheck` 可看到自建 region 及其 STUN 延迟。

## 与透明代理共存（daed/dae、passwall2 等）

路由器上的透明代理按"兜底走代理"接管 tailscale 流量时，后果不是变慢，
而是**直连全灭**：

- STUN（UDP 3478）被代理 → 节点对外 advertised 的公网端点变成代理
  出口 VPS，NAT 穿越必然失败，全部回落 DERP 中继；
- DERP/控制面（TLS 443）被代理 → 中继之上再套一层代理，跨洲多跳。

识别特征：`tailscale netcheck` 的 `IPv4:` 是代理机 IP；`tailscale
status` 显示 `relay "…"`；`tailscale ping` 报 `direct connection not
established`。

### daed/dae checklist

每台**同时运行 tailscaled 或为 LAN 客户端当网关**的路由器都要加（放在
geosite/geoip/fallback 之前）：

```lua
pname(tailscaled) -> must_direct          -- 路由器自身流量（仅本机进程可匹配）
l4proto(udp) && dport(3478) -> direct     -- STUN，LAN 客户端靠这条救回
domain(suffix: tailscale.com) -> direct   -- 官方 DERP（使用官方 map 时）
domain(suffix: <login-server-域名>) -> direct  -- 控制面；每个 profile 的域名都要各加一条
```

- P2P 数据面无需单独规则：打洞成功后对端是真实公网 IP，已有的
  `dip(geoip:cn)` / `dip(geoip:private) -> direct` 会接住（含国内 IPv6）。
- 新登记 profile（如故障切换的备用 Headscale）时，同步补第四条 domain
  规则。

### passwall2 checklist（规则管理）

passwall2 不支持按进程名匹配，且其生成器会把域名/IP 拆成独立 Xray
路由规则（等效 OR），但 `端口` 字段会 AND 进每一条——"域名 + 端口
3478"混在一条规则里 = 只匹配"该域名且端口 3478"= 匹配不到任何流量。
必须拆两条，出站均选直连（_direct）：

| 规则 | 域名 | 端口 | 网络协议 |
| --- | --- | --- | --- |
| tailscale-domains | `tailscale.com`、各 login server 域名 | 留空 | tcp,udp |
| tailscale-stun | 留空（IP 也留空） | `3478` | 仅 udp |

路由器自身 tailscaled 若被 passwall2 接管，只能靠目标 IP/端口命中上述
规则，或确认 passwall2 未代理本机流量。

### 验证

```sh
tailscale netcheck         # IPv4 应为真实宽带出口，而非代理机 IP
tailscale ping <对端>       # 应出现 direct ...，而非 via DERP(...)
tailscale status           # 对端行应显示 direct
```

### LAN 客户端自己也在跑 Tailscale（DNS 接管冲突）

上面各节是"代理接管 tailscale 流量"；这里反过来：tailnet 接管客户端
的 DNS。LAN 内装了 Tailscale 的设备（如 Windows PC）默认
accept-dns=true，会应用控制端下发的 DNS 配置——若 tailnet 配了全局
解析器（如 1.1.1.1/1.0.0.1），该设备的一切解析都改道 tailscaled 的
本地代理 100.100.100.100 再转给全局解析器：绕开 daed 按域名分流的
设计，国内环境下直连 1.1.1.1 解析还会被污染。典型症状：设备一连上
Tailscale，DNS 就全坏。

处理：在该设备上拒绝 DNS 接管，并清掉已缓存的坏结果：

```sh
tailscale set --accept-dns=false
# 然后清本地 DNS 缓存：
#   Windows:  ipconfig /flushdns
#   Linux:    resolvectl flush-caches
#   macOS:    killall -HUP mDNSResponder
```

代价：MagicDNS 名字（<机器名>.<base_domain>）在该设备上不再可解析，
设备互访改用 tailscale IP（`tailscale status` 可查）。想保留
MagicDNS，可去控制端（官方管理台的 DNS 页，或 Headscale 配置的
dns 节）移除全局解析器、或改为 split DNS——没有全局解析器时，
100.100.100.100 只应答 MagicDNS 名字，其余查询回退给系统原 DNS
（即路由器/daed），两者即可共存。Headscale 侧直接用本仓库的
`enable-magic-dns`：它托管 dns 节、把全局解析器清空并把
`override_local_dns` 关掉（默认基域 `ts.<域名>`）。注意 headscale
打包示例自带 `magic_dns: true` + 全局解析器 1.1.1.1/1.0.0.1，
`install` 原样透传——`status` 会以 `dns-global-resolvers-pushed`
提示这一冲突，直到运行 enable/disable-magic-dns 表达意图。

路由器侧无需改动：join 默认 `--accept-dns=false`，apply 与 failover
都会收敛漂移，status 会把 accept-dns=true 标为 unsafe-accept-dns。
LAN 客户端设备不归脚本管，需如上逐台手动设置。

## 备份与回退

- VPS 默认备份目录：`/var/backups/headscale-bootstrap/`
- OpenWrt 默认备份目录：`/root/tailscale-bootstrap-backups/`

每次备份新建 UTC 时间戳目录（同秒自动加 `-N` 后缀，不覆盖旧备份），
包含 `manifest.sha256` 清单与 `metadata.txt`。`metadata.txt` 中的
`service_running=` 标明快照是否在服务运行时复制——这类快照里的 SQLite
文件可能内部不一致，`rollback` 恢复时会明确告警。带 `.INCOMPLETE` 标记
的目录不会被 rollback 接受。

```sh
cd /var/backups/headscale-bootstrap/<timestamp> && sudo sha256sum -c manifest.sha256
```

备份属于敏感运维数据，请保持在 Git 之外（`.gitignore` 已覆盖常见敏感
文件名；唯一例外是测试用的假身份 fixture，按精确路径放行）。

## 状态文件

- VPS：`/var/lib/headscale-bootstrap/state.json`
- OpenWrt：`/etc/tailscale-bootstrap/state.json`

只记录非秘密的管理信息（domain、proxy_mode、service_mode、login_server、
profiles、failover_enabled、subnets 等）。auth key、API token、
`tailscaled.state` 内容永不写入。多 profile 列表本身的权威来源是
`/etc/config/tailscale-bootstrap`（UCI），watchdog 每个周期重新读取，
改表即时生效、无需重启。

## 把脚本放到没有 Git 的设备上

两个入口会按相对路径加载 `lib/` 下的库文件，因此不支持
`curl .../headscale-vps.sh | sh`。请保持目录结构下载（生产环境建议固定
为已审阅的完整 commit SHA，不要用会漂移的 `main`）：

```sh
RAW_BASE=https://raw.githubusercontent.com/blooddrunk/headscale-openwrt-bootstrap/<SHA>
TARGET=/root/headscale-openwrt-bootstrap
fetch() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -O "$2" "$1"
    else echo '需要 curl、wget 或 uclient-fetch' >&2; return 1; fi
}
mkdir -p "$TARGET/lib"
for path in headscale-vps.sh tailscale-openwrt.sh \
            lib/log.sh lib/common.sh lib/backup.sh lib/version.sh lib/state.sh lib/net.sh \
            lib/vps-ops.sh lib/openwrt-ops.sh; do
    fetch "$RAW_BASE/$path" "$TARGET/$path"
done
sh -n "$TARGET"/*.sh "$TARGET"/lib/*.sh   # 下载后先做语法检查
chmod 700 "$TARGET"/*.sh "$TARGET"/lib/*.sh
```

## 运行测试

```sh
./tests/test-milestone1.sh          # 只读探测、指纹、硬阻断、私有备份
./tests/test-vps-install.sh         # VPS 安装/apply、1Panel 与 Caddy 路径
./tests/test-openwrt-core.sh        # 包/core/fw4 事务/join（含多网络守卫）
./tests/test-openwrt-subnet.sh      # subnet 与 WAN UDP 事务
./tests/test-update-rollback.sh     # 双端升级顺序、回退、清理
./tests/test-failure-injection.sh   # 失败注入、幂等、重启稳态
./tests/test-openwrt-failover.sh    # profile 登记/切换/移除、watchdog 决策
```

测试完全离线：使用临时 fixture 根目录和受控的假命令（可注入故障），
不会触碰真实 VPS 或路由器，也不会执行任何目标 init 脚本。依赖 POSIX
`sh`、`jq`、`sha256sum`；OpenWrt 用例需要宿主机存在 `/dev/net/tun`，
否则相应部分自动跳过。详见 [tests/README.md](tests/README.md)。

## 仓库结构

```text
headscale-vps.sh            VPS 端入口
tailscale-openwrt.sh        OpenWrt 端入口
lib/                        共享库与两端操作实现
templates/                  tailscale-core/failover 服务与反代配置模板
tests/                      fixture 测试与假命令（均为合成数据）
```

## 已知边界

- 1Panel 站点与 TLS 证书需在 1Panel 界面人工创建；脚本只负责校验与补齐
  站点内缺失的必要指令。
- `enable-derp` 不管理防火墙/云安全组；STUN 端口（默认 udp/3478）需
  自行放行，否则客户端 netcheck 只能看到 DERP 延迟而 STUN 超时。
- nginx 模式不负责申请证书。
- 不支持同时连接多个 Headscale 网络（官方客户端同一时刻只有一个活动
  tailnet）。多网络场景使用 profile 列表 + failover 在网络间串行切换
  （见上文"多 profile 与故障切换"）；若要真正同时在线，只能运行多个
  独立的 tailscaled 实例，超出本项目范围。
- failover 的健康探测是控制面探测（`/health`）加 BackendState 检查，
  不代表该网络的数据面对你可用：每个登记的网络里仍需存在你可达的对端
  节点，切换后才有远程入口。
- 路由器真机重启后的完整验收建议人工执行一次（重启后运行 `status`
  即为自动检查）。
- LuCI 界面里的"启用/停止/重启 Tailscale"按钮在本部署中不可用，daemon
  由 `tailscale-core` 管理。
- 脚本管不到 LAN 客户端设备（如 Windows）上的 Tailscale 偏好；透明
  代理共存场景下客户端侧的 accept-dns 设置见"与透明代理共存"。
