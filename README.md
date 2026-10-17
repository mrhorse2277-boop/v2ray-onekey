# V2Ray/Xray 多模式一键脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

参考 [wulabing/V2Ray_ws-tls_bash_onekey](https://github.com/wulabing/V2Ray_ws-tls_bash_onekey) 的架构重写,
支持 **ws+tls / h2+tls / socks5 / vless+REALITY 四种模式同时安装、互不冲突**,分享链接适配最新版
[v2rayN](https://github.com/2dust/v2rayN) / [v2rayNG](https://github.com/2dust/v2rayNG) 正式版。

## 四种模式与共存方式

| 模式 | 端口 | TLS/伪装 | 组件 | 抗封锁 |
|---|---|---|---|---|
| vmess/vless + ws + tls | 443 | Nginx TLS 终结 + 静态伪装站 | Nginx + acme.sh 证书 | 中 |
| vmess/vless + h2 + tls | 随机独立端口 | V2Ray 直接 TLS | 不依赖 Nginx | 中 |
| socks5 (带认证) | 随机独立端口 | 明文 | V2Ray socks 入站 | 无 |
| **vless + REALITY** | 443(空闲时)/随机 | Xray REALITY,借用真实大站证书 | Xray core | **强(推荐)** |

四种模式各自使用独立的:

- 配置文件:`config_ws.json` / `config_h2.json` / `config_socks.json` / `config_reality.json`
- systemd 服务:`v2ray-ws` / `v2ray-h2` / `v2ray-socks` / `xray-reality`
- 核心:V2Ray (ws/h2/socks) + Xray (REALITY),分别用官方脚本安装
- 端口:安装时自动分配并查重(`used_ports.txt` 记录),任意组合互不占用

> 说明:原项目 h2 模式是 V2Ray 直接占 443、Nginx 退出,因此原版 h2 与 ws 天然互斥;
> 本脚本把 h2 改为独立端口直连,才能与 ws(443)共存。REALITY 在 443 空闲时用 443,
> 已被 ws 占用时自动落到独立端口,同样可共存。

## 支持系统

Debian 10+ / Ubuntu 18.04+ / CentOS 7+/Rocky/AlmaLinux,推荐 Debian 11+ 或 Ubuntu 20.04+。
(CentOS 7 已 EOL,可能需先切换 vault 源;CentOS 8 已停止维护,建议 Rocky/Alma)

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

准备:境外 VPS。ws 与 h2 模式需要域名(已解析 A 记录);socks5 和 REALITY **不需要域名和证书**。

```bash
# 一键下载并进入交互菜单 (将 mrhorse2277-boop/v2ray-onekey 替换为实际仓库路径)
wget -N --no-check-certificate -q -O install.sh "https://raw.githubusercontent.com/mrhorse2277-boop/v2ray-onekey/main/install.sh" && chmod +x install.sh && bash install.sh
```

# 非交互
bash install.sh ws vmess     # vmess + ws + tls (Nginx, 443)bash install.sh ws vless     # vless + ws + tls
bash install.sh h2 vmess     # vmess + h2 + tls (独立端口)
bash install.sh h2 vless     # vless + h2 + tls
bash install.sh socks        # socks5 (随机用户名/密码, 独立端口)
bash install.sh reality      # vless + REALITY (抗封锁首选, 免域名/证书)
bash install.sh info         # 查看全部已安装节点并导出链接
bash install.sh uninstall    # 卸载(可选单模式或全部)
```

重复执行不同的安装命令即可同时安装多种模式,例如:

```bash
bash install.sh reality && bash install.sh ws vless && bash install.sh socks
```

安装完成后每种模式都会输出:完整节点参数、**分享链接**(追加保存到 `/root/v2ray_share_url.txt`)、**终端二维码**。

### REALITY 模式说明

- 自动生成 x25519 密钥对与 shortId,无需任何人工输入
- 内置多个伪装目标站(tesla/microsoft/samsung/nvidia 等),安装时逐一用 TLS 1.3 + H2 探测校验,不可用自动换下一个
- 客户端流控为 `xtls-rprx-vision`,指纹模拟 chrome
- 443 端口空闲时直接监听 443(伪装效果最佳);被占用时自动换独立端口

### 客户端导入

- **v2rayN(Windows)**:复制分享链接 → 剪贴板批量导入;或「服务器 → 扫描屏幕上的二维码」
- **v2rayNG(Android)**:「+」→ 从剪贴板导入 / 扫描二维码

链接字段与最新版客户端对齐(依据 v2rayN 源码解析逻辑):

- vmess:v2 JSON,`aid=0` 走 AEAD,含 `scy` / `sni` / `fp` 字段;h2 模式 `net=h2`、`port` 为实际端口
- vless:标准 URI,`encryption=none`,`path` URL 编码,含 `sni` / `fp`;h2 模式 `type=h2`
- REALITY:`vless://...?type=tcp&security=reality&pbk=公钥&sid=shortId&sni=伪装域名&fp=chrome&flow=xtls-rprx-vision&encryption=none`
- socks:`socks://base64(user:pass)@IP:端口#备注`(v2rayN 新格式,明文旧格式也兼容)

## 菜单功能

| 选项 | 功能 |
|---|---|
| 1–2 | 安装 vmess/vless + ws + tls |
| 3–4 | 安装 vmess/vless + h2 + tls |
| 5 | 安装 socks5 |
| 6 | 安装 vless + REALITY |
| 7 | 查看全部已安装节点 / 导出全部分享链接 |
| 8 | 手动续签 / 重新申请证书(ws/h2 共用) |
| 9 | 更新 V2Ray / Xray core(全部服务一并重启) |
| 10 | 卸载(单模式或全部) |

## 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/local/etc/v2ray/config_ws.json` / `config_h2.json` / `config_socks.json` | V2Ray 各模式配置 |
| `/usr/local/etc/xray/config_reality.json` | Xray REALITY 配置 |
| `/usr/local/etc/v2ray/v2ray_info.txt` | 全部节点信息(脚本保存) |
| `/usr/local/etc/v2ray/used_ports.txt` | 已分配端口记录 |
| `/root/v2ray_share_url.txt` | 全部分享链接(追加式) |
| `/etc/nginx/conf.d/v2ray-ws-tls.conf` | Nginx 站点配置(仅 ws 模式) |
| `/home/wwwroot/v2ray-web/` | 伪装站点根目录 |
| `/data/v2ray.crt`、`/data/v2ray.key` | 证书与私钥(ws 与 h2 共用) |
| `/usr/local/bin/ssl_update.sh` | 手动续签脚本(续签后自动重启 nginx + 两个 V2Ray 服务) |

## 常见问题

- **证书申请失败**:确认域名 A 记录已指向本机、80/443 端口未封禁;然后重试菜单 8。也可把已有证书放到 `/data/v2ray.crt` 和 `/data/v2ray.key` 后重跑脚本。ws 与 h2 共用同一份证书;REALITY 不需要证书。
- **防火墙**:脚本自动放行 ufw / firewalld 的 80/443 及 h2、socks、REALITY 端口;云厂商安全组需手动放行对应端口。
- **socks5 安全**:socks 为明文协议,脚本已随机生成 8 位用户名 + 16 位密码,请勿改成弱密码;仅建议在可信网络使用。
- **REALITY 连接异常**:通常是伪装目标站不可用或被针对性封锁,可编辑 `/usr/local/etc/xray/config_reality.json` 更换 `dest`/`serverNames` 后 `systemctl restart xray-reality`(同步更新客户端 sni)。
- **性能**:建议开启 BBR(安装完成提示里有命令)。

## 免责声明

仅供学习和技术研究,请遵守所在地区法律法规。
