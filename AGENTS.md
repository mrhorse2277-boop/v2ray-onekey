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

## 3. 主打系统矩阵: 依赖类改动必须在六个系统上实测

**Debian 11/12/13 + Ubuntu 18.04/20.04/22.04/24.04 是本脚本的主打系统。**
凡是改动**系统依赖面**的提交, 必须在**全部六个系统**上按第 4 节的方法实测,
不允许只测一个系统就推。

触发条件(满足任一即必须跑全矩阵):

- 新增/修改 shell 语法、内建命令用法(bash 版本相关)
- 新增/修改 systemd unit 模板或 `systemctl` 调用
- 新增/修改对外部命令的调用(openssl / awk / sed / grep / curl / getopt 等)
- 新增/修改包管理器逻辑(apt / dnf / yum 分支)
- 改动用户/组、文件权限、SELinux、防火墙相关代码
- 升级或新增 core(v2ray/xray)的安装方式、配置模板结构
- 任何"在某个发行版上可能行为不同"的判断——拿不准就按触发算

不触发(可只跑 Debian 12 真机):纯文案、纯链接字段拼接、纯菜单排版、
仅影响本仓库文档的改动。

**违规示例**:只在 Debian 12 上跑通就推了 `Group=` 或 `openssl -tls1_3` 这类
改动——这两处都曾在非 Debian 系统上直接导致装不上/起不来。

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
- Ubuntu 容器内 systemd-resolved 起不来: disable 掉并写静态 resolv.conf

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
- 在用户 VPS 上测试后必须把改动的配置恢复原样
- 链接生成一律从实际配置文件现场生成, 不信任 INFO_FILE/URL_FILE 历史值
- 五个配置模板的 freedom outbound `domainStrategy: UseIPv4` 不可丢失
- sed -i 改配置后必须补 `fix_config_perm` 属组修正

