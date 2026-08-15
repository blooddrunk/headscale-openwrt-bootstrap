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
- **默认最小权限**：exit node、IPv6 subnet routing、embedded DERP 默认
  关闭（后两者本版未实现，显式请求会被拒绝）；subnet router 使用
  Tailscale 自身 SNAT，fw4 tailscale zone 不额外开启 masquerade。

## 快速开始

### VPS 端（headscale-vps.sh）

~~~sh
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
~~~

### OpenWrt 端（tailscale-openwrt.sh）

~~~sh
scp -r headscale-openwrt-bootstrap root@192.168.1.1:/root/
ssh root@192.168.1.1
cd /root/headscale-openwrt-bootstrap

# 1. 只读体检：包、危险 helper、TUN、fw4、当前 ControlURL 等
./tailscale-openwrt.sh --login-server https://hs.example.com discover
./tailscale-openwrt.sh --login-server https://hs.example.com plan

# 2. 安装 tailscale 包 + tailscale-core 服务（危险 stock 服务只会被 disable）
./tailscale-openwrt.sh --login-server https://hs.example.com install

# 3. 注册节点（auth key 文件需为 0400/0600 权限，注册成功后自动删除）
./tailscale-openwrt.sh --login-server https://hs.example.com \
    --auth-key-file /tmp/hs-auth-key join

# 4. （可选）把 LAN 网段作为 subnet router 广播出去
./tailscale-openwrt.sh --login-server https://hs.example.com enable-subnet
~~~

`enable-subnet` 会自动从 `ubus` 读取 LAN 地址并正确计算网络 CIDR（例如
192.168.10.129/25 → 192.168.10.128/25），随后停在"已广告、等待批准"
状态，并打印 VPS 侧的批准命令：

~~~sh
# 在 VPS 上执行
sudo ./headscale-vps.sh approve-route --node-id <ID> --route 192.168.10.0/24
~~~

## 多 profile 与故障切换（OpenWrt 端）

远程只能通过 tailnet 访问的路由器有一个现实风险：控制服务器一挂，
人就再也无法远程登录路由器去手动换网。profile 列表 + failover 守护
进程就是为这个场景准备的——它仍然**不会同时连接两个网络**（官方客户端
同一时刻只有一个活动 tailnet），只是把"已注册的多个网络"登记在路由器
上，由 watchdog 在当前网络失效时自动切换：

~~~sh
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
./tailscale-openwrt.sh enable-failover            # 可选调参见 --help
./tailscale-openwrt.sh status                     # 含 failover 健康项

# 5. 随时把某个网络从列表移除（加 --delete-identity 会同时注销该身份）
./tailscale-openwrt.sh --login-server https://hs-b.example.com profile-remove
~~~

watchdog（`/usr/sbin/tailscale-failover`，procd 守护 `tailscale-failover`）
的行为边界：

- 每 `check_interval` 秒探测所有登记网络的 `login_server/health`
  （curl → wget → uclient-fetch，需要可用 CA 证书）；
- 活动网络连续 `failure_threshold` 次探测失败（或控制面可达但
  BackendState ≠ Running，例如节点被服务端吊销）即切换到优先级最高
  （数字最小）且连续 `recovery_threshold` 次探测正常的候选；
- `--failback true` 才会回切更高优先级网络，默认保持稳定；
- `cooldown` 秒内不发生第二次切换，切换后立即收敛安全偏好
  （accept-dns=false / accept-routes=false）；
- 手动切到列表之外的网络时，只要它健康 watchdog 就不干预；失效才接管；
- 它只调用 `tailscale switch`，从不 login、从不使用 auth key、
  从不改 netifd/fw4；配置与身份分离：列表在
  `/etc/config/tailscale-bootstrap`（项目自有文件），身份仍在
  `/etc/tailscale/tailscaled.state`；
- 守护文件带指纹校验，被篡改后 plan/status 会阻断，
  `enable-failover` 自动备份并从模板修复。

注意事项：每个网络都需要一个你能访问的对端节点（手机/电脑同时加入
两个 tailnet，或两个网络各有一个 exit node），否则切换后依旧没有入口。
每台 Headscale 侧的路由批准（approve-route）是独立的，切换后如需
subnet router 需在新服务器重新批准。

## 命令参考

两个脚本都支持 `--json`、`--quiet` 机器可读输出；`discover`/`plan`/
`status` 永远只读，`plan` 发现硬冲突时退出码为 2。

| 命令 | 端 | 说明 |
| --- | --- | --- |
| `discover` / `plan` / `status` / `verify` | 双端 | 只读检查环境、展示计划、校验健康 |
| `backup` | 双端 | 创建带 manifest 的私有时间戳快照，不停服务 |
| `install` | 双端 | 全新安装（VPS：.deb；OpenWrt：opkg/apk 包 + tailscale-core） |
| `apply` | 双端 | 幂等收敛：已满足的状态不会重做、不会无谓重启 |
| `join` | OpenWrt | 用 `file:` auth key 注册，拒绝静默切换 ControlURL |
| `profile-list` / `profile-add` / `profile-remove` | OpenWrt | 多网络登记表（增/删/查，`--priority` 定优先级，`--delete-identity` 同时注销身份） |
| `switch-to` | OpenWrt | 手动切换到列表中的某个网络（经 ControlURL 校验） |
| `enable-failover` / `disable-failover` | OpenWrt | 安装/启动/停止按优先级与健康探测自动切换的 watchdog |
| `enable-subnet` / `disable-subnet` | OpenWrt | 广播/撤回 LAN 网段，附 fw4 forwarding 事务 |
| `allow-wan-udp [false]` | OpenWrt | 添加/移除最窄的 WAN UDP 41641 入站规则 |
| `update` | 双端 | 升级（VPS 遵守 minor 顺序；OpenWrt 只重启 tailscale-core 并校验身份不变） |
| `rollback [BACKUP_ID]` | 双端 | 把配置+数据+（VPS）软件包作为一个快照整体恢复 |
| `cleanup` | 双端 | 删除脚本自管的内容，保留数据/身份/软件包 |
| `purge` / `purge-identity` | 双端 | 破坏性操作，必须 `--yes-i-understand`，执行前做最终备份 |
| `ensure-user` / `issue-key` / `approve-route` | VPS | 用户与注册密钥管理、路由批准 |

常用参数：VPS 侧 `--domain`、`--expected-public-ip`、`--proxy`、
`--listen/--metrics-listen/--grpc-listen`、`--version`、`--user`、
`--expiration`、`--output`、`--node-id`、`--route`；OpenWrt 侧
`--login-server`、`--auth-key-file`、`--service-mode`、`--accept-dns`、
`--accept-routes`、`--subnet`、`--min-client-version`、`--priority`、
`--delete-identity`，以及 enable-failover 的
`--check-interval/--failure-threshold/--recovery-threshold/--failback/
--cooldown/--probe-timeout/--health-path`。完整列表见
`--help`。

## 反向代理模式（`--proxy`）

| 模式 | 行为 |
| --- | --- |
| `1panel` | 检测 1Panel OpenResty 容器（host 网络 + 挂载），只补齐已有站点缺失的必要指令（如 `proxy_buffering off;`），`openresty -t` 通过才 reload。站点和证书请先在 1Panel 界面创建（upstream 填 `http://127.0.0.1:8080`）。 |
| `caddy` | 80/443 空闲时自动安装 Caddy，用 BEGIN/END 标记管理专属站点块，`caddy validate` 通过才重载。 |
| `nginx` | 写入 `/etc/nginx/conf.d/headscale-bootstrap.conf`（标记块）。TLS 证书请在模板标注处自行提供，`nginx -t` 不过即还原。 |
| `none` | 不管理任何反代；TLS 归属需自行明确。 |
| `auto` | 默认。按上述顺序自动判断，判断不了就阻断而不是猜。 |

域名必须直接解析到 VPS（Cloudflare 请用 DNS Only 灰云）；脚本从不修改
DNS 记录，也从不读取 1Panel 保存的 Cloudflare token。

## 备份与回退

- VPS 默认备份目录：`/var/backups/headscale-bootstrap/`
- OpenWrt 默认备份目录：`/root/tailscale-bootstrap-backups/`

每次备份新建 UTC 时间戳目录（同秒自动加 `-N` 后缀，不覆盖旧备份），
包含 `manifest.sha256` 清单与 `metadata.txt`。`metadata.txt` 中的
`service_running=` 标明快照是否在服务运行时复制——这类快照里的 SQLite
文件可能内部不一致，`rollback` 恢复时会明确告警。带 `.INCOMPLETE` 标记
的目录不会被 rollback 接受。

~~~sh
cd /var/backups/headscale-bootstrap/<timestamp> && sudo sha256sum -c manifest.sha256
~~~

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

~~~sh
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
~~~

## 运行测试

~~~sh
./tests/test-milestone1.sh          # 只读探测、指纹、硬阻断、私有备份
./tests/test-vps-install.sh         # VPS 安装/apply、1Panel 与 Caddy 路径
./tests/test-openwrt-core.sh        # 包/core/fw4 事务/join（含多网络守卫）
./tests/test-openwrt-subnet.sh      # subnet 与 WAN UDP 事务
./tests/test-update-rollback.sh     # 双端升级顺序、回退、清理
./tests/test-failure-injection.sh   # 失败注入、幂等、重启稳态
./tests/test-openwrt-failover.sh    # profile 登记/切换/移除、watchdog 决策
~~~

测试完全离线：使用临时 fixture 根目录和受控的假命令（可注入故障），
不会触碰真实 VPS 或路由器，也不会执行任何目标 init 脚本。依赖 POSIX
`sh`、`jq`、`sha256sum`；OpenWrt 用例需要宿主机存在 `/dev/net/tun`，
否则相应部分自动跳过。详见 [tests/README.md](tests/README.md)。

## 仓库结构

~~~text
headscale-vps.sh            VPS 端入口
tailscale-openwrt.sh        OpenWrt 端入口
lib/                        共享库与两端操作实现
templates/                  tailscale-core/failover 服务与反代配置模板
tests/                      fixture 测试与假命令（均为合成数据）
~~~

## 已知边界

- 1Panel 站点与 TLS 证书需在 1Panel 界面人工创建；脚本只负责校验与补齐
  站点内缺失的必要指令。
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
