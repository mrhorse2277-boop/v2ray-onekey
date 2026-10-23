# Agent 门禁 (硬性禁令)

任何 AI agent / 自动化在本仓库工作前必须遵守。违反任何一条即为错误操作,
即使任务指令没有明确提及。

## 1. 知识库只留本地, 严禁推送

`docs/kb/`(收录快照+提炼笔记)与 `docs/upstream/`(上游完整克隆)是**本地资料库**,
绝对不允许进入 git 历史:

- **禁止** `git add docs/kb docs/upstream`(包括 `git add -A` / `git add .` 的隐式收录)
- **禁止**修改 `.gitignore` 等任何方式把它们改为跟踪
- 排除机制在 `.git/info/exclude`(仅本地生效, 不随仓库分发)——**不要删除或注释其中
  的 `docs/kb/`、`docs/upstream/` 两行**
- 提交前必须核对 `git status --short` 与 `git diff --cached --name-only`:
  出现 `docs/kb/` 或 `docs/upstream/` 任何路径即中止提交并移除
- 知识库的维护(同步/去旧)用 `bash docs/kb/update_kb.sh`, 只在本地执行, 不涉及 git

## 2. push 即发布

GitHub 仓库 `mrhorse2277-boop/v2ray-onekey` 的 main 分支就是用户侧一键命令的
raw 拉取源,**没有版本分支/tag 隔离**:

- install.sh 的任何改动必须先在测试 VPS 上验证通过才允许 push(硬约束)
- 纯文档(README/MAINTENANCE/AGENTS)改动可以直接 push
- 推送命令见 MAINTENANCE.md(本机 socks5h 代理 + 显式 credential.helper)

## 3. 主打系统矩阵: 按"依赖能力"而非"依赖版本"决定测多少

**Debian 11/12/13 + Ubuntu 18.04/20.04/22.04/24.04 是本脚本的主打系统。**

判定原则:**触发重测的是"脚本用到了以前没验证过的依赖能力", 不是"依赖升级了"。**
版本号变化本身不构成重测理由 —— 只要脚本用到的那几项能力还在、语义没变,
行为就不会变, 重跑只是重复验证同一个结论。

### 三档判定

| 档 | 情况 | 举例 | 要求 |
|---|---|---|---|
| **A** | 新增依赖能力 | 首次用 `openssl s_client -ech`、`declare -A`、`systemd StateDirectory=`、新增 `jq` 依赖 | **六个系统全跑**(第 4 节) |
| **B** | 同依赖版本升级, 能力不变 | openssl 3.5→3.6、bash 5.2→5.3、systemd 252→253 | **能力核对 + 记录**, 不跑全矩阵 |
| **C** | 上游移除或改变能力 | Xray 删 h2 传输、openssl 删某参数、systemd 改 unit 语义 | 按 A 处理(改脚本 + 六系统全跑) |

**B 档的"能力核对"具体做什么**(几分钟即可, 不是跑全矩阵):

1. 读上游 release notes 的 breaking changes / removed / deprecated 段落
2. 在任意一台机器上把脚本用到的那条命令跑一遍, 确认输出格式与行为一致
3. 在 MAINTENANCE 的"依赖能力基线"表下记一行复核记录(版本 + 日期 + 结论)

### 依赖能力基线(脚本实际依赖的能力, 非版本号)

| 依赖 | 脚本用到的能力 | 最低要求 | 已验证范围 |
|---|---|---|---|
| bash | `local -n`(nameref)、`${v,,}` | **4.3+** | 4.4 / 5.0 / 5.1 / 5.2 |
| systemd | `AmbientCapabilities`、`Restart=on-failure`、`LimitNOFILE` | **229+** | 237 / 247 / 252 |
| openssl | `s_client -tls1_3`、`x509 -ext`(均 1.1.1+); 降级路径用 `-tls1_2`、`-text` | 1.1.0+ | 1.1.0g / 1.1.1f / 1.1.1w / 3.0.2 / 3.0.13 / 3.5.7 |
| awk / sed / grep / curl / ss / getopt | 仅基础用法(无 GNU 扩展依赖) | — | 全部已验证 |
| 包管理器 | apt-get / dnf / yum 三分支 | — | apt 全测; dnf/yum 代码级 |
| 组名 | `nogroup`(Debian系) / `nobody`(RHEL系) | — | 由 `detect_nobody_group` 运行时探测 |

**改动新增了上表没有的能力 → 归 A 档。** 新增依赖后必须同时更新此表。

### 其他必须跑全矩阵的情形

- 新增/修改 systemd unit 模板、`systemctl` 调用方式
- 新增/修改包管理器分支、用户组/权限/SELinux/防火墙逻辑
- 升级或改变 core(v2ray/xray)的安装方式、配置模板结构
- 改动迁移机制(`MIGRATIONS`)本身
- 改动启动依赖检测(`ensure_runtime_deps` / `install_runtime_deps`)
- 拿不准时按 A 档算

### 新增依赖的强制流程(缺一不可)

脚本在**主菜单弹出前**做依赖检测与补齐(`main()` → `ensure_runtime_deps`)。
以后任何新增依赖都必须走完下面四步, 否则等于给用户埋一个静默失败:

1. **加入清单**:按性质放进 `install.sh` 顶部的 `RUNTIME_DEPS`(任何功能都可能用到,
   缺失会降级或出错)或 `OPTIONAL_DEPS`(缺失仅功能降级、不自动安装)。
   `BASE_DEPS` 只放"没有就无法运行"的核心命令(coreutils/文本工具), 不要往里塞新东西。
2. **同步能力基线**:在本文第 3 节"依赖能力基线"表里补一行(依赖名 + 用到的能力 +
   最低版本 + 已验证范围), 否则后人无法判断版本升级是否需要重测。
3. **跑六系统全矩阵**(第 4 节), 且必须额外验证**新依赖缺失时的启动路径**:
   在最小化环境里确认"检测到缺失 → 安装 → 复核 → 继续"这条链路走得通。
4. **在 MAINTENANCE 的"依赖能力复核记录"里记一行**。

**为什么必须这么严**:菜单 7/10/11/12/15 这些功能不经过 `do_install`,
如果依赖只装在安装路径上, 精简系统上跑菜单 7 会因缺 `curl`/`openssl` 而
**静默产出错误链接**(相关调用大多带 `2>/dev/null`), 用户看到的链接格式正确但内容是错的。
2026-10 就踩过这个坑。

### 依赖安装的健壮性要求

`install_runtime_deps` 必须覆盖这些最差情况, 修改时不许退化:

| 最差情况 | 处理方式 |
|---|---|
| apt 索引损坏/不同步 | `update` 后仍失败 → `--fix-missing` 重试 |
| 某个包源里不可用 | 逐个包安装, 不让一个包拖垮整批 |
| 软件源不可达/被墙 | 记录日志 + 明确报错 + 给出手动命令, **不许假装成功** |
| dpkg 锁被占用 | 等待释放(最多 60s), 超时明确提示而不是干等 |
| 命令挂死(网络黑洞) | 所有包管理调用套 `timeout` |
| 磁盘不足 | 安装前检查, 不足直接说明 |
| dpkg 半装状态 | `dpkg --configure -a` 修复后重试 |

安装结果**以 `command -v` 复核为准**, 不信包管理器的返回码。
失败后允许继续进菜单(用户至少要能看节点/卸载), 但必须明确告知哪些功能受影响。

### 不需要跑全矩阵的情形

- 纯文案、纯链接字段拼接、纯菜单排版、仅文档改动
- 依赖版本升级且能力未变(B 档: 只做能力核对)
- 在 Debian 12 真机上已能完整覆盖的逻辑修正(如链接生成 bug)
- 新增/修改迁移**探针**(`<fn>_check`)或菜单头部状态显示: 纯只读检测, 不碰配置、
  不碰服务、不碰依赖。按单台机器做第 5 节的自检即可(四种状态条数 + 菜单 15 后转 🟢),
  不需要六系统全跑; 但**新增迁移函数本身**属于改配置模板, 按第 5 节登记, 且要补跑
  受影响模式的安装/升级链路验证。

### 新增系统进矩阵(与依赖升级是两回事)

若某系统首次进入支持范围(如 Debian 14 发布), 对该系统跑**一轮完整测试**(第 4 节),
不需要因此重跑其他已测系统 —— 它们的行为没被改动影响。
若某系统版本被淘汰(EOL 且用户基数低), 从矩阵移除时要在 README 与本节同步说明。

**违规示例**:只在 Debian 12 上跑通就推了 `Group=` 或 `openssl -tls1_3` 这类
**新增能力**改动——这两处都曾在非 Debian 系统上直接导致装不上/起不来。
反过来, 因为 openssl 小版本升级就把六个系统重跑一遍, 属于过紧, 也不必要。

## 4. 六个系统的实测方法(必须按此复现)

单台 Debian VPS 即可覆盖全部六个系统, **不需要重装**。用 debootstrap 引导真实
发行版用户空间 + systemd-nspawn 启动真实 systemd(不是模拟、不是阉割容器)。

```bash
# 宿主机准备
apt-get install -y debootstrap systemd-container

# 1) 引导 (每个系统约 200MB)
debootstrap --variant=minbase --include=systemd,systemd-sysv,dbus,curl,ca-certificates \
    bullseye /tmp/ns11 http://deb.debian.org/debian/          # Debian 11
debootstrap ... bookworm /tmp/ns12 http://deb.debian.org/debian/   # Debian 12
debootstrap ... trixie  /tmp/ns13 http://deb.debian.org/debian/    # Debian 13
debootstrap ... bionic  /tmp/ns1804 http://archive.ubuntu.com/ubuntu/  # Ubuntu 18.04
debootstrap ... focal   /tmp/ns2004 http://archive.ubuntu.com/ubuntu/  # Ubuntu 20.04
debootstrap ... jammy   /tmp/ns2204 http://archive.ubuntu.com/ubuntu/  # Ubuntu 22.04
debootstrap ... noble   /tmp/ns2404 http://archive.ubuntu.com/ubuntu/  # Ubuntu 24.04

# 2) 补依赖 + 静态 DNS (容器内 systemd-resolved 常失效)
chroot /tmp/nsXX /bin/bash -c "apt-get update -qq; apt-get install -y openssl iproute2 procps wget cron"
printf 'nameserver 8.8.8.8\n' > /tmp/nsXX/etc/resolv.conf
cp install.sh /tmp/nsXX/root/

# 3) 启动真实 systemd
systemd-nspawn -D /tmp/nsXX --machine=tXX --boot --quiet &
systemd-run --machine=tXX --quiet --pipe --wait /bin/sh -c 'systemctl is-system-running'
```

每个系统必须逐项验证(七项, 缺一不可):

1. `bash -n install.sh` 语法通过
2. 版本预检输出正确(实测系统显示"已实测通过", 未测系统显示"未在实测矩阵内")
3. 组名探测正确(`nogroup` / `nobody` 按发行版)
4. OpenSSL 能力检测走对分支(1.1.0 走降级, 1.1.1+ 走严格)
5. socks5 真实安装: 服务 `active`、`User=nobody`、`Group=` 为有效组、
   端口监听、配置 `root:<组> 640`
6. 代理实测连通: `curl --proxy socks5h://... -w '%{http_code}'` 返回 **200**
7. 菜单 7 链接生成正常 + 卸载后服务 inactive、配置文件删除干净

**踩过的坑(照做可避免)**:

- 容器 `/tmp` 是 53MB tmpfs, core 安装脚本解压 18MB 包会 disk full →
  跑安装前 `export TMPDIR=/root/tmpwork`(磁盘目录)
- chroot 模式(非 nspawn)不挂 `/dev` 时 `source <(...)` 报
  `/dev/fd/63: No such file or directory`; 但 bind 了 `/dev` 又会挡住 nspawn 启动,
  两种模式互斥, 别混用
- `machinectl shell` 会吞输出, 必须用 `systemd-run --machine=X --pipe --wait`
- 宿主机 debootstrap 1.0.128 不认识 `noble`(实测 `E: No such script`):
  先 `cp /usr/share/debootstrap/scripts/jammy /usr/share/debootstrap/scripts/noble`
  再 `sed -i 's/jammy/noble/g'` 改名; Ubuntu 系结构相同, 引导正常
- Ubuntu 容器内 systemd-resolved 起不来: disable 掉并写静态 resolv.conf。
  **注意**: 若在 nspawn 启动后才改 resolv.conf, resolved 可能再次覆盖, 导致
  `Temporary failure resolving` 让依赖安装假失败(2026-10 实测踩过)。做法:
  启动容器后立即 `systemctl disable --now systemd-resolved` 再写文件,
  或写入后 `chattr +i` 锁定(测试完记得 `chattr -i` 再删目录)

**测试后必须清理**:`machinectl terminate` 所有机器、删掉 `/tmp/ns_*`、
移除临时加的 debootstrap 脚本, 确认宿主机磁盘与服务恢复原状。

**未覆盖的部分要在文档里说清**:容器共享宿主内核, 不覆盖内核参数、云厂商安全组、
磁盘/网卡驱动; REALITY/ws/xhttp 需域名证书, 在容器内不跑(由 Debian 12 真机覆盖)。
不许把"容器里跑通"说成"真机验证"。

## 5. 其他既有硬规则 (详见 MAINTENANCE.md)

- **每次维护/更新脚本, 推送前必须完整测试已装代理的可用性**:至少覆盖
  服务 active、REALITY 握手 (Verify return code: 0)、socks5 实测连通
  (curl --proxy 204)、菜单 7 链接生成正确——只跑 bash -n / 静态检查不算测过
- 改 install.sh 必须手动递增 `SCRIPT_VERSION`(菜单 14 版本对比唯一依据)
- **改任何配置模板必须同步登记迁移补丁**(菜单 15 机制):在 MIGRATIONS 数组
  追加 "版本|函数|描述" 并实现幂等迁移函数, 保证已安装机器跑一次菜单 15 就能追平
- **每条迁移必须同时写 `<迁移函数名>_check` 只读探针**, 返回 0 表示"本机还有待做部分"。
  菜单头部的"🔴 N 条待升级"就靠它判定, 而**不读 `migrations_done.txt`**——
  全新安装从未写过 state 文件, 只看 state 会把已符合新模板的机器误报成"待升级"。
  漏写探针不会报错(会退回 state 判定), 但会丢掉"全新安装免误报"能力, 属于隐性退化,
  所以视为违规:
  ```bash
  migr_useipv4_check() {            # 对应 migr_useipv4
      local conf
      for conf in "${REALITY_CONF}" "${WS_CONF}" "${XHTTP_CONF}" "${SOCKS_CONF}"; do
          [[ -f "${conf}" ]] || continue
          grep -q '"domainStrategy"' "${conf}" || return 0   # 缺字段 = 待升级
      done
      return 1
  }
  ```
  探针必须**只读**、幂等、在"已迁移"状态下返回 1、在"未迁移/半迁移"状态下返回 0
  (半迁移也要返回 0, 让用户跑菜单 15 收尾)。新增探针后要在
  "未装节点 / 全新安装 / 存量缺字段 / 旧残留" 四种状态下各验一次条数,
  并确认跑完菜单 15 后自动回到 🟢。
- 在用户 VPS 上测试后必须把改动的配置恢复原样
- 链接生成一律从实际配置文件现场生成, 不信任 INFO_FILE/URL_FILE 历史值
- 五个配置模板的 freedom outbound `domainStrategy: UseIPv4` 不可丢失
- sed -i 改配置后必须补 `fix_config_perm` 属组修正

