# 维护手册

面向后续维护者。用户视角的功能说明见 [README.md](README.md),这里只写"改代码之前需要知道的事"。

> **AI agent 必须先读 [AGENTS.md](AGENTS.md)** —— 硬性门禁:知识库(docs/kb、docs/upstream)
> 只留本地严禁推送、push 即发布、SCRIPT_VERSION 手动递增等禁令都在那里。

## 仓库与部署

- 唯一交付物是 `install.sh`(约 3250 行,单文件 self-contained,无外部依赖文件)
- GitHub 仓库:`mrhorse2277-boop/v2ray-onekey`(main 分支)
- 本机推送走本机代理(10809 已停,用 socks5h://127.0.0.1:10808;DNS 也走代理避免解析污染):
  `git -c http.proxy=socks5h://127.0.0.1:10808 -c credential.helper= -c credential.helper="manager" push`
- 用户侧一键命令从 `raw.githubusercontent.com` 拉取,推送即发布,**没有版本分支/tag 隔离**——
  所以"测试通过再 push"是硬约束

## 测试环境

- 测试 VPS:97.64.22.90,SSH 端口 39517,root + 公钥认证
- 每轮测试流程:用户重装系统 → `ssh-keygen -R "[97.64.22.90]:39517"` 清旧 host key →
  `scp -P 39517 install.sh root@97.64.22.90:/root/install.sh` → 上 VPS 跑
- Let's Encrypt 对测试域名 banwagong.ownip.net 有 7 天 5 证限流;
  测试 ws 时用临时自签证书绕过:
  `openssl req -x509 -nodes -newkey rsa:2048 -days 30 -keyout /data/v2ray.key -out /data/v2ray.crt -subj '/CN=banwagong.ownip.net'`

## 每轮测试清单

> **先判定改动类型**(AGENTS.md 第 3 节三档):
> - **A 档**: 新增了"依赖能力基线"表里没有的能力 → **六个主打系统全跑**(第 4 节)
> - **B 档**: 依赖版本升级、能力未变 → **只做能力核对并在此记录**, 不跑全矩阵
> - **C 档**: 上游移除/改变能力 → 按 A 档
>
> 下列 1-7 项是**单系统内**的检查内容, 与矩阵测试配合使用。

1. `bash -n install.sh` 本地语法检查;有条件时 shellcheck(error 级必须为零)
2. 安装四模式:reality(443)→ socks → ws(443 被占自动落独立端口)→ xhttp(独立端口)
3. 验证:REALITY 握手(`openssl s_client -connect 127.0.0.1:443 -servername <sni>`,
   Verify return code: 0)、socks5 连通(curl --proxy socks5h://... 实测 204)、
   ws 端口(`ss -lnt` IPv4+IPv6 listen 一致)、xhttp 节点用 xray 客户端实测 200
   (xhttp 只能由 Xray 核心承载,服务端 unit 是 `xray-xhttp`)
4. `systemctl is-active xray` 应为 **inactive** 且无 `config.json` 占位进程
   (官方 Xray 安装器每次都会复活它,ensure_xray/do_update_v2ray 里负责清)
5. 菜单 11/12 重置端口:检查 `used_ports.txt` 旧端口删除、新端口写入(f84a6e8 起)
6. 类型化卸载(13→1..4)+ 全部卸载(13→5),残留检查七项:
   进程(unit/`pgrep -c 'run -config'`)、`/etc/systemd/system/{v2ray,xray}*`、
   `/usr/local/etc/{v2ray,xray}` 目录、`/usr/local/bin/{v2ray,xray}`、
   nginx 配置、监听端口——应全为 0
7. 换系统回归时,先跑一遍上面全部,再针对该系统差异(包管理/systemd 版本/nginx 版本)看细节
8. **发行版覆盖现状(必须如实记录)**:
   - 1.5.0 已实测通过: **Debian 11/12/13 + Ubuntu 18.04/20.04/22.04/24.04**
   - Debian 12 是 VPS 真机全量回归(四模式/菜单/迁移)
   - 其余五个版本用 `debootstrap` + `systemd-nspawn` 跑真实发行版用户空间 + 真实
     systemd,每个都验证了: bash -n / 版本预检 / 组名探测 / OpenSSL 能力 /
     socks 安装 / 代理连通 200 / 菜单 7 / 卸载清理
   - **未覆盖**:容器共享宿主内核(内核参数、安全组、磁盘网卡驱动未测);
     REALITY/ws/xhttp 需域名证书未在容器内跑
   - 复现方法见本节末尾的 nspawn 命令
   - CentOS/Rocky/Alma/Fedora/Oracle/RHEL 为**代码级支持,未真机验证**
   - **CentOS 7 明确不支持**:bash 4.2 无 `local -n`(需 4.3+),systemd 219 无
     `AmbientCapabilities`(需 229+),`check_system` 会在预检阶段直接拒绝
   - **OpenSSL 版本坑 (1.5.0 修)**:Ubuntu 18.04 自带 1.1.0g,不支持
     `s_client -tls1_3`(报 Option unknown)与 `x509 -ext`(报 Unknown digest ext)。
     修复前 REALITY 选站会把所有候选判失败、直接装不上。现在 `openssl_has_tls13`
     自动检测并降级到 `-tls1_2` / `-text`,Debian 12 仍走严格路径。
     实测:18.04 走降级且候选站全 PASS;Debian 11(1.1.1w)/13(3.5)/Ubuntu 20.04+ 走严格路径

## 依赖能力复核记录 (B 档)

依赖版本升级但脚本用到的能力未变时, 不跑六系统全矩阵, 但必须在此记一行。
能力清单见 AGENTS.md 第 3 节的"依赖能力基线"表。

| 日期 | 依赖 | 版本变化 | 复核内容 | 结论 |
|---|---|---|---|---|
| 2026-10-23 | openssl | 1.1.0g / 1.1.1f / 1.1.1w / 3.0.2 / 3.0.13 / 3.5.7 | `-tls1_3` 与 `x509 -ext` 的分支判定 | 1.1.0g 走降级, 其余走严格, 六系统实测一致 |
| 2026-10-23 | bash | 4.4 / 5.0 / 5.1 / 5.2 | `local -n`、`${v,,}` | 全部可用 |
| 2026-10-23 | systemd | 237 / 247 / 252 | `AmbientCapabilities` | 全部可用 |

**新增依赖能力时**:先更新 AGENTS.md 的能力基线表, 再按 A 档跑六系统,
最后在此追加记录(写"已按 A 档全矩阵验证"即可)。

## 多发行版测试方法 (systemd-nspawn)

单台 Debian VPS 即可覆盖多个发行版,**不需要重装**:

```bash
apt-get install -y debootstrap systemd-container
# 引导真实发行版用户空间 (Debian 系)
debootstrap --variant=minbase --include=systemd,systemd-sysv,dbus     bullseye /tmp/ns11 http://deb.debian.org/debian/
# Ubuntu 系 (noble 若报 No such script, 先 cp jammy 脚本改名)
debootstrap --variant=minbase --include=systemd,systemd-sysv,dbus     bionic /tmp/ns_bionic http://archive.ubuntu.com/ubuntu/
# 补依赖 + 静态 DNS (systemd-resolved 在容器内常失效)
printf 'nameserver 8.8.8.8
' > /tmp/ns11/etc/resolv.conf
# 启动真实 systemd
systemd-nspawn -D /tmp/ns11 --machine=t11 --boot --quiet &
systemd-run --machine=t11 --quiet --pipe --wait /bin/bash -c 'systemctl is-system-running'
```

**踩过的坑**:
- 容器内 `/tmp` 是 53MB tmpfs,官方 core 安装脚本解压 18MB 包会 disk full;
  跑安装前 `export TMPDIR=/root/tmpwork`(磁盘目录)
- chroot 模式(非 nspawn)必须先 `mount --bind /dev`,否则 `source <(...)` 报
  `/dev/fd/63: No such file or directory`;但 bind 了 /dev 又会挡住 nspawn 启动,
  两者只能选一
- `machinectl shell` 会吞输出,用 `systemd-run --machine=X --pipe --wait` 拿结果
- Ubuntu 容器内 systemd-resolved 常起不来,直接 disable 并写静态 resolv.conf
   - `check_system` 对 RHEL 系打印醒目警告,交互模式经 `confirm_untested_distro`
     要求确认(非交互不阻塞,否则一键命令会卡住)
   - **纪律**:写文档时区分"本轮实测"与"历史记录",不要把没跑过的版本标成已验证;
     真在某版本跑通了再升 ✅,并同步 README 表格 + install.sh 头部注释 + 本节

## 已知版本敏感点(改代码前先看)

- **systemd 237–257 行为差异**:卸载必须用 `stop_service_sync`(同步等进程退出+SIGKILL 兜底),
  不能 `disable --now` 后立刻 rm unit(255 异步收尾会留孤儿进程)
- **procps-ng 老版本**:pgrep/pkill 正则不能用 `(a|b)` 分组、不能用前导 `-`,
  只用简单无分组模式
- **nginx ≥1.25.1**:http2 用独立指令,listen 行是 `listen <p> ssl;` / `listen [::]:<p>;`;
  旧版是 `listen <p> ssl http2;`。改 listen 相关 sed 必须两种格式都兼容
- **Debian 11 已 EOL**:security 源 404,测试需切 archive.debian.org(环境问题,非脚本 bug)
- **awk 默认是 mawk**(Debian/Ubuntu):IGNORECASE 赋值不报错但无效,别依赖它
- **宝塔**:nginx 二进制在 `/www/server/nginx/sbin/nginx`,vhost 在
  `/www/server/panel/vhost/nginx/`;只 reload 不 restart;先代理后宝塔的迁移在
  `migrate_ws_conf_to_btpanel`(带验证+回退)

## 架构要点

- **模式隔离**:四模式各自独立配置文件+systemd 服务,任意组合共存;
  端口冲突在分配时解决(REALITY 占 443 → ws 落独立端口;nginx 占 443 → REALITY 落独立端口)
- **xhttp 模式用 Xray 核心**:v2fly 不支持 xhttp 传输(实测 `unknown transport protocol: xhttp`),
  所以该模式的 unit 是 `xray-xhttp` + `/usr/local/bin/xray`,配置文件在
  `/usr/local/share/xray/` 找 geo 数据(`ensure_xray_geo_data` 兜底下载;
  注意 Xray-rules-dat 的资产名是 `geoip-full.dat`,没有 `geoip.dat`)
- **h2 已从 Xray 删除**(v24.12.31 起,`Transport: Remove HTTP`):任何 `"network": "h2"`
  配置在 Xray 上直接报 `The feature HTTP transport ... has been removed`;
  v2fly 仍支持 h2 但客户端全部失效。旧 h2 机器靠迁移 `migr_h2_to_xhttp` 转换
- **core 安装**:不自己下载二进制,调 v2fly/fhs-install-v2ray 与 XTLS/Xray-install 的
  install-release.sh,脚本不硬编码版本号,长期不更新也能装到最新 core。
  ensure_v2ray/ensure_xray 只判断"有没有",升级走菜单 9(无条件重跑安装脚本+重启服务)
- **INFO_FILE**(`/usr/local/etc/v2ray/v2ray_info.txt`):`### <section>` 段落 + key=value,
  仅存节点参数(端口/UUID/凭据等)供菜单内部快速读取;**share_url 已不从 INFO_FILE 生成**——
  菜单 7 与 10/11/12 一律从实际配置现场生成(b8e5b6b),INFO_FILE 各段落仍由
  sync_info_block 在改端口/UUID/换站后同步,卸载时 sed 删除的段落名必须与
  append_info 写入的一致(8b0f105 修过的失配坑)
- **非交互兼容**:所有交互点必须 `[[ -t 0 ]]` 判断,CLI 子命令/管道下跳过询问走默认值
  (pick_port 随机、REALITY 选延迟最低站)。破坏了这条,一键命令就不能用了
- **取消路径**:pick_port 返回 1 = 用户 b 取消;安装场景 return 1 中止,
  重置场景删 .bak 后 return 1。注意 `do_reset_node` 的 b 分支是**递归调用**,
  局部状态必须 local(f84a6e8 修过标志泄漏)
- **链接来源铁律**:菜单 7 与菜单 10/11/12 的新链接一律**从实际配置文件现场生成**
  (REALITY 的 pbk 由私钥 `xray x25519 -i` 推导优先,URL_FILE 历史值只作兜底),
  不信任 INFO_FILE/URL_FILE 里的 share_url(历史记录可能陈旧,b8e5b6b 重写过菜单 7);
  导出文件每次重建不追加
- **freedom 出站 UseIPv4**:五个配置模板的 freedom outbound 都带
  `settings.domainStrategy=UseIPv4`(60f59ca,用户 VPS IPv6 回程不稳),
  改配置模板时别丢;手工给存量机器补这个参数用 sed 定位
  `"protocol": "freedom"` 插入 settings 块
- **脚本自更新(菜单 14)**:`SCRIPT_VERSION` 是版本对比的唯一依据,
  **每次改完脚本必须手动递增**(不一致才触发覆盖,相同则提示已是最新);
  自更新带合法性(grep 标识)+语法(bash -n)双校验和备份回滚
- **配置迁移机制(菜单 15)**:改任何配置模板必须同步在 `MIGRATIONS` 数组追加
  `"版本|函数|描述"` 并实现幂等迁移函数(先检测字段已存在则跳过),存量机器跑一次
  菜单 15 就追平;已应用记录在 `MIGRATIONS_STATE`
  (`/usr/local/etc/v2ray/migrations_done.txt`,格式 `版本|函数名`),失败自动回滚不记 state。
  **注意跨文件迁移的特殊性**:执行器默认要求目标配置已存在(否则 continue),
  但 h2→xhttp 的源是 `config_h2.json`、目标是尚不存在的 `config_xhttp.json`,
  所以执行器对 `migr_h2_to_xhttp` 特判放行源文件,且目标不存在时不备份(回滚靠删新文件)。
  迁移函数内部还要自己判 `[[ "${conf}" == "${XHTTP_CONF}" ]]`,否则会被执行器
  对四种配置各调一次、把 h2 配置写到别的模式上
- **推送前完整可用性测试**:每次维护/更新脚本,推送前必须在测试 VPS 上实测
  服务 active + REALITY 握手 Verify=0 + socks5 curl 204 + 菜单 7 链接生成
  (AGENTS.md 门禁硬规则,静态检查不算测过)。
  **xhttp 实测方法**:Xray 26.x 删了 `allowInsecure`,客户端配置要用
  `pinnedPeerCertSha256`(证书 DER 的 sha256 **hex** 字符串,不是 base64),
  否则连测试都跑不起来
- **降权与权限**:服务以 nobody 运行,配置文件必须 `root:<组> 640`
  (`fix_config_perm`);任何 sed -i 改配置的路径之后都要补一次属组修正,
  否则服务读不到配置起不来。
  **组名跨发行版不同**:Debian/Ubuntu 是 `nogroup`,RHEL/CentOS/Rocky/Alma/Fedora
  是 `nobody`(没有 nogroup)。systemd 的 `Group=` 指向不存在的组会让服务**直接启动失败**
  (实测 `Failed with result 'exit-code'`),所以四个 unit 模板都不能硬编码,
  统一用 `detect_nobody_group` 探测(`NOBODY_GROUP`,优先 nogroup→nobody→root 兜底)
- **busybox sed**:替换串里的 `
` 在 busybox sed(Alpine 等精简系统)上会写成字面
  `
` 而不是换行。需要多行插入时用 awk `print` 而不是 sed,awk 在各实现上一致
  (`migr_h2_to_xhttp` 补 xhttpSettings 就是这样改的)

## 本地资料库 (docs/kb + docs/upstream, 仅本地)

客户端(v2rayN/v2rayNG)分享链接解析与配置生成的源码资料库,纯本地,不入 git
(排除靠 `.git/info/exclude`,勿删)。结构/保鲜命令/去旧规则见
[docs/kb/UPDATE.md](docs/kb/UPDATE.md),提炼笔记见 [docs/kb/SPEC.md](docs/kb/SPEC.md)。
改 install.sh 链接生成前先 `bash docs/kb/update_kb.sh --check` 确认快照新旧;
收录文件与上游冲突时 `--sync` 同步;上游删除/改名报 EXPIRED 由人重定位。

## 常用调试命令

```bash
# 服务与端口
systemctl is-active v2ray-ws v2ray-socks xray-reality xray-xhttp; ss -lnt
# 占位进程检查 (官方安装器残留)
pgrep -af 'xray run -config /usr/local/etc/xray/config.json'
# REALITY 握手
echo | openssl s_client -connect 127.0.0.1:443 -servername <sni> 2>/dev/null | grep -E 'subject=|Verify'
# socks5 连通 (user/pass/port 从 v2ray_info.txt 读)
curl -s -o /dev/null -w '%{http_code}' --proxy socks5h://user:pass@127.0.0.1:<port> https://www.google.com/generate_204
# 日志
journalctl -u v2ray-socks -u xray-reality --no-pager -n 20
```

## 测试 harness 教训

- `ssh -t` / 管道喂交互脚本不可靠:输入会被吞或落错分支。单元级验证用
  `script -qec 'bash xxx.sh' /dev/null` 模拟 tty;端到端验证用非交互子命令
- 交互菜单跑在伪终端里**不会自己退出**(回到菜单等待),SSH 会话会挂起——
  喂输入序列的末尾必须带 `0`(退出菜单),否则表现为"反复超时"
- `pgrep -c` 会把测试命令自身算进去;`grep -c` 对 `not-found` 这类输出会误报,
  残留检查用 `pgrep -c ... || true` + 明确期望值核对
