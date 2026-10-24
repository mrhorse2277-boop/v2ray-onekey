# V2Ray/Xray 多模式一键脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

参考 [wulabing/V2Ray_ws-tls_bash_onekey](https://github.com/wulabing/V2Ray_ws-tls_bash_onekey) 的架构重写,
支持 **ws+tls / xhttp+tls / socks5 / vless+REALITY 四种模式同时安装、互不冲突**,分享链接适配最新版
[v2rayN](https://github.com/2dust/v2rayN) / [v2rayNG](https://github.com/2dust/v2rayNG) 正式版。

> 维护者请先读 [MAINTENANCE.md](MAINTENANCE.md)——架构要点、版本敏感点、每轮测试清单都在那里。

## 四种模式与共存方式

| 模式 | 端口 | TLS/伪装 | 组件 | 抗封锁 |
|---|---|---|---|---|
| vmess/vless + ws + tls | 443 | Nginx TLS 终结 + 静态伪装站 | Nginx + acme.sh 证书 | 中 |
| vmess/vless + xhttp + tls | 随机独立端口 | Xray 直接 TLS | 不依赖 Nginx | 中 |
| socks5 (带认证) | 随机独立端口 | 明文 | V2Ray socks 入站 | 无 |
| **vless + REALITY** | 443(空闲时)/随机 | Xray REALITY,借用真实大站证书 | Xray core | **强(推荐)** |

四种模式各自使用独立的:

- 配置文件:`config_ws.json` / `config_xhttp.json` / `config_socks.json` / `config_reality.json`
- systemd 服务:`v2ray-ws` / `xray-xhttp` / `v2ray-socks` / `xray-reality`
- 核心:V2Ray (ws/socks) + Xray (xhttp/REALITY),分别用官方脚本安装
- 端口:安装时自动分配并查重(`used_ports.txt` 记录),任意组合互不占用

> **为什么是 xhttp 而不是 h2**:Xray 自 v24.12.31 起**删除**了 HTTP(h2) 传输
> (`The feature HTTP transport ... has been removed`),v2rayN 的传输白名单也已移除
> h2/http,v2rayNG 内置内核同步删除——h2 节点对当前所有客户端都已失效。
> xhttp 是 Xray 官方指定的继任者(2024-11 起两个客户端均支持),本脚本 1.5.0 起
> 该模式改用 xhttp 传输并使用 Xray 核心。**已装 h2 的机器跑一次菜单 15 即可自动迁移**
> (保留 UUID/端口/路径,服务从 `v2ray-h2` 换成 `xray-xhttp`)。
>
> 历史说明:原项目的 h2 模式是 V2Ray 直接占 443、Nginx 退出,因此原版 h2 与 ws 天然互斥;
> 本脚本把它改为独立端口直连,才能与 ws(443)共存。REALITY 在 443 空闲时用 443,
> 已被 ws 占用时自动落到独立端口,同样可共存。

## 支持系统

### 推荐安装系统

**Debian 12** 或 **Ubuntu 22.04 / 24.04**。

### 测试覆盖的实际情况

| 发行版 | 版本 | 状态 | 实测内容 |
|---|---|---|---|
| Debian | **11 / 12 / 13** | ✅ **实测通过** | 12 为 VPS 真机全量回归;11/13 在独立发行版用户空间(systemd-nspawn)完整跑通 |
| Ubuntu | **18.04 / 20.04 / 22.04 / 24.04** | ✅ **实测通过** | 均在独立发行版用户空间完整跑通 |
| CentOS | 8 | ⚠️ 代码级支持,未验证 | — |
| Rocky / AlmaLinux | 8 / 9 | ⚠️ 代码级支持,未验证 | — |
| Fedora / Oracle Linux / RHEL | — | ⚠️ 代码级支持,未验证 | — |
| **CentOS 7** | 7 | ❌ **不支持** | bash 4.2 / systemd 219 低于门槛 |

**1.5.0 对 Debian 11/12/13 与 Ubuntu 18.04~24.04 的实测项目**(每个版本都跑):

1. `bash -n` 语法检查
2. 版本预检 + 组名探测(`nogroup` 在六个版本上均正确)
3. OpenSSL 能力检测(18.04 的 1.1.0g 正确走降级路径,其余走严格 TLS1.3)
4. socks5 真实安装 → 服务 `active`、`User=nobody`/`Group=nogroup`、端口监听、配置 `root:nogroup 640`
5. 代理实测连通(**HTTP 200**)
6. 菜单 7 链接生成(含两种工具格式)
7. 卸载 → 服务 inactive、配置文件删除干净

> **测试环境说明**:Debian 12 是 VPS 真机;其余五个版本用 `debootstrap` 引导真实发行版
> 用户空间 + `systemd-nspawn` 启动真实 systemd 跑测(非模拟、非容器化阉割)。
> 差异在于共享宿主内核,未覆盖:内核参数、云厂商安全组、独立磁盘/网卡驱动。
>
> **未验证项**:REALITY / ws / xhttp 三模式的完整安装(需要域名+证书,容器内不便申请),
> 以及菜单 10/11/12/15 的交互流程。这些在 Debian 12 真机上已验证。

### 技术依赖(可自行核对你的系统)

| 依赖 | 最低要求 | 各版本基线 |
|---|---|---|
| bash | **4.3+**(脚本用 `local -n` nameref) | Debian 11+: 5.1+;Ubuntu 18.04+: 4.4+ |
| systemd | **229+**(`AmbientCapabilities`) | Debian 11+: 247+;Ubuntu 18.04+: 237+ |
| 包管理器 | apt-get / dnf / yum 之一 | — |

### 依赖自动检测与安装

脚本在**弹出主菜单之前**就会检查依赖,不需要先选安装项:

```
启动 → 检查 root → 检查系统版本 → 检测并补齐依赖 → 弹出主菜单
```

- **基础命令缺失**(coreutils/awk/sed 等) → 直接报错退出,这些无法自动修复
- **运行时依赖缺失**(curl/openssl/ss/timeout/shuf/od/base64):
  交互模式会列出缺失项并询问是否安装(默认 Y);非交互(一键命令)直接安装不打断
- **可选组件缺失**(qrencode/socat) → 只提示不安装,核心功能不受影响

安装采用多级兜底,**不会静默跳过**:索引刷新 → 批量安装 → `--fix-missing` 重试 →
逐个包安装。同时处理 dpkg 锁占用(等 60s)、半装状态(`dpkg --configure -a`)、
磁盘不足、命令挂死(全程 `timeout`)等最差情况。

装完以 `command -v` 实际复核为准。若仍失败,会明确告知缺少什么、完整日志位置
(`/tmp/v2ray_deps_install.log`)、以及可直接复制执行的手动安装命令,并说明
哪些功能会受影响(菜单 7 链接生成、REALITY 选站、端口查重、下载安装)。
此时仍允许进入菜单——至少能查看已装节点或卸载。

### OpenSSL 版本兼容(1.5.0 已修复)

旧版 OpenSSL 缺两个脚本用到的能力,**1.5.0 之前会导致 Ubuntu 18.04 上 REALITY 完全装不上**:

| 用法 | 需要版本 | 低版本表现 | 修复方式 |
|---|---|---|---|
| `openssl s_client -tls1_3` | 1.1.1+ | `Option unknown option -tls1_3`,探测输出为空 | 自动检测,降级到 `-tls1_2` 握手校验 |
| `openssl x509 -ext subjectAltName` | 1.1.1+ | `x509: Unknown digest ext` | 降级到 `-text` 全文解析 |

Ubuntu 18.04 自带 OpenSSL **1.1.0g**,以上两条都会触发。修复后实测:三个候选伪装站
在 1.1.0g 下全部通过校验(修复前全部被判失败);Debian 12(OpenSSL 3.0)仍走严格
TLS1.3 路径,未被降级。

> 降级判定偏松(只验 TLS1.2 握手可达),可能放过个别不支持 TLS1.3 的站,
> 但远好过全部判死导致装不上。REALITY 本身仍按 Xray 要求工作。

**为什么 CentOS 7 不支持**:它的 bash 是 4.2,不支持 `local -n`(nameref 自 4.3 引入),
脚本的 REALITY 选站与菜单 7 链接收集会直接报 `local: -n: invalid option`;
且 systemd 219 低于 `AmbientCapabilities` 所需的 229,REALITY 监听 443 会失败。
脚本会在预检阶段明确拒绝,而不是中途出错。

> **RHEL 系请谨慎使用。** 脚本对该系列做了代码级适配(包管理器分支、组名探测、
> SELinux 放行),但**没有在真机上跑过完整安装/卸载/迁移回归**。已知差异包括:
> systemd 版本、`nobody` 组名、SELinux Enforcing 策略、firewalld 行为、
> nginx 打包方式等。安装时会打印醒目警告,交互模式下要求确认;
> 非交互模式只警告不阻塞(避免一键命令被卡住)。

CentOS 8 已停止维护。

## 与已有网站 / 宝塔面板共存

脚本会**自动探测现有 Nginx 环境**,分三种情况处理:

| 环境 | 行为 |
|---|---|
| 宝塔面板 | 复用宝塔自编译 Nginx,站点配置写入 `/www/server/panel/vhost/nginx/v2ray-ws-tls.conf`,**不安装第二个 Nginx**,不碰面板与已有网站 |
| 已有发行版 Nginx | 直接复用,配置写入 `/etc/nginx/conf.d/`,只 reload 不 restart |
| 全新系统 | 才安装发行版 Nginx |

防破坏设计:

- 安装依赖时**不再盲装 Nginx**——先探测,已有的复用
- 共存场景(检测到宝塔或已有 Nginx)下,ws 模式**不监听 80 端口**,只在 443 的 server_name 上追加代理路径,不干扰原有网站
- 输入的域名若已被现有网站使用(如宝塔站点),会明确警告并要求确认,防止误把业务域名装坏
- 首次证书签发会先写一个仅含 acme 验证目录的临时 80 端口配置,签发后立即删除,不影响已有站点
- 证书续签回调只做 Nginx reload 和本脚本服务重启,绝不 stop/restart 整个 Nginx
- 卸载只删除本脚本自己的配置文件,然后平滑 reload Nginx,已有网站全程无感

零冲突模式:**REALITY 与 socks5 不需要域名和证书,在任何环境(包括宝塔)都可放心安装**。

## 使用

准备:境外 VPS。ws 与 xhttp 模式需要域名(已解析 A 记录);socks5 和 REALITY **不需要域名和证书**。

```bash
# 一键下载并进入交互菜单 (将 mrhorse2277-boop/v2ray-onekey 替换为实际仓库路径)
wget -N --no-check-certificate -q -O install.sh "https://raw.githubusercontent.com/mrhorse2277-boop/v2ray-onekey/main/install.sh" && chmod +x install.sh && bash install.sh

# 非交互
bash install.sh ws vmess     # vmess + ws + tls (Nginx, 443)
bash install.sh ws vless     # vless + ws + tls
bash install.sh xhttp vmess  # vmess + xhttp + tls (独立端口, 旧参数 h2 仍接受)
bash install.sh xhttp vless  # vless + xhttp + tls
bash install.sh socks        # socks5 (随机用户名/密码, 独立端口)
bash install.sh reality      # vless + REALITY (抗封锁首选, 免域名/证书)
bash install.sh info         # 查看全部已安装节点并导出链接
bash install.sh checkreality # REALITY 伪装站健康巡检 (只读)
bash install.sh uninstall socks   # 卸载单模式 (可换 ws|xhttp|reality|all; 不带参数则交互选择)
```

重复执行不同的安装命令即可同时安装多种模式,例如:

```bash
bash install.sh reality && bash install.sh ws vless && bash install.sh socks
```

安装完成后每种模式都会输出:完整节点参数、**分享链接**(追加保存到 `/root/v2ray_share_url.txt`)、**终端二维码**。

### REALITY 模式说明

- 自动生成 x25519 密钥对与 shortId,无需任何人工输入
- 内置多个伪装目标站(按地区分组),安装时逐一用 TLS 1.3 + H2 探测校验并实测延迟,**自动剔除被 GFW 封锁的站点**(不在封锁列表的也经部署前终验兜底),最终选用延迟最低的可用站;菜单 10 可随时换站
- 客户端流控为 `xtls-rprx-vision`,指纹模拟 chrome
- 443 端口空闲时直接监听 443(伪装效果最佳);被占用时自动换独立端口
- **菜单 16 / `bash install.sh checkreality` 健康巡检**(只读):随时复查伪装站
  是否仍满足 TLS1.3+H2、是否被列入 GFW 封锁列表、实测延迟;劣化时提示跑
  菜单 10 换站(保留 UUID/端口/密钥,客户端只改 SNI)

### ws 模式走 Cloudflare CDN 中转(1.6.0 起)

ws+tls 模式支持域名解析到 Cloudflare(橙云代理)的 CDN 中转部署。**选择入口在
安装 ws 的流程里**(菜单 1/2 或一键命令),不是独立菜单项:

- **交互安装**:输入域名后,脚本检测到解析落在 CF 公布的 IP 段,会**明确询问
  "启用 CDN 中转模式? [Y/n]"**,回车默认启用;选 n 按直连继续(会提示灰云/
  证书风险)
- **非交互一键命令**:检测到 CF 解析自动启用;`CF_MODE=1` 可**强制启用**——
  适合域名暂时灰云直连、证书签好后再开橙云的场景
- xhttp 模式检测到 CF 解析会明确提示**不支持 CDN 中转**(CF 代理的缓冲会破坏
  xhttp 流式传输),需要 CDN 请用 ws 模式

启用后:

- 流量路径:客户端 → CF 边缘 → 回源本机 443(nginx),VPS 真实 IP 不直接暴露
- 证书签发改走 **DNS-01**(`acme.sh` 的 `dns_cf`),不需要 80 端口可达:
  - 非交互:`CF_Token=xxx CF_Account_ID=xxx CF_Zone_ID=xxx bash install.sh ws vless`
    (或旧式 `CF_Email` + `CF_Key`);凭据仅用于本次签发,不落盘
  - 交互模式无环境变量时会逐项询问
  - 也可自备证书放到 `/data/v2ray.crt` 与 `/data/v2ray.key` 后安装,跳过申请
- 安装完成后提示在 CF 面板确认 SSL/TLS 模式为 **Full (strict)**(WebSocket 现代账户默认开启)
- 分享链接与直连 ws 完全一致,客户端无需特殊设置


### 端口选择

所有需要端口的操作(安装 ws 独立端口/xhttp/socks5/REALITY、菜单 11/12 重置端口)都会询问:

```
  1. 使用默认端口 (ws/xhttp/REALITY 8443, socks5 10808)
  2. 随机分配端口 (自动避开占用与本脚本其他节点)
  3. 自定义端口 (1000-65535)
  b. 返回上一级 (取消本次操作)
```

三种选择均做双重占用检查(`ss` 实际监听 + 本脚本端口记录),不通过则提示并返回重选;
非交互模式(CLI 子命令)自动随机分配。v2ray 内部回环端口(proxy_pass)不询问,保持随机。

### 菜单导航

- 主菜单 `0` = 退出脚本
- 所有子菜单 `0` = 返回主菜单;两层嵌套菜单(重置节点)第二层 `b` = 返回上一级
- 端口选择、伪装站选择随时可输 `b` 取消本次操作(取消后配置原样不动)

### 客户端导入

- **v2rayN(Windows)**:复制分享链接 → 剪贴板批量导入;或「服务器 → 扫描屏幕上的二维码」
- **v2rayNG(Android)**:「+」→ 从剪贴板导入 / 扫描二维码

链接字段与最新版客户端对齐(依据 v2rayN 源码解析逻辑):

- vmess:v2 JSON,`aid=0` 走 AEAD,含 `scy` / `sni` / `fp` 字段;xhttp 模式 `net=xhttp` + `type=auto`(即 xhttp mode)、`alpn=h2`
- vless:标准 URI,`encryption=none`,`path` URL 编码,含 `sni` / `fp`;xhttp 模式 `type=xhttp&mode=auto&alpn=h2`
- REALITY:`vless://...?type=tcp&security=reality&pbk=公钥&sid=shortId&sni=伪装域名&fp=chrome&flow=xtls-rprx-vision&encryption=none`
- socks:`socks://base64(user:pass)@IP:端口#备注`(v2rayN 新格式,明文旧格式也兼容)

## 菜单功能

| 选项 | 功能 |
|---|---|
| 1–2 | 安装 vmess/vless + ws + tls |
| 3–4 | 安装 vmess/vless + xhttp + tls |
| 5 | 安装 socks5 |
| 6 | 安装 vless + REALITY |
| 7 | 查看全部已安装节点 / 导出全部分享链接 |
| 8 | 手动续签 / 重新申请证书(ws/xhttp 共用) |
| 9 | 更新 V2Ray / Xray core(**只更新实际已装的内核**;REALITY-only 机器不会被顺手装 v2ray,反之亦然) |
| 10 | 更换 REALITY 伪装站(保留 UUID/端口,客户端只改 SNI) |
| 11 | 重置 REALITY 节点(端口 / UUID / 密钥 / 全部) |
| 12 | 重置 ws/xhttp/socks 节点(端口 / UUID / 用户密码) |
| 13 | 卸载(单模式或全部;单模式卸载同时回收端口记录) |
| 14 | 更新脚本(从 GitHub 下载最新版覆盖本地脚本,带合法性/语法校验与回滚) |
| 15 | 升级已装节点配置(保留 UUID/端口/密钥,按序补跑新版脚本的配置迁移) |
| 16 | REALITY 伪装站健康巡检(只读:TLS1.3+H2 / GFW 列表 / 延迟;劣化提示换站,结论同步到菜单头部) |
| 0 | 退出 |

重置端口/安装端口支持"默认/随机/自定义"三选一(见上文端口选择)。

**菜单头部会显示版本与配置状态**(宽度都控制在边框内 52 列),一眼看出要不要更新:

```
  脚本版本 : v1.5.3 → v1.5.4  🔴 建议更新 (菜单 14)
  节点配置 : 🔴 2 条待升级 (菜单 15)
  Xray内核 : 26.3.27 → 26.10.21 🔴 可更新 (菜单 9)
  V2Ray内核: 5.53.0  🟢 无需更新
  伪装站   : www.dbs.com  🟢 健康
```

脚本版本一行的状态取值:🟢 无需更新(本地与远端一致,只显示一个版本号)/
🔴 建议更新 / 🟢 本地较新 / ⚪ 检测失败(网络不通)。

内核行**只对已安装的 core 显示**(没装 Xray 就没有 Xray 内核行),版本号与
`xray version` / `v2ray version` 输出一致(不带 v 前缀)。有新版本时显示
当前 → 最新并指向菜单 9;最新版号取自 GitHub releases 的最新 tag,同样缓存 6 小时,
菜单 9 更新完内核会自动作废缓存、下次进菜单重新确认。

节点配置一行显示的是**已装节点里还有几条配置迁移没做**。判定不看历史记录文件,
而是直接读当前配置内容(是否残留旧 h2 配置、freedom 出站有没有 `domainStrategy`),
所以全新安装不会误报、手工改过配置的机器也能准确判定:

```
  节点配置 : 🟢 已是最新配置, 无需升级
  节点配置 : 🔴 1 条待升级 (菜单 15)
  节点配置 : 未安装节点 (菜单 1-6)
```

跑一次菜单 15 后提示会自动变回 🟢——判定依据是配置内容本身,不是写标记。

伪装站一行(1.6.1 起,已装 REALITY 才显示)是**伪装站健康巡检的结论**:🟢 健康 /
🔴 建议换站 (菜单 10,已进 GFW 封锁列表时) / 🔴 待复查 (菜单 16,TLS 探测不达标
时——可能是站点变化也可能是本机网络问题,菜单 16 有明细)。巡检要 TLS 握手 + GFW
列表 + 延迟探测,为不拖慢菜单刷新,结论缓存 6 小时;菜单 16 手动巡检、菜单 10
换站成功、REALITY 安装成功都会立即刷新结论。

最新版本号会缓存 6 小时,不会每次进菜单都联网(避免 GitHub 被墙时卡顿);
菜单 14 更新成功后会写入新版本号缓存,立即反映新状态。

菜单 10/11/12 变更完成后,除显示新链接外还会直接渲染**分享链接二维码**,
手机 v2rayNG 扫码即可导入(qrencode 未装时静默跳过)。

节点链接始终从实际配置文件**现场生成**:菜单 7 展示/导出的内容、菜单 10/11/12
变更后的新链接,均直接读取磁盘上的当前配置(REALITY 公钥由私钥现场推导),
即使手工改过配置也能保证导出的链接与实际运行配置一致;导出文件
`/root/v2ray_share_url.txt` 每次运行菜单 7 时重建,只含当前有效链接。

所有模式的代理**出站**固定走 **IPv4**(freedom 出站 `domainStrategy: UseIPv4`),
避免 VPS 的 IPv6 回程质量不稳导致部分站点访问异常。

**入站双栈监听**(1.6.0 起):socks5 / xhttp / REALITY 三个直连模式不再写死
`listen: 0.0.0.0`,内核按通配地址监听——VPS 有 IPv6 时同时接受 IPv4 与 IPv6
客户端连接(已实测:`[::1]` 回环 REALITY 握手与 socks 代理连通均通过,六系统
容器矩阵全部验证),VPS 无 IPv6 时自动回退仅 IPv4,不影响原有行为。存量机器跑
菜单 15 自动迁移。注:分享链接仍使用 IPv4 地址;VPS 具备公网 IPv6 时可手工把
链接里的地址换成 v6 地址使用。

> **xhttp 模式的客户端支持**:v2rayN 7.1.0+ / v2rayNG 1.9.10+ 可直接导入使用
> (两者均于 2024-11 加入 xhttp)。更早的客户端不支持 xhttp,且旧的 h2 传输已被
> Xray 内核删除、同样无法使用,请升级客户端。脚本安装与查看节点时均会提示。

## 已装机器升级

已安装过旧版脚本的机器:先菜单 14 把脚本本体更新到最新,再跑一次**菜单 15**——
在保留 UUID/密码/密钥/端口/伪装站/证书的前提下,把新版脚本引入的配置变更按序补进
现有配置(每条迁移幂等、改前备份、改后校验、失败自动回滚),完成后自动重启受影响的
服务并重建导出链接。CLI 等价命令 `bash install.sh upgrade`。
1.3.0 起的所有配置级变更(如出站固定 IPv4)都通过该机制向存量机器追平。
**1.6.0 重点**:三个直连模式(socks5/xhttp/REALITY)的入站监听去掉写死的
`listen: 0.0.0.0`,改为通配双栈监听(有 IPv6 收 v6 连接,无 IPv6 自动回退),
已装机器跑一次菜单 15 即迁移。菜单 15 的跳过判定同时参考迁移记录与只读探针:
即使记录显示已迁移、配置后来又出现旧残留(如手工恢复旧文件),也会重新补跑。

**1.5.0 重点**:h2 传输被 Xray 内核删除,该模式迁移到 xhttp。已装 h2 的机器跑菜单 15 后,
配置从 `config_h2.json` 转到 `config_xhttp.json`、服务从 `v2ray-h2` 换成 `xray-xhttp`
(UUID/端口/路径全部保留),客户端需重新导入新链接(链接由 `type=http` 变为 `type=xhttp`)。

## 先装代理后装宝塔

若先用本脚本装了 ws(配置在发行版 nginx),之后才安装宝塔,宝塔 Nginx 不加载
`/etc/nginx/conf.d`,ws 会失效。脚本检测到该情况会自动把配置迁移到宝塔 vhost 目录,
迁移后验证(宝塔 nginx reload 成功 + ws 服务与端口正常),验证不通过自动回退并告知原因。

## 验证过的系统

真机完整测试仅覆盖 **Debian 11/12/13** 与 **Ubuntu 18.04/20.04/22.04/24.04**
(systemd 237–257、nginx 新旧两种模板格式)。CentOS / Rocky / AlmaLinux 等 RHEL 系
**为代码级支持,未做真机验证**,详见上文 [支持系统](#支持系统)。

## 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/local/etc/v2ray/config_ws.json` / `config_socks.json` | V2Ray 各模式配置 |
| `/usr/local/etc/v2ray/config_xhttp.json` | Xray xhttp 配置 |
| `/usr/local/etc/xray/config_reality.json` | Xray REALITY 配置 |
| `/usr/local/etc/v2ray/v2ray_info.txt` | 全部节点信息(脚本保存) |
| `/usr/local/etc/v2ray/used_ports.txt` | 已分配端口记录 |
| `/root/v2ray_share_url.txt` | 全部分享链接(每次运行菜单 7 重建, 只含当前有效链接) |
| `/etc/nginx/conf.d/v2ray-ws-tls.conf` | Nginx 站点配置(仅 ws 模式) |
| `/home/wwwroot/v2ray-web/` | 伪装站点根目录 |
| `/data/v2ray.crt`、`/data/v2ray.key` | 证书与私钥(ws 与 xhttp 共用) |
| `/usr/local/bin/ssl_update.sh` | 手动续签脚本(续签后自动重启 nginx + 两个 V2Ray 服务) |

## 常见问题

- **证书申请失败**:确认域名 A 记录已指向本机、80/443 端口未封禁;然后重试菜单 8。也可把已有证书放到 `/data/v2ray.crt` 和 `/data/v2ray.key` 后重跑脚本。ws 与 xhttp 共用同一份证书;REALITY 不需要证书。
- **防火墙**:脚本自动放行 ufw / firewalld 的 80/443 及 xhttp、socks、REALITY 端口;云厂商安全组需手动放行对应端口。
- **socks5 安全**:socks 为明文协议,脚本已随机生成 8 位用户名 + 16 位密码,请勿改成弱密码;仅建议在可信网络使用。
- **REALITY 连接异常**:通常是伪装目标站不可用或被针对性封锁,可编辑 `/usr/local/etc/xray/config_reality.json` 更换 `dest`/`serverNames` 后 `systemctl restart xray-reality`(同步更新客户端 sni)。
- **性能**:建议开启 BBR(安装完成提示里有命令)。

## 免责声明

仅供学习和技术研究,请遵守所在地区法律法规。
