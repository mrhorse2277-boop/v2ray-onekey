#!/usr/bin/env bash
#
# v2ray-ws-tls-onekey —— V2Ray 多模式一键脚本
#
# 可同时安装、互不冲突:
#   1. vmess/vless + ws + tls + Nginx (443 端口, Nginx TLS 终结 + 伪装站)
#   2. vmess/vless + xhttp + tls    (独立端口, Xray 直接监听 TLS, 不依赖 Nginx)
#   3. socks5                      (V2Ray socks 入站, 独立端口, 带用户名密码)
#   4. vless + REALITY             (Xray core, 抗封锁首选, 无需域名/证书)
#
# 每种模式独立 systemd 服务 (v2ray-ws / xray-xhttp / v2ray-socks / xray-reality),
# 配置文件分离, 可任意组合安装、单独卸载, 端口互不占用。
#
# 分享链接适配最新版 v2rayN / v2rayNG。
#
# 支持系统:
#   ✅ 已实测通过 (1.5.0): Debian 11/12/13, Ubuntu 18.04/20.04/22.04/24.04
#      (Debian 12 为真机全量回归; 其余为 debootstrap + systemd-nspawn 真实发行版
#       用户空间 + 真实 systemd 跑通 socks 安装/连通/菜单/卸载全流程)
#   ⚠️ 代码级支持, 未真机验证: CentOS 8, Rocky/AlmaLinux 8/9, Fedora,
#      Oracle Linux, RHEL —— 与 Debian 系存在 systemd 版本、nobody 组名、
#      SELinux、firewalld 等差异, 安装时会打印警告并要求确认。
#   ❌ 不支持: CentOS 7 (bash 4.2 无 local -n, systemd 219 无 AmbientCapabilities)
#   推荐直接用 Debian 12 或 Ubuntu 22.04/24.04。
#
# 用法:
#   bash install.sh              交互式菜单
#   bash install.sh ws vmess     非交互安装 vmess+ws+tls
#   bash install.sh ws vless     非交互安装 vless+ws+tls
#   bash install.sh xhttp vmess  非交互安装 vmess+xhttp+tls (旧参数 h2 仍接受)
#   bash install.sh xhttp vless  非交互安装 vless+xhttp+tls (旧参数 h2 仍接受)
#   bash install.sh socks        非交互安装 socks5
#   bash install.sh reality      非交互安装 vless+REALITY
#   bash install.sh info         查看全部已安装节点
#   bash install.sh uninstall    交互卸载
#   交互菜单 14 = 更新脚本自身 (从 GitHub 下载最新版覆盖本地脚本)
#

export LC_ALL=C

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

V2RAY_CONF_DIR="/usr/local/etc/v2ray"
V2RAY_INSTALL_SCRIPT="https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh"

# --- 脚本自更新 (菜单 14) ---
SCRIPT_VERSION="1.5.1"
SELF_UPDATE_URL="https://raw.githubusercontent.com/mrhorse2277-boop/v2ray-onekey/main/install.sh"

CERT_DIR="/data"
CRT_FILE="${CERT_DIR}/v2ray.crt"
KEY_FILE="${CERT_DIR}/v2ray.key"
SSL_UPDATE_SH="/usr/local/bin/ssl_update.sh"

# --- ws + tls (Nginx) 模式 ---
WS_NGINX_CONF="/etc/nginx/conf.d/v2ray-ws-tls.conf"
WS_WWW_ROOT="/home/wwwroot/v2ray-web"
WS_CONF="${V2RAY_CONF_DIR}/config_ws.json"
WS_SERVICE="v2ray-ws"

# --- Nginx 环境探测结果 (install_dependencies / detect_nginx_env 填充) ---
NGINX_ENV="none"        # btpanel | distro | none
NGINX_BIN=""            # 实际使用的 nginx 二进制
NGINX_VHOST_DIR=""      # 站点配置目录
NGINX_RELOAD_CMD=""     # 平滑重载命令
BT_PANEL_DIR="/www/server/panel"
BT_NGINX_VHOST_DIR="/www/server/panel/vhost/nginx"

# --- xhttp + tls 模式 (Xray 直接 TLS) ---
# 原 h2 模式: Xray 自 v24.12.31 起删除 HTTP(h2) 传输 (改为 XHTTP stream-one H2/H3),
# v2rayN 的 Networks 白名单也不再含 h2/http, v2rayNG 内置内核同步删除。
# 因此本模式改用 xhttp 传输, 并改用 Xray 核心 (v2fly 不支持 xhttp)。
# 旧变量名 H2_* 保留为兼容别名, 见文件末尾的迁移说明。
XHTTP_CONF="${V2RAY_CONF_DIR}/config_xhttp.json"
XHTTP_SERVICE="xray-xhttp"
# 兼容旧安装 (v2ray-h2 / config_h2.json), 迁移与卸载时需要识别
LEGACY_H2_CONF="${V2RAY_CONF_DIR}/config_h2.json"
LEGACY_H2_SERVICE="v2ray-h2"

# --- socks5 模式 ---
SOCKS_CONF="${V2RAY_CONF_DIR}/config_socks.json"
SOCKS_SERVICE="v2ray-socks"

# --- REALITY 模式 (Xray core) ---
XRAY_CONF_DIR="/usr/local/etc/xray"
REALITY_CONF="${XRAY_CONF_DIR}/config_reality.json"
REALITY_SERVICE="xray-reality"
XRAY_INSTALL_SCRIPT="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

# 公共信息文件
INFO_FILE="${V2RAY_CONF_DIR}/v2ray_info.txt"
URL_FILE="/root/v2ray_share_url.txt"

# DOMAIN 支持环境变量预设 (非交互安装), 交互模式下仍会提示输入
DOMAIN="${DOMAIN:-}"
MODE=""                 # ws | xhttp | socks | reality
PROTOCOL=""             # vmess | vless (socks/reality 模式下为空/固定)
UUID=""
INTERNAL_PORT=""
XHTTP_PORT=""
WS_PATH=""
SOCKS_PORT=""
SOCKS_USER=""
SOCKS_PASS=""
WS_PORT=""
REALITY_PORT=""
# REALITY_DEST 允许环境变量预设 (REALITY_DEST="域名:端口" bash install.sh reality),
# 因此这里不能无条件清空, 用 :- 兜底
REALITY_DEST="${REALITY_DEST:-}"
REALITY_SNI=""
REALITY_PUBKEY=""
REALITY_SID=""
CLIENT_REMARK=""
SHARE_URL=""
PUBLIC_IP=""

log_info()    { echo -e "${GREEN}[信息]${PLAIN} $*"; }
log_warn()    { echo -e "${YELLOW}[警告]${PLAIN} $*"; }
log_error()   { echo -e "${RED}[错误]${PLAIN} $*"; }
log_confirm() { echo -e "${BLUE}[提示]${PLAIN} $*"; }

# --- 依赖清单 (启动检测与安装共用; 新增依赖必须同时加入此处与 AGENTS.md 门禁) ---
# RUNTIME_DEPS: 脚本任何功能都可能用到, 缺失则降级或出错 (菜单 7/10/11/12/15 也要用)
#   curl=公网IP与下载, openssl=证书/base64/TLS探测, ss=端口查重,
#   timeout/shuf=超时与随机端口, od/base64=shortId与socks编码
RUNTIME_DEPS="curl wget openssl ss timeout shuf od base64"
# BASE_DEPS: 纯 shell 逻辑必需 (coreutils/文本工具), 缺失直接无法运行
BASE_DEPS="awk sed grep cut tr head tail sort uniq cat mkdir rm mv cp chmod chgrp basename dirname readlink mktemp date find touch printf"
# OPTIONAL_DEPS: 缺失仅功能降级, 不自动安装 (qrencode=二维码, socat=证书备用)
OPTIONAL_DEPS="qrencode socat"
# 启动依赖检查是否已执行过 (避免每次回菜单重复 apt-get)
DEPS_CHECKED=0

gen_random() { tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$1"; }

gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        echo "$(gen_random 8)-$(gen_random 4)-4$(gen_random 3)-a$(gen_random 3)-$(gen_random 12)"
    fi
}

# 生成 REALITY x25519 密钥对, 输出 "私钥 公钥"
# 兼容不同版本 xray 输出: "Private key: xxx"/"PrivateKey: xxx"; 公钥行可能是 "Public key:" 或 "Password (PublicKey):"
gen_x25519() {
    local xray_bin
    xray_bin="$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)"
    [[ -x "${xray_bin}" ]] || return 1
    local out
    out="$("${xray_bin}" x25519 2>/dev/null)" || return 1
    X25519_PRIVKEY="$(echo "${out}" | awk -F': *' '/[Pp]rivate/{print $2; exit}')"
    X25519_PUBKEY="$(echo "${out}" | awk -F': *' '/[Pp]ublic|Password/{print $2; exit}')"
    [[ -n "${X25519_PRIVKEY}" && -n "${X25519_PUBKEY}" ]]
}

# 校验 REALITY 伪装目标站: TLS 1.3 + H2 可用 (XTLS 官方推荐检查项)
# OpenSSL 版本差异 (实测):
#   1.1.1+ : 支持 -tls1_3, 能真正验证 TLS1.3 握手
#   1.1.0  : (Ubuntu 18.04 自带 1.1.0g) 既不认 -tls1_3, 本身也不支持 TLS1.3,
#            只能用 -tls1_2 做可达性+握手校验, 属降级判定
# 降级时只告警不拒绝: 否则 18.04 上所有候选站都会被判失败, REALITY 无法安装。
OPENSSL_HAS_TLS13=""
openssl_has_tls13() {
    [[ -n "${OPENSSL_HAS_TLS13}" ]] && { [[ "${OPENSSL_HAS_TLS13}" == "1" ]]; return; }
    if openssl s_client -help 2>&1 | grep -q -- "-tls1_3"; then
        OPENSSL_HAS_TLS13="1"
    else
        OPENSSL_HAS_TLS13="0"
    fi
    [[ "${OPENSSL_HAS_TLS13}" == "1" ]]
}

check_reality_dest() {
    local dest="$1" sni="$2"
    if ! command -v openssl >/dev/null 2>&1; then
        return 0   # 无 openssl 时跳过强校验, 由用户自担
    fi
    local probe
    if openssl_has_tls13; then
        probe="$(echo | timeout 15 openssl s_client -connect "${dest}" -servername "${sni}" -alpn h2 -tls1_3 2>/dev/null)"
        echo "${probe}" | grep -q "TLSv1.3\|TLS 1.3\|Protocol *: TLSv1.3" || return 1
        return 0
    fi
    # 降级路径: 老 openssl 无法验证 TLS1.3, 退到 TLS1.2 握手成功即认为可达。
    # 该判定偏松 (可能放过不支持 TLS1.3 的站), 但远好过全部判死导致装不上。
    probe="$(echo | timeout 15 openssl s_client -connect "${dest}" -servername "${sni}" -alpn h2 -tls1_2 2>/dev/null)"
    echo "${probe}" | grep -qE "TLSv1\.[23]|Protocol *: *TLSv1" || return 1
    return 0
}

# 随机端口, 避开常用端口与已占用端口
gen_port() {
    local used_file="$1"
    local p
    while :; do
        p="$(shuf -i 10000-62000 -n 1 2>/dev/null || echo $((RANDOM + 10000)))"
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"; then
            continue
        fi
        if [[ -f "${used_file}" ]] && grep -qw "${p}" "${used_file}"; then
            continue
        fi
        echo "${p}"
        return
    done
}

record_port() {
    local used_file="${V2RAY_CONF_DIR}/used_ports.txt"
    mkdir -p "${V2RAY_CONF_DIR}"
    echo "$1" >> "${used_file}"
}

# 服务运行组的名字: Debian/Ubuntu 是 nogroup, RHEL/CentOS/Rocky/Alma/Fedora 是 nobody。
# systemd 的 Group= 指向不存在的组会让服务直接启动失败
# (实测: Failed with result 'exit-code'), 所以 unit 里不能硬编码 nogroup。
# 结果缓存在 NOBODY_GROUP, 首次调用时探测。
# getent 属 glibc 组件, Alpine 等 musl 系统没有, 此时退回读 /etc/group。
NOBODY_GROUP=""
group_exists() {
    if command -v getent >/dev/null 2>&1; then
        getent group "$1" >/dev/null 2>&1
    else
        grep -q "^$1:" /etc/group 2>/dev/null
    fi
}
detect_nobody_group() {
    [[ -n "${NOBODY_GROUP}" ]] && return 0
    if group_exists nogroup; then
        NOBODY_GROUP="nogroup"
    elif group_exists nobody; then
        NOBODY_GROUP="nobody"
    else
        # 极简系统两个都没有: 退到 root 组 (配置仍 640 root:root, 服务以 nobody 读)
        NOBODY_GROUP="root"
    fi
}

# 服务以 nobody 运行, 配置需可读: root:<组> 640 (不放 world)
fix_config_perm() {
    # sed -i 会重建文件导致属组回退为 root, 重置路径改完配置后调用本函数修正
    local f="$1"
    [[ -f "${f}" ]] || return 0
    detect_nobody_group
    chmod 640 "${f}" 2>/dev/null
    chgrp "${NOBODY_GROUP}" "${f}" 2>/dev/null || true
}

# core 配置语法预检 (借鉴 wulabing/Xray_onekey 的安装收尾自检):
# 配置写坏时 systemd + Restart=on-failure 会进入 crash loop, is-active 在
# 短暂窗口内可能误报通过; 先用官方校验直接拒绝坏配置, 错误信息也更可读。
# 注意两个 core 的校验入口不同: v2ray 是独立子命令 `v2ray test`,
# xray 是 `xray run -test` (实测确认, v2ray 无 run -test)。
validate_core_config() {
    local bin="$1" conf="$2" out
    if [[ "$(basename "${bin}")" == "xray" ]]; then
        out="$("$bin" run -test -config "${conf}" 2>&1)"
    else
        out="$("$bin" test -config "${conf}" 2>&1)"
    fi
    if [[ "$?" != "0" ]]; then
        log_error "core 配置校验失败 (${conf}):"
        echo "${out}" | head -10
        return 1
    fi
    return 0
}

# 撤销端口记录 (安装/重置取消或失败时用, 避免未真正使用的端口长期占用
# gen_port 的可用池)。只删一条与 $1 相同的记录。
unrecord_port() {
    local used_file="${V2RAY_CONF_DIR}/used_ports.txt"
    [[ -f "${used_file}" ]] || return 0
    local tmp="${used_file}.tmp.$$"
    grep -vx "$1" "${used_file}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${used_file}" || rm -f "${tmp}"
}

# 端口占用检查 (不含历史记录, 只看当前实际监听)
port_in_use() {
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}\$"
}

# 端口三选一: 默认 / 随机 / 自定义 (安装与重置共用)。
# 用法: pick_port <用途说明> <默认端口> [已用记录文件]
# 返回全局变量 PICK_PORT_RESULT; 返回值 1 = 用户选择 b 返回上一级 (调用方应中止当前操作)。
# 循环直到选中一个当前未被监听的端口:
#   - 随机端口本身已做占用规避, 但仍复核一次 (防时间窗竞态);
#   - 默认/自定义端口被占用或非法时提示并重新回到选择菜单;
#   - b 返回上级, 0/回车退出整个流程;
#   - 非交互 (stdin 非 tty, CLI 子命令/管道) 跳过询问, 等同于选随机。
pick_port() {
    local label="$1" default_port="$2" used_file="${3:-${V2RAY_CONF_DIR}/used_ports.txt}"
    local p
    if [[ ! -t 0 ]]; then
        PICK_PORT_RESULT="$(gen_port "${used_file}")"
        return 0
    fi
    while :; do
        echo "请选择 ${label} 端口:"
        echo "  1. 使用默认端口 ${default_port}"
        echo "  2. 随机分配端口 (自动避开占用)"
        echo "  3. 自定义端口 (1000-65535)"
        echo "  b. 返回上一级 (取消本次操作)"
        read -rp "请选择 [1]: " p || return 1
        p="${p:-1}"
        case "${p}" in
            1)
                if port_in_use "${default_port}"; then
                    log_error "默认端口 ${default_port} 已被占用,请换一个。"
                    continue
                fi
                if [[ -f "${used_file}" ]] && grep -qw "${default_port}" "${used_file}"; then
                    log_error "默认端口 ${default_port} 已被本脚本其他节点使用,请换一个。"
                    continue
                fi
                PICK_PORT_RESULT="${default_port}"
                return 0
                ;;
            2)
                PICK_PORT_RESULT="$(gen_port "${used_file}")"
                return 0
                ;;
            3)
                read -rp "请输入端口号 (1000-65535, b 返回): " p || return 1
                p="${p,,}"
                if [[ "${p}" == "b" ]]; then
                    return 1
                fi
                if ! [[ "${p}" =~ ^[0-9]+$ ]] || (( p < 1000 || p > 65535 )); then
                    log_error "端口号无效 (需 1000-65535),请重试。"
                    continue
                fi
                if port_in_use "${p}"; then
                    log_error "端口 ${p} 已被占用,请换一个。"
                    continue
                fi
                if [[ -f "${used_file}" ]] && grep -qw "${p}" "${used_file}"; then
                    log_error "端口 ${p} 已被本脚本其他节点使用,请换一个。"
                    continue
                fi
                PICK_PORT_RESULT="${p}"
                return 0
                ;;
            b|B)
                return 1
                ;;
            *)
                log_error "无效输入,请重试。"
                ;;
        esac
    done
}

# 端口监听终验: 分配时空闲不代表绑定成功 (存在时间窗竞态),
# 服务启动后确认端口真的在监听, 最多等 5 秒
verify_port_listening() {
    local port="$1" tries
    for tries in 1 2 3 4 5; do
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            return 0
        fi
        sleep 1
    done
    log_error "端口 ${port} 未处于监听状态 (可能已被其他程序占用,或服务启动失败)。"
    return 1
}

pause() { read -rp "按回车键继续..." _; }

# 停止服务并同步等待进程退出 (卸载用)。
# 不同 systemd 版本 stop 完成时间差异大 (255 会异步收尾): 若发完信号就删 unit 文件,
# stop 可能被跳过, 服务进程沦为孤儿继续监听端口。此函数等待进程真正退出, 兜底 SIGKILL。
# 进程匹配限定本脚本配置路径 (run -config /usr/local/etc/{v2ray,xray}/config_*.json),
# 不误伤系统里其他 v2ray/xray 实例。
# 可移植性注意: 不用分组括号 (procps-ng 老版本 pgrep 对 (a|b) 分组行为不一致), 用两条简单正则。
stop_service_sync() {
    local svc="$1" i alive p
    local pats=(
        'run -config /usr/local/etc/v2ray/config_'
        'run -config /usr/local/etc/xray/config_'
    )
    systemctl stop "${svc}" 2>/dev/null || true
    for i in 1 2 3 4 5; do
        alive=0
        for p in "${pats[@]}"; do
            if pgrep -f "${p}" >/dev/null 2>&1; then
                alive=1
                break
            fi
        done
        [[ "${alive}" == "0" ]] && return 0
        sleep 1
    done
    # 循环走完说明仍有进程存活, 精确匹配后强杀
    for p in "${pats[@]}"; do
        pkill -KILL -f "${p}" 2>/dev/null || true
    done
    return 0
}

# ---------- 环境检查 ----------

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log_error "请以 root 用户运行本脚本。"
        exit 1
    fi
}

check_system() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
    elif [[ -f /etc/redhat-release ]]; then
        ID="centos"
    else
        log_error "无法识别系统,本脚本支持 Debian / Ubuntu / CentOS。"
        exit 1
    fi

    case "${ID:-}" in
        debian|ubuntu|centos|rocky|almalinux|ol|rhel|fedora) ;;
        *)
            log_error "不支持的系统: ${PRETTY_NAME:-${ID:-unknown}}。"
            exit 1
            ;;
    esac
    log_info "当前系统: ${PRETTY_NAME:-${ID}}"

    # 硬性版本门槛: 不满足会中途报错(甚至装完起不来), 必须在最开始就拒绝。
    # bash 4.3+ : 脚本用 local -n (nameref) 收集链接/选站, 4.2 及以下直接
    #             `local: -n: invalid option` (CentOS 7 的 bash 4.2 就是这种)。
    # systemd 229+: AmbientCapabilities 才可用 (REALITY 监听 443 需要),
    #              CentOS 7 的 systemd 219 不支持。
    local bmajor bminor smajor
    bmajor="${BASH_VERSINFO[0]}"; bminor="${BASH_VERSINFO[1]}"
    if (( bmajor < 4 || (bmajor == 4 && bminor < 3) )); then
        log_error "bash 版本过低: ${BASH_VERSION} (需要 4.3+, 脚本使用 local -n)。"
        log_error "CentOS 7 自带 bash 4.2, 无法运行本脚本; 请改用 Debian 12 或 Ubuntu 22.04/24.04。"
        exit 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        smajor="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')"
        if [[ "${smajor}" =~ ^[0-9]+$ ]] && (( smajor < 229 )); then
            log_error "systemd 版本过低: ${smajor} (需要 229+, AmbientCapabilities 依赖)。"
            log_error "CentOS 7 自带 systemd 219, 无法运行本脚本。"
            exit 1
        fi
    fi

    # 按实测覆盖度分级提示: 仅 Debian 12 做过 1.5.0 全流程回归;
    # Debian 11/13 与 Ubuntu 各版本为历史记录, 本轮未复验;
    # RHEL 系为代码级支持(未真机验证), 后者要显式告知而不是静默继续。
    case "${ID:-}" in
        debian)
            case "${VERSION_ID:-}" in
                11|12|13) log_confirm "Debian ${VERSION_ID}: 已实测通过 (推荐使用)。" ;;
                *)        log_confirm "Debian ${VERSION_ID:-?}: 依赖满足, 但未在实测矩阵内。" ;;
            esac
            ;;
        ubuntu)
            case "${VERSION_ID:-}" in
                18.04|20.04|22.04|24.04) log_confirm "Ubuntu ${VERSION_ID}: 已实测通过 (推荐使用)。" ;;
                *)                        log_confirm "Ubuntu ${VERSION_ID:-?}: 依赖满足, 但未在实测矩阵内。" ;;
            esac
            ;;
        *)
            log_warn "=========================================================="
            log_warn " 注意: ${PRETTY_NAME:-${ID}} 属 RHEL 系,本脚本对该系列仅为"
            log_warn " 代码级支持,尚未做真机完整验证 (服务单元/权限/防火墙等"
            log_warn " 行为可能与 Debian 系不同)。"
            log_warn " 如条件允许,推荐改用 Debian 12 或 Ubuntu 22.04/24.04。"
            log_warn " 继续安装表示你接受自行排查该系列的系统差异。"
            log_warn "=========================================================="
            ;;
    esac
}

# 安装前确认: 系统为未真机验证的 RHEL 系时要求显式确认。
# 非交互 (CLI 子命令/管道) 下不阻塞, 仅保留上面的警告 —— 否则一键命令会被卡住。
confirm_untested_distro() {
    case "${ID:-}" in
        debian|ubuntu) return 0 ;;
    esac
    [[ -t 0 ]] || return 0
    local yn
    read -rp "当前系统未经真机验证,确认继续? [y/N]: " yn
    [[ "${yn,,}" == "y" ]]
}

# 环境预检: 在安装前一次性确认系统环境满足运行条件, 缺什么明确报告而不是中途报错
preflight_check() {
    local errors=() warns=()

    # 1. systemd: 全部服务管理依赖它 (LXC/容器可能没有)
    if ! command -v systemctl >/dev/null 2>&1; then
        errors+=("缺少 systemctl (无 systemd?) —— 本脚本需要在 systemd 环境运行,不支持纯容器")
    elif [[ ! -d /run/systemd/system ]]; then
        warns+=("systemd 未运行 (容器环境?),服务安装后可能无法自启,需手动管理")
    fi

    # 2. 核心工具: 缺失不立即退出 (最小化镜像常见), 交由 install_dependencies 安装后再复核;
    #    仅在系统无任何可用包管理器时才阻断
    local t missing_core=""
    for t in curl ss timeout shuf awk sed grep openssl; do
        command -v "${t}" >/dev/null 2>&1 || missing_core+="${t} "
    done
    if [[ -n "${missing_core}" ]]; then
        if command -v apt-get >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            warns+=("缺少核心工具: ${missing_core}(将由包管理器自动安装)")
        else
            errors+=("缺少核心工具: ${missing_core},且系统无 apt-get/dnf/yum,无法自动安装")
        fi
    fi

    # 3. 架构: v2ray/xray 官方发布支持的范围
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64|aarch64|armv7l|riscv64|loongarch64) ;;
        *) errors+=("不支持的 CPU 架构: ${arch} (支持 x86_64/aarch64/armv7l/riscv64/loongarch64)") ;;
    esac

    # 4. 虚拟化探测 (仅提示): OpenVZ/LXC 老面板内核常缺 TUN/部分模块
    if [[ -f /proc/vz ]] && ! grep -q vzfs /proc/mounts 2>/dev/null; then
        :
    elif [[ -d /proc/vz ]]; then
        warns+=("检测到 OpenVZ 虚拟化,部分内核模块可能受限")
    fi

    # 5. 网络出口: 访问 GitHub (安装 core 必需)
    if ! curl -sI --max-time 8 https://github.com -o /dev/null 2>&1; then
        warns+=("当前网络访问 github.com 不畅,安装/更新 core 可能失败 (代理或更换镜像)")
    fi

    # 6. 磁盘空间: core+geo 约需 200MB
    local avail_mb
    avail_mb="$(df -Pm / | tail -1 | awk '{print $4}')"
    if (( avail_mb < 200 )); then
        errors+=("根分区剩余空间不足: ${avail_mb}MB (至少需要 200MB)")
    elif (( avail_mb < 500 )); then
        warns+=("根分区剩余空间偏少: ${avail_mb}MB")
    fi

    # 报告
    local w
    for w in "${warns[@]}"; do
        log_warn "预检: ${w}"
    done
    if (( ${#errors[@]} > 0 )); then
        local e
        for e in "${errors[@]}"; do
            log_error "预检失败: ${e}"
        done
        exit 1
    fi
    log_info "环境预检通过 (arch=${arch}, 磁盘可用 ${avail_mb}MB)"
}

install_dependencies() {
    log_info "安装基础依赖 (curl wget socat qrencode openssl cron)..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl wget socat qrencode openssl cron ca-certificates iproute2 coreutils findutils
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        # Rocky/Alma/Fedora: qrencode 在 EPEL (部分镜像已内置)
        dnf install -y epel-release >/dev/null 2>&1 || true
        dnf install -y curl wget socat qrencode openssl cronie iproute coreutils || true
        command -v qrencode >/dev/null 2>&1 || dnf install -y qrencode >/dev/null 2>&1 || true
        systemctl enable --now crond >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        # CentOS 7 (EOL): 若官方源已归档失败, 不阻断; qrencode 在 EPEL
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y curl wget socat openssl cronie iproute coreutils || true
        yum install -y qrencode >/dev/null 2>&1 || true
        systemctl enable --now crond >/dev/null 2>&1
    else
        log_error "未找到 apt-get / dnf / yum,无法自动安装依赖。"
        exit 1
    fi

    # 缺失项降级处理: 核心依赖必须存在, 次要依赖缺失仅告警
    # (与预检清单一致: ss/iproute、timeout/shuf/od/coreutils 为端口与服务逻辑必需)
    local missing_core=""
    for c in curl wget openssl ss timeout shuf awk sed grep; do
        command -v "${c}" >/dev/null 2>&1 || missing_core+="${c} "
    done
    if [[ -n "${missing_core}" ]]; then
        log_error "核心依赖安装失败: ${missing_core},请手动安装后重试。"
        exit 1
    fi
    command -v qrencode >/dev/null 2>&1 || log_warn "qrencode 不可用,安装完成后不显示二维码(分享链接功能不受影响)。"

    # SELinux Enforcing (RHEL 系默认): 放行 nginx 反代本地端口
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
        if command -v setsebool >/dev/null 2>&1; then
            setsebool -P httpd_can_network_connect 1 || true
        fi
        # h2/REALITY 由 v2ray/xray 直接绑定非保留端口, 上游 systemd 单元含
        # CAP_NET_BIND_SERVICE 时 443 也可绑定; /data 下证书读取一般不受限。
        # 极端情况下若服务启动被 AVC 拒绝, 提示用户用 audit2allow 处理
        log_info "SELinux 为 Enforcing,已放行 httpd_can_network_connect。若服务启动异常,请检查 audit 日志 (ausearch -m avc -ts recent)。"
    fi
}

# 启动阶段依赖检查: 在弹出主菜单之前执行, 保证菜单 7/10/11/12/15 等功能也可用。
# 背景: 依赖安装原先只在 do_install (用户选安装项) 里触发, 菜单 7 等路径不经过它,
# 在精简系统上会因缺 curl/openssl 而静默产出错误链接 (调用多带 2>/dev/null)。
# 策略:
#   - BASE_DEPS 缺失 -> 直接退出 (无这些根本无法运行)
#   - RUNTIME_DEPS 缺失 -> 交互模式提示并确认后安装; 非交互直接装(不阻塞一键命令)
#   - 装完仍缺 -> 明确警告哪些功能受影响, 但仍放行菜单 (用户至少要能看节点/卸载)
#   - OPTIONAL_DEPS 缺失 -> 仅提示, 不安装
#   - 只执行一次 (DEPS_CHECKED), 避免每次回菜单重复 apt-get
ensure_runtime_deps() {
    [[ "${DEPS_CHECKED}" == "1" ]] && return 0

    local missing_base="" missing_rt="" missing_opt="" c
    for c in ${BASE_DEPS}; do
        command -v "${c}" >/dev/null 2>&1 || missing_base+="${c} "
    done
    for c in ${RUNTIME_DEPS}; do
        command -v "${c}" >/dev/null 2>&1 || missing_rt+="${c} "
    done
    for c in ${OPTIONAL_DEPS}; do
        command -v "${c}" >/dev/null 2>&1 || missing_opt+="${c} "
    done

    # 1) 基础工具缺失: 无法运行, 直接退出并给出手动安装建议
    if [[ -n "${missing_base}" ]]; then
        log_error "缺少基础命令: ${missing_base}"
        log_error "这些是脚本运行的前提, 无法自动修复。请先安装 coreutils 与文本工具后重试。"
        exit 1
    fi

    # 2) 运行时依赖缺失: 按发行版安装
    if [[ -n "${missing_rt}" ]]; then
        local pkgmgr=""
        if command -v apt-get >/dev/null 2>&1; then pkgmgr="apt"
        elif command -v dnf >/dev/null 2>&1; then pkgmgr="dnf"
        elif command -v yum >/dev/null 2>&1; then pkgmgr="yum"
        fi

        if [[ -z "${pkgmgr}" ]]; then
            log_warn "缺少: ${missing_rt}且系统无 apt-get/dnf/yum, 无法自动安装。"
            log_warn "受影响功能: 菜单 7 链接生成(公网IP/base64)、REALITY 选站、端口查重、下载安装。"
        else
            log_warn "检测到缺失依赖: ${missing_rt}"
            local do_install_now=1
            if [[ -t 0 ]]; then
                log_confirm "将使用 ${pkgmgr} 安装上述软件包, 这会修改系统已安装软件。"
                local yn
                read -rp "是否现在安装? [Y/n]: " yn
                [[ "${yn,,}" == "n" ]] && do_install_now=0
            fi
            if [[ "${do_install_now}" == "1" ]]; then
                install_runtime_deps "${pkgmgr}"
                # 装完复核: 以命令是否真的可用为准, 不信包管理器的返回码
                local still=""
                for c in ${RUNTIME_DEPS}; do
                    command -v "${c}" >/dev/null 2>&1 || still+="${c} "
                done
                if [[ -n "${still}" ]]; then
                    log_error "依赖安装未完全成功, 仍缺少: ${still}"
                    log_warn "已尝试: 索引刷新 -> 批量安装 -> --fix-missing 重试 -> 逐个安装。"
                    log_warn "完整日志: /tmp/v2ray_deps_install.log"
                    log_warn "请按上面的日志排查 (常见原因: 软件源不可达/被墙、源列表损坏、磁盘满)。"
                    log_warn "可手动安装后重新运行本脚本, 例如:"
                    case "${pkgmgr}" in
                        apt) log_warn "  apt-get update && apt-get install -y ${still}" ;;
                        *)   log_warn "  ${pkgmgr} install -y ${still}" ;;
                    esac
                    log_warn "受影响功能: 菜单 7 链接生成(公网IP/base64)、REALITY 选站、端口查重、下载安装。"
                    log_warn "继续进入菜单, 但上述功能可能异常。"
                else
                    log_info "运行时依赖已就绪。"
                fi
            else
                log_warn "已跳过依赖安装 (你选择了 n)。缺失 ${missing_rt}可能导致部分功能异常。"
                log_warn "需要时可重新运行本脚本, 或手动安装:"
                case "${pkgmgr}" in
                    apt) log_warn "  apt-get install -y ${missing_rt}" ;;
                    *)   log_warn "  ${pkgmgr} install -y ${missing_rt}" ;;
                esac
            fi
        fi
    fi

    # 3) 可选依赖: 只提示
    if [[ -n "${missing_opt}" ]]; then
        log_warn "可选组件缺失: ${missing_opt} (不影响核心功能)"
        case "${missing_opt}" in
            *qrencode*) log_warn "  - qrencode: 不显示二维码, 分享链接仍正常输出" ;;
        esac
        case "${missing_opt}" in
            *socat*) log_warn "  - socat: 证书申请备用方案不可用" ;;
        esac
    fi

    DEPS_CHECKED=1
    return 0
}

# 按包管理器安装运行时依赖 (只装缺失的, 不整包重装)
# 按包管理器安装运行时依赖 (只装缺失的)。
# 设计原则: 尽力保障装成功, 不静默跳过。已覆盖的最差情况:
#   1. apt 索引损坏/不同步 -> update 后仍失败, 用 --fix-missing 重试
#   2. 某个包在源里不可用   -> 逐个安装, 不让一个包拖垮整批
#   3. 软件源不可达/被墙     -> 记录日志并明确报错, 给出手动命令, 不假装成功
#   4. apt/dpkg 被其他进程占用 -> 先等锁 (最多 60s), 超时则提示而不是干等
#   5. 命令挂死(网络黑洞)     -> 所有 apt/dnf 调用套 timeout, 避免卡死菜单
#   6. 磁盘不足               -> 安装前检查, 空间不够直接说明而不是装到一半失败
#   7. 半装状态(dpkg interrupted) -> 尝试 dpkg --configure -a 修复后重试
# 返回 0 表示"已尽力", 是否真的可用由调用方 command -v 复核。
install_runtime_deps() {
    local pkgmgr="$1" pkgs="" c
    for c in ${RUNTIME_DEPS}; do
        command -v "${c}" >/dev/null 2>&1 && continue
        case "${c}" in
            ss)     pkgs+="iproute2 " ;;
            base64|od) pkgs+="coreutils " ;;
            *)      pkgs+="${c} " ;;
        esac
    done
    pkgs="$(printf '%s\n' ${pkgs} | sort -u | tr '\n' ' ')"
    [[ -z "${pkgs// /}" ]] && return 0

    local logf="/tmp/v2ray_deps_install.log"
    : > "${logf}" 2>/dev/null || logf="/dev/null"
    _dep_log() { echo "[$(date '+%H:%M:%S')] $*" >> "${logf}" 2>/dev/null; }

    log_info "安装: ${pkgs}"

    # 最差情况 6: 磁盘空间 (装这些包约需 30-60MB, 留 100MB 余量)
    local avail_mb
    avail_mb="$(df -Pm / | tail -1 | awk '{print $4}' 2>/dev/null)"
    if [[ "${avail_mb}" =~ ^[0-9]+$ ]] && (( avail_mb < 100 )); then
        log_error "磁盘剩余 ${avail_mb}MB, 不足以安装依赖 (需至少 100MB)。"
        log_warn "请清理空间后重新运行本脚本。"
        return 1
    fi

    # 最差情况 4: dpkg 锁被占用 (unattended-upgrades / 用户手动 apt 常见)
    _wait_dpkg_lock() {
        [[ "${pkgmgr}" == "apt" ]] || return 0
        local i
        for i in $(seq 1 30); do
            if ! fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; then
                return 0
            fi
            [[ "${i}" == "1" ]] && log_warn "apt/dpkg 被其他进程占用, 等待锁释放 (最多 60s)..."
            sleep 2
        done
        log_warn "等待 dpkg 锁超时。可能有 apt 正在运行 (如自动更新), 请稍后重试。"
        _dep_log "dpkg lock timeout"
        return 1
    }

    # 所有包管理调用统一套 timeout (最差情况 5: 网络黑洞导致挂死)
    _pkg_run() {
        local secs="$1"; shift
        timeout "${secs}" "$@" >>"${logf}" 2>&1
    }

    case "${pkgmgr}" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            _wait_dpkg_lock || { log_warn "跳过安装 (锁未释放)。"; return 1; }

            # 最差情况 7: 上次安装中断留下的半装状态
            if [[ -f /var/lib/dpkg/updates/0000 ]] || dpkg --audit 2>/dev/null | grep -q .; then
                log_warn "检测到 dpkg 半装状态, 先修复..."
                _dep_log "dpkg --configure -a"
                _pkg_run 120 dpkg --configure -a || true
            fi

            # 1) 刷新索引 (失败继续用现有索引)
            _dep_log "apt-get update"
            if ! _pkg_run 180 apt-get update -y; then
                log_warn "apt 索引刷新失败, 用现有索引继续。"
                _dep_log "update failed, continue"
            fi

            # 2) 批量安装
            # shellcheck disable=SC2086
            if _pkg_run 300 apt-get install -y --no-install-recommends ${pkgs}; then
                _dep_log "batch install OK"
            else
                log_warn "批量安装失败, 尝试 --fix-missing 修复..."
                _dep_log "retry --fix-missing"
                # shellcheck disable=SC2086
                if _pkg_run 300 apt-get install -y --fix-missing --no-install-recommends ${pkgs}; then
                    _dep_log "fix-missing OK"
                else
                    log_warn "修复重试仍失败, 改为逐个安装..."
                    local one
                    for one in ${pkgs}; do
                        _dep_log "single: ${one}"
                        _pkg_run 180 apt-get install -y --no-install-recommends "${one}" \
                            || _dep_log "single failed: ${one}"
                    done
                fi
            fi
            ;;
        dnf|yum)
            _dep_log "${pkgmgr}: epel"
            _pkg_run 120 "${pkgmgr}" install -y epel-release || true
            _dep_log "${pkgmgr} install ${pkgs}"
            # shellcheck disable=SC2086
            if _pkg_run 300 "${pkgmgr}" install -y ${pkgs}; then
                _dep_log "batch OK"
            else
                log_warn "批量安装失败, 改为逐个安装..."
                local one
                for one in ${pkgs}; do
                    _dep_log "single: ${one}"
                    _pkg_run 180 "${pkgmgr}" install -y "${one}" \
                        || _dep_log "single failed: ${one}"
                done
            fi
            ;;
    esac
    return 0
}

# 探测系统现有 Nginx 环境 (宝塔面板 / 发行版 Nginx / 全新系统)
# 结果写入 NGINX_ENV / NGINX_BIN / NGINX_VHOST_DIR / NGINX_RELOAD_CMD / WS_NGINX_CONF
# 场景: 先用本脚本装过 ws (配置在发行版 nginx), 之后装了宝塔 —— 旧配置位于
# /etc/nginx/conf.d, 宝塔 nginx 不加载该目录, ws 节点会静默失效; 检测到此
# 情况时自动把配置迁移到宝塔 vhost 目录并重载两边。
# 迁移后做双重验证 (宝塔 nginx 配置可用 + v2ray-ws 服务与端口正常),
# 任一不通过则整体回退: 配置移回原位、重载两边, 并告知用户手动处理。
migrate_ws_conf_to_btpanel() {
    local old_conf="/etc/nginx/conf.d/v2ray-ws-tls.conf"
    [[ -f "${old_conf}" ]] || return 0
    [[ ! -f "${WS_NGINX_CONF}" ]] || return 0   # 宝塔目录已有, 不重复迁移
    if [[ -t 0 ]]; then
        log_warn "检测到旧的 ws nginx 配置 (/etc/nginx/conf.d) 与宝塔环境并存,"
        log_warn "宝塔 Nginx 不会加载该目录, ws 节点已失效。"
        local yn
        read -rp "是否迁移到宝塔 Nginx (${WS_NGINX_CONF})? [Y/n]: " yn
        [[ "${yn,,}" == "n" ]] && { log_info "已跳过迁移 (旧配置保持原样)。"; return 0; }
    else
        log_info "检测到旧的 ws nginx 配置与宝塔环境并存,自动迁移到宝塔 Nginx。"
    fi

    local bt_nginx="/www/server/nginx/sbin/nginx"
    local reload_bt_ok=0 reload_old_ok=0

    mv -f "${old_conf}" "${WS_NGINX_CONF}"
    if [[ -x "${bt_nginx}" ]]; then
        if "${bt_nginx}" -t >/dev/null 2>&1 && "${bt_nginx}" -s reload >/dev/null 2>&1; then
            reload_bt_ok=1
        fi
    fi
    # 发行版 nginx 仍在运行则一并重载, 让它释放旧配置 (文件已移走, reload 无副作用)
    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null && reload_old_ok=1
    fi

    # ---- 迁移后验证 ----
    # 1) 宝塔 nginx: 配置测试通过且 reload 成功 (reload 失败意味着新配置有问题,
    #    nginx 会继续跑旧配置, ws 依旧不通)
    # 2) ws 服务: v2ray-ws unit 存在时要求服务 active 且内部端口监听
    #    (v2ray-ws 是独立 systemd 服务, 不随 nginx 重启, 正常应不受迁移影响;
    #     迁移若引发异常说明环境有其他问题, 同样按失败回退)
    local bt_ok=0 ws_ok=0
    [[ "${reload_bt_ok}" == "1" ]] && bt_ok=1
    if [[ -f "/etc/systemd/system/${WS_SERVICE}.service" ]]; then
        if systemctl is-active --quiet "${WS_SERVICE}" \
            && verify_port_listening "$(grep -o '"port": [0-9]*' "${WS_CONF}" | head -1 | grep -o '[0-9]*')" >/dev/null 2>&1; then
            ws_ok=1
        fi
    else
        ws_ok=1   # ws 未安装, 无需验证服务
    fi

    if [[ "${bt_ok}" == "1" && "${ws_ok}" == "1" ]]; then
        log_info "迁移验证通过: 宝塔 Nginx 配置生效,ws 服务与端口正常。迁移完成。"
        return 0
    fi

    # ---- 回退 ----
    log_warn "迁移后验证未通过 (宝塔 nginx reload: ${reload_bt_ok}/1, ws 服务: ${ws_ok}/1),回退迁移:"
    mv -f "${WS_NGINX_CONF}" "${old_conf}"
    if [[ -x "${bt_nginx}" ]]; then
        "${bt_nginx}" -t >/dev/null 2>&1 && "${bt_nginx}" -s reload >/dev/null 2>&1 || true
    fi
    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    fi
    log_warn "已回退: ws 配置保持原位 (${old_conf}),宝塔环境未改动。"
    log_warn "宝塔 Nginx 无法加载该配置目录,ws 节点仍不可用。建议: 先在宝塔中"
    log_warn "停止或卸载其 Nginx 后重跑本脚本, 或手动把 ${old_conf} 的内容"
    log_warn "并入宝塔站点配置后再迁移。"
    return 1
}

detect_nginx_env() {
    # 1) 宝塔面板: 使用宝塔自编译 Nginx, 配置写进其 vhost 目录
    if [[ -d "${BT_PANEL_DIR}" && -d "${BT_NGINX_VHOST_DIR}" && -x /www/server/nginx/sbin/nginx ]]; then
        NGINX_ENV="btpanel"
        NGINX_BIN="/www/server/nginx/sbin/nginx"
        NGINX_VHOST_DIR="${BT_NGINX_VHOST_DIR}"
        WS_NGINX_CONF="${NGINX_VHOST_DIR}/v2ray-ws-tls.conf"
        NGINX_RELOAD_CMD="${NGINX_BIN} -s reload"
        log_info "检测到宝塔面板,将复用宝塔 Nginx (不安装第二个 Nginx): ${NGINX_BIN}"
        migrate_ws_conf_to_btpanel
        return
    fi

    # 2) 发行版 Nginx 已存在: 直接复用, 不重复安装
    if command -v nginx >/dev/null 2>&1; then
        NGINX_ENV="distro"
        NGINX_BIN="$(command -v nginx)"
        NGINX_VHOST_DIR="/etc/nginx/conf.d"
        WS_NGINX_CONF="${NGINX_VHOST_DIR}/v2ray-ws-tls.conf"
        NGINX_RELOAD_CMD="systemctl reload nginx"
        log_info "检测到已有 Nginx,将复用现有 Nginx (不重复安装): ${NGINX_BIN}"
        return
    fi

    # 3) 全新系统: 安装发行版 Nginx
    NGINX_ENV="none"
    log_info "未检测到 Nginx,将安装发行版 Nginx。"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y nginx
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx
    fi
    systemctl enable --now nginx >/dev/null 2>&1 || true
    if ! command -v nginx >/dev/null 2>&1; then
        log_error "Nginx 安装失败。"
        exit 1
    fi
    NGINX_ENV="distro"
    NGINX_BIN="$(command -v nginx)"
    NGINX_VHOST_DIR="/etc/nginx/conf.d"
    WS_NGINX_CONF="${NGINX_VHOST_DIR}/v2ray-ws-tls.conf"
    NGINX_RELOAD_CMD="systemctl reload nginx"
}

# 校验/重载 Nginx (兼容宝塔与发行版)
nginx_check_reload() {
    # NGINX_BIN 未初始化时 (如重置节点先于 ws 安装被调用) 自动探测
    if [[ -z "${NGINX_BIN}" ]]; then
        NGINX_BIN="$(command -v nginx 2>/dev/null || echo /www/server/nginx/sbin/nginx)"
        [[ -x "${NGINX_BIN}" ]] || { log_warn "未找到 nginx,跳过 reload。"; return 0; }
        [[ "${NGINX_ENV}" == "none" ]] && NGINX_ENV="distro"
    fi
    if ! "${NGINX_BIN}" -t >/dev/null 2>&1; then
        log_error "nginx 配置测试失败:"
        "${NGINX_BIN}" -t
        exit 1
    fi
    if [[ "${NGINX_ENV}" == "btpanel" ]]; then
        "${NGINX_BIN}" -s reload 2>/dev/null || true
    else
        systemctl reload nginx 2>/dev/null || true
    fi
}

open_firewall() {
    # 尽力而为:存在防火墙服务才放行,失败不阻断
    # REALITY 端口在任何模式下都必须放行 (独立服务, 端口安装时才确定)
    if [[ -n "${REALITY_PORT}" ]]; then :; fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        [[ -n "${XHTTP_PORT}" ]]      && ufw allow "${XHTTP_PORT}/tcp"      >/dev/null 2>&1
        [[ -n "${SOCKS_PORT}" ]]   && ufw allow "${SOCKS_PORT}/tcp"   >/dev/null 2>&1
        [[ -n "${REALITY_PORT}" ]] && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1
        log_info "已通过 ufw 放行相关端口。"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http  >/dev/null 2>&1
        firewall-cmd --permanent --add-service=https >/dev/null 2>&1
        [[ -n "${XHTTP_PORT}" ]]      && firewall-cmd --permanent --add-port="${XHTTP_PORT}/tcp"      >/dev/null 2>&1
        [[ -n "${SOCKS_PORT}" ]]   && firewall-cmd --permanent --add-port="${SOCKS_PORT}/tcp"   >/dev/null 2>&1
        [[ -n "${REALITY_PORT}" ]] && firewall-cmd --permanent --add-port="${REALITY_PORT}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log_info "已通过 firewalld 放行相关端口。"
    fi
}

get_public_ip() {
    local ip=""
    # curl 缺失时 (依赖安装失败且用户选择继续) 优雅降级: 用 wget 兜底,
    # 两者都没有就留空, 由调用方用 127.0.0.1 占位并提示, 不刷屏报错
    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -4 -s --max-time 8 https://api.ip.sb/ip || true)"
        [[ -z "${ip}" ]] && ip="$(curl -4 -s --max-time 8 https://ifconfig.me || true)"
        [[ -z "${ip}" ]] && ip="$(curl -4 -s --max-time 8 https://api.ipify.org || true)"
    elif command -v wget >/dev/null 2>&1; then
        ip="$(wget -4 -qO- --timeout=8 https://api.ip.sb/ip 2>/dev/null || true)"
        [[ -z "${ip}" ]] && ip="$(wget -4 -qO- --timeout=8 https://api.ipify.org 2>/dev/null || true)"
    else
        log_warn "curl/wget 均不可用, 无法获取公网 IP (链接将用 127.0.0.1 占位)。"
    fi
    PUBLIC_IP="${ip//[$'\r\n']/}"
}

check_domain() {
    local domain="$1"
    if ! echo "${domain}" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'; then
        log_error "域名格式不正确: ${domain}"
        return 1
    fi
    local resolved=""
    if command -v getent >/dev/null 2>&1; then
        resolved="$(getent hosts "${domain}" 2>/dev/null | awk '{print $1; exit}')"
    fi
    if [[ -z "${resolved}" ]]; then
        # 备选: python3 (RHEL 最小安装无 nslookup/dig, 但常有 python3)
        if command -v python3 >/dev/null 2>&1; then
            resolved="$(python3 -c "import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: pass" "${domain}" 2>/dev/null)"
        fi
    fi
    if [[ -z "${resolved}" ]] && command -v nslookup >/dev/null 2>&1; then
        resolved="$(nslookup "${domain}" 2>/dev/null | awk '/^Address/ && !/127.0.0.1|#/{print $2; exit}')"
    fi
    if [[ -z "${resolved}" ]]; then
        log_error "无法解析域名 ${domain},请确认 DNS 已生效(A 记录指向本机)。"
        return 1
    fi

    get_public_ip
    if [[ -z "${PUBLIC_IP}" ]]; then
        log_warn "无法获取本机公网 IP,跳过域名解析核对。"
        return 0
    fi
    if [[ "${resolved}" != "${PUBLIC_IP}" ]]; then
        log_warn "域名 ${domain} 解析到 ${resolved},本机公网 IP 为 ${PUBLIC_IP}。"
        log_warn "若解析结果不是本机 IP,后续证书申请会失败。"
        read -rp "确认继续吗? [y/N]: " yn
        [[ "${yn,,}" == "y" ]] || return 1
    fi
    return 0
}

# ---------- V2Ray core ----------

ensure_v2ray() {
    if command -v v2ray >/dev/null 2>&1 && [[ -x /usr/local/bin/v2ray ]]; then
        log_info "V2Ray 已安装: $(/usr/local/bin/v2ray version 2>/dev/null | head -1)"
    else
        log_info "安装/更新 V2Ray core (v2fly 官方脚本)..."
        if ! bash <(curl -L -s "${V2RAY_INSTALL_SCRIPT}"); then
            log_error "V2Ray 安装失败,请检查网络。"
            exit 1
        fi
    fi
    mkdir -p "${V2RAY_CONF_DIR}"
    ensure_geo_data
}

# 路由规则 geoip:private 依赖 geoip.dat;官方安装脚本可能不带,缺失时补齐
ensure_geo_data() {
    local geo_dir="/usr/local/share/v2ray"
    if [[ -s "${geo_dir}/geoip.dat" && -s "${geo_dir}/geosite.dat" ]]; then
        return
    fi
    mkdir -p "${geo_dir}"
    log_info "下载 geo 数据文件 (geoip.dat / geosite.dat)..."
    if [[ ! -s "${geo_dir}/geoip.dat" ]]; then
        curl -sL --max-time 120 -o "${geo_dir}/geoip.dat" \
            "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" || true
    fi
    if [[ ! -s "${geo_dir}/geosite.dat" ]]; then
        # v2fly 官方 domain-list-community 的 latest 资产可能 404, 备选 Loyalsoldier 源
        curl -sL --max-time 120 -o "${geo_dir}/geosite.dat" \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" || true
    fi
    if [[ -s "${geo_dir}/geoip.dat" && -s "${geo_dir}/geosite.dat" ]]; then
        log_info "geo 数据就绪。"
    else
        log_warn "geo 数据下载失败,若服务启动报 geoip 缺失,请手动下载到 ${geo_dir}/"
    fi
}

ensure_xray() {
    if command -v xray >/dev/null 2>&1 && [[ -x /usr/local/bin/xray ]]; then
        log_info "Xray 已安装: $(/usr/local/bin/xray version 2>/dev/null | head -1)"
        return
    fi
    log_info "安装/更新 Xray core (XTLS 官方脚本)..."
    if ! bash <(curl -L -s "${XRAY_INSTALL_SCRIPT}"); then
        log_error "Xray 安装失败,请检查网络。"
        exit 1
    fi
    # 官方 Xray-install 脚本会自启并开机启用自带的 xray.service (跑占位 config.json),
    # 本脚本所有 REALITY 实例使用独立的 xray-reality.service, 该官方服务是无用常驻进程,
    # 且与我们的实例无关, 统一停用禁用 (跨发行版 systemctl 行为一致)。
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray >/dev/null 2>&1 || true
    mkdir -p "${XRAY_CONF_DIR}"
}

# xhttp 配置的 routing 依赖 geoip:private, 需要 /usr/local/share/xray/geoip.dat。
# 官方安装脚本在 Xray 已安装时走"更新"分支, 不会重下 geodata; 存量机器可能
# 只有 REALITY (其配置同样用 geoip:private, 但可能靠 v2ray 的 geo 目录兜底),
# 因此这里独立兜底一次, 缺失才下载。
ensure_xray_geo_data() {
    local geo_dir="/usr/local/share/xray"
    if [[ -s "${geo_dir}/geoip.dat" && -s "${geo_dir}/geosite.dat" ]]; then
        return
    fi
    mkdir -p "${geo_dir}"
    log_info "下载 Xray geo 数据文件 (geoip.dat / geosite.dat)..."
    # 资产名与官方 Xray-install 一致: geoip 只有 full/lite 两种, 落地统一命名 geoip.dat
    if [[ ! -s "${geo_dir}/geoip.dat" ]]; then
        curl -sL --max-time 180 -o "${geo_dir}/geoip.dat" \
            "https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geoip-full.dat" || true
    fi
    if [[ ! -s "${geo_dir}/geosite.dat" ]]; then
        curl -sL --max-time 180 -o "${geo_dir}/geosite.dat" \
            "https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geosite.dat" || true
    fi
    if [[ -s "${geo_dir}/geoip.dat" && -s "${geo_dir}/geosite.dat" ]]; then
        log_info "Xray geo 数据就绪。"
    else
        log_warn "Xray geo 数据下载失败,若服务启动报 geoip 缺失,请手动下载到 ${geo_dir}/"
    fi
}

# ---------- 证书 (ws 与 xhttp 共用 /data 下的证书) ----------

create_webroot() {
    mkdir -p "${WS_WWW_ROOT}"
    if [[ -f "${WS_WWW_ROOT}/index.html" ]]; then
        return
    fi
    cat > "${WS_WWW_ROOT}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome to nginx!</title>
<style>
    body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
EOF
}

# 防误伤检查: 该域名是否已被现有网站使用 (宝塔 vhost / nginx conf)
# 只对"已有站点配置且根目录非本脚本伪装目录"的情况报警, 避免把用户的业务域装坏
check_domain_conflict() {
    local domain="$1"
    local hit=""
    # 宝塔: 域名即 vhost 文件名
    if [[ -f "${BT_NGINX_VHOST_DIR}/${domain}.conf" ]]; then
        hit="${BT_NGINX_VHOST_DIR}/${domain}.conf"
    fi
    if [[ -z "${hit}" && -f "${NGINX_VHOST_DIR}" ]] ; then :; fi
    if [[ -z "${hit}" ]]; then
        hit="$(grep -rls "server_name ${domain}" /etc/nginx/ 2>/dev/null | head -1 || true)"
    fi
    if [[ -z "${hit}" && -d "${BT_NGINX_VHOST_DIR}" ]]; then
        hit="$(grep -rls "server_name ${domain}" "${BT_NGINX_VHOST_DIR}" 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "${hit}" && "${hit}" != "${WS_NGINX_CONF}" ]]; then
        log_warn "域名 ${domain} 已被现有网站配置使用: ${hit}"
        log_warn "本脚本会在该 server_name 上追加代理路径(伪装站逻辑不再生效),不影响原网站的其余路径。"
        read -rp "确认继续吗? [y/N]: " yn
        [[ "${yn,,}" == "y" ]] || exit 1
    fi
}

install_acme() {
    if [[ -f /root/.acme.sh/acme.sh ]]; then
        return
    fi
    log_info "安装 acme.sh..."
    if ! curl -sL https://get.acme.sh | sh -s email="acme@${DOMAIN}" ; then
        log_error "acme.sh 安装失败。"
        exit 1
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    # 显式确保自动续签 cron 存在 (acme.sh 安装时通常会自装, 但 cron 环境缺失的
    # 最小系统上可能失败; 各发行版 crontab 命令名不同, 做兼容)
    if ! crontab -l 2>/dev/null | grep -q "acme.sh"; then
        if command -v crontab >/dev/null 2>&1; then
            (crontab -l 2>/dev/null; echo '0 3 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" > /dev/null') | crontab - 2>/dev/null                 && log_info "已配置 acme.sh 自动续签 cron (每天 03:00 检查)。"
        elif [[ -d /etc/cron.d ]]; then
            echo '0 3 * * * root "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" > /dev/null' > /etc/cron.d/acme-renew
            log_info "已配置 /etc/cron.d/acme-renew 自动续签。"
        else
            log_warn "系统无 cron,自动续签不可用;请每 60 天手动运行菜单 8 或 ssl_update.sh。"
        fi
    fi
}

issue_certificate() {
    mkdir -p "${CERT_DIR}"
    if [[ -f "${CRT_FILE}" && -f "${KEY_FILE}" ]]; then
        log_info "检测到已有证书 ${CRT_FILE},跳过申请。"
        return
    fi

    install_acme

    # 首次签发时序: 现有 Nginx 可能还没有为该域名服务 80 端口,
    # 先写一个仅含 webroot 验证目录的临时 80 端口站点并重载, 验证通过后再签发
    cat > "${NGINX_VHOST_DIR}/v2ray-acme-bootstrap.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root ${WS_WWW_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }
}
EOF
    if [[ "${NGINX_ENV}" == "btpanel" ]] || [[ "${NGINX_ENV}" == "distro" ]]; then
        nginx_check_reload || true
    fi

    # 若存在旧证书, 先备份; 签发失败时回滚, 避免无效内容导致 nginx 无法加载证书
    local cert_backup=""
    if [[ -f "${CRT_FILE}" ]]; then
        cert_backup="${CRT_FILE}.bak.$$"
        cp -a "${CRT_FILE}" "${cert_backup}"
    fi

    log_info "使用 HTTP 验证方式申请 Let's Encrypt 证书 (域名: ${DOMAIN})..."
    if /root/.acme.sh/acme.sh --issue -d "${DOMAIN}" -w "${WS_WWW_ROOT}" --server letsencrypt --log; then
        /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" \
            --fullchain-file "${CRT_FILE}" \
            --key-file "${KEY_FILE}" \
            --reloadcmd "bash -c '${NGINX_BIN} -s reload 2>/dev/null; systemctl reload nginx 2>/dev/null; systemctl restart ${WS_SERVICE} ${XHTTP_SERVICE} 2>/dev/null; exit 0'"
        # 服务以 nobody 运行, 私钥需可读: root:nogroup 640 (nginx 以 root 起 worker
        # 前读证书不受影响, key 只对 root 组内可见, 不放 world)
        chmod 640 "${KEY_FILE}" 2>/dev/null
        chgrp nogroup "${KEY_FILE}" 2>/dev/null || chgrp nobody "${KEY_FILE}" 2>/dev/null || true
        log_info "证书申请并安装成功: ${CRT_FILE}"
        [[ -n "${cert_backup}" ]] && rm -f "${cert_backup}"
    else
        log_warn "证书自动申请失败(常见原因: 域名未解析到本机 / 80 端口被占用或封禁 / 被防火墙拦截)。"
        # 回滚: 不让 acme.sh 的失败安装污染证书文件, 保证 nginx 仍能加载
        if [[ -n "${cert_backup}" ]]; then
            mv -f "${cert_backup}" "${CRT_FILE}"
            log_info "已保留原有证书文件 ${CRT_FILE}。"
        else
            rm -f "${CRT_FILE}" "${KEY_FILE}"
        fi
        log_confirm "可稍后手动申请: ${SSL_UPDATE_SH}"
        log_confirm "或自行将证书放到 ${CRT_FILE} 与 ${KEY_FILE} 后,重跑本脚本。"
    fi
    rm -f "${NGINX_VHOST_DIR}/v2ray-acme-bootstrap.conf"
}

write_ssl_update_script() {
    cat > "${SSL_UPDATE_SH}" <<EOF
#!/usr/bin/env bash
# 手动续签/重新申请证书脚本
/root/.acme.sh/acme.sh --renew -d "${DOMAIN}" --force \\
    --fullchain-file "${CRT_FILE}" \\
    --key-file "${KEY_FILE}" \\
    --reloadcmd "bash -c 'chmod 640 ${KEY_FILE} 2>/dev/null; chgrp nogroup ${KEY_FILE} 2>/dev/null || chgrp nobody ${KEY_FILE} 2>/dev/null; ${NGINX_BIN} -s reload 2>/dev/null; systemctl reload nginx 2>/dev/null; systemctl restart ${WS_SERVICE} ${XHTTP_SERVICE} 2>/dev/null; exit 0'"
EOF
    chmod +x "${SSL_UPDATE_SH}"
}

# ---------- ws + tls 模式 ----------

write_ws_v2ray_config() {
    local config
    if [[ "${PROTOCOL}" == "vless" ]]; then
        config=$(cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${INTERNAL_PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/${WS_PATH}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
)
    else
        config=$(cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${INTERNAL_PORT},
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0,
            "email": "user@${DOMAIN}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/${WS_PATH}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
)
    fi

    # 服务以 nobody 运行, 配置需可读: root:nogroup 640 (不放 world)
    echo "${config}" > "${WS_CONF}"
    chmod 640 "${WS_CONF}"
    chgrp nogroup "${WS_CONF}" 2>/dev/null || chgrp nobody "${WS_CONF}" 2>/dev/null || true
}

write_ws_nginx_config() {
    # 每次安装都覆盖本节点的 nginx 配置;不动其他站点配置
    # 共存场景 (宝塔/已有网站占用 80/443): 不写 80 重定向与 80 监听, 只在 443 server_name 上追加代理路径
    # 443 冲突场景: REALITY 先装且占用 443 时, nginx 无法绑定 443 (nginx -t 却不报错, 静默失效),
    # 因此 ws 改用独立 TLS 端口 (WS_PORT), 分享链接同步使用该端口
    local listen_port=443
    if [[ -n "${WS_PORT:-}" ]]; then
        listen_port="${WS_PORT}"
    fi

    local http_block=""
    if [[ "${NGINX_ENV}" == "none" && "${listen_port}" == "443" ]]; then
        http_block="server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}"
    fi

    # http2 指令: nginx >= 1.25.1 用 "http2 on", 旧版用 "listen ... http2"
    local http2_line1="listen ${listen_port} ssl http2;"
    local http2_line2="listen [::]:${listen_port} ssl http2;"
    if "${NGINX_BIN}" -v 2>&1 | grep -qE "nginx/(1\.2[5-9]|1\.[3-9][0-9]|[2-9]\.)" \
        || "${NGINX_BIN}" -v 2>&1 | grep -qE "nginx/1\.25\.[1-9]"; then
        http2_line1="listen ${listen_port} ssl;"
        http2_line2="listen [::]:${listen_port};
    http2 on;"
    fi

    cat > "${WS_NGINX_CONF}" <<EOF
${http_block}
server {
    ${http2_line1}
    ${http2_line2}
    server_name ${DOMAIN};

    ssl_certificate     ${CRT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    root  ${WS_WWW_ROOT};
    index index.html;

    # 证书续签 (acme.sh webroot) 验证目录
    location ^~ /.well-known/acme-challenge/ {
        root ${WS_WWW_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    # WebSocket 代理: 路径与客户端配置保持一致
    location ^~ /${WS_PATH} {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

    if command -v nginx >/dev/null 2>&1 && [[ "${NGINX_ENV}" != "btpanel" ]]; then
        if ! nginx -t >/dev/null 2>&1; then
            log_error "nginx 配置测试失败:"
            nginx -t
            exit 1
        fi
    fi
}

write_ws_service() {
    detect_nobody_group
    cat > "/etc/systemd/system/${WS_SERVICE}.service" <<EOF
[Unit]
Description=V2Ray (ws+tls via nginx)
After=network.target nss-lookup.target

[Service]
User=nobody
Group=${NOBODY_GROUP}
ExecStart=/usr/local/bin/v2ray run -config ${WS_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${WS_SERVICE}" >/dev/null 2>&1
}

do_install_ws() {
    echo
    if [[ -n "${DOMAIN}" ]]; then
        log_info "使用预设域名 (环境变量 DOMAIN): ${DOMAIN}"
    else
        log_confirm "请输入你的域名 (例如 www.example.com,必须已解析 A 记录到本机):"
        read -rp "域名: " DOMAIN
    fi
    DOMAIN="${DOMAIN//[$'\r\n']/}"
    DOMAIN="${DOMAIN,,}"
    if [[ -z "${DOMAIN}" ]] || ! check_domain "${DOMAIN}"; then
        log_error "域名校验未通过。"
        exit 1
    fi

    # 探测现有 Nginx 环境 (宝塔/发行版/全新), 并做域名占用防误伤检查
    detect_nginx_env
    check_domain_conflict "${DOMAIN}"

    create_webroot
    ensure_v2ray
    issue_certificate

    UUID="$(gen_uuid)"
    INTERNAL_PORT="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
    record_port "${INTERNAL_PORT}"
    WS_PATH="$(gen_random 16)"
    CLIENT_REMARK="${DOMAIN}-${PROTOCOL}-ws"

    # 443 端口冲突检测: 若 443 已被占用且占用者是本脚本的 REALITY (xray),
    # nginx 将无法绑定 443 (静默失效), ws 改用独立 TLS 端口
    WS_PORT=443
    if ss -lnt 2>/dev/null | awk '{print $NF}' | grep -q "xray" || ss -lnp 2>/dev/null | grep ":443 " | grep -q "xray"; then
        if ! pick_port "ws+tls (443 已被 REALITY 占用, 需独立端口)" 8443; then
            log_info "已取消 ws 安装。"
            return 1
        fi
        WS_PORT="${PICK_PORT_RESULT}"
        record_port "${WS_PORT}"
        log_warn "检测到 443 端口已被 xray (REALITY 模式) 占用,ws 将监听独立端口 ${WS_PORT}。"
        log_warn "请确保防火墙/安全组放行 ${WS_PORT}/tcp。"
    elif ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]443$'; then
        # 443 被其他进程占用 (如已有 nginx/宝塔): nginx 已在 443 服务, vhost 直接并入, 无需换端口
        WS_PORT=443
    fi

    write_ws_v2ray_config
    write_ws_nginx_config
    write_ws_service
    write_ssl_update_script
    build_share_link
    open_firewall

    log_info "重启服务..."
    if ! validate_core_config /usr/local/bin/v2ray "${WS_CONF}"; then
        exit 1
    fi
    systemctl restart "${WS_SERVICE}"
    nginx_check_reload
    sleep 1

    if ! systemctl is-active --quiet "${WS_SERVICE}"; then
        log_error "${WS_SERVICE} 服务未正常运行:"
        journalctl -u "${WS_SERVICE}" --no-pager -n 20
        exit 1
    fi
    if [[ "${NGINX_ENV}" == "distro" ]] && ! systemctl is-active --quiet nginx; then
        log_error "nginx 服务未正常运行:"
        journalctl -u nginx --no-pager -n 20
        exit 1
    fi
    # 端口监听终验: v2ray 内部端口 + nginx 对外端口都必须真的在监听
    if ! verify_port_listening "${INTERNAL_PORT}"; then
        journalctl -u "${WS_SERVICE}" --no-pager -n 20
        exit 1
    fi
    if ! verify_port_listening "${WS_PORT}"; then
        log_error "nginx 未监听对外端口 ${WS_PORT} (配置可能被其他站点抢占)。"
        exit 1
    fi

    show_mode_info
    if [[ "${NGINX_ENV}" == "btpanel" ]]; then
        log_confirm "宝塔环境: 站点配置已写入 ${WS_NGINX_CONF},可在宝塔面板正常管理原有网站。"
    fi
    log_confirm "ws+tls 安装完成。"
}

# ---------- xhttp + tls 模式 (Xray 直接监听 TLS, 独立端口, 不依赖 Nginx) ----------
# 传输用 xhttp (Xray 官方对 h2 的继任者)。alpn 锁 h2: xhttp 跑在 HTTP/2 之上。

write_xhttp_v2ray_config() {
    local tls_settings='"tlsSettings": {
          "alpn": ["h2"],
          "certificates": [
            {
              "certificateFile": "'"${CRT_FILE}"'",
              "keyFile": "'"${KEY_FILE}"'"
            }
          ]
        }'

    local protocol_block
    if [[ "${PROTOCOL}" == "vless" ]]; then
        protocol_block="\"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"${UUID}\",
            \"level\": 0
          }
        ],
        \"decryption\": \"none\"
      }"
    else
        protocol_block="\"protocol\": \"vmess\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"${UUID}\",
            \"alterId\": 0,
            \"email\": \"user@${DOMAIN}\"
          }
        ]
      }"
    fi

    local config
    config=$(cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${XHTTP_PORT},
      "listen": "0.0.0.0",
      ${protocol_block},
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "path": "/${WS_PATH}"
        },
        ${tls_settings}
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
)

    # 服务以 nobody 运行, 配置需可读: root:nogroup 640 (不放 world)
    echo "${config}" > "${XHTTP_CONF}"
    chmod 640 "${XHTTP_CONF}"
    chgrp nogroup "${XHTTP_CONF}" 2>/dev/null || chgrp nobody "${XHTTP_CONF}" 2>/dev/null || true
}

write_xhttp_service() {
    detect_nobody_group
    cat > "/etc/systemd/system/${XHTTP_SERVICE}.service" <<EOF
[Unit]
Description=Xray (xhttp+tls direct)
After=network.target nss-lookup.target

[Service]
User=nobody
Group=${NOBODY_GROUP}
# XHTTP_PORT 可能为 443 (<1024 特权端口), 非 443 时该 capability 无害
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/xray run -config ${XHTTP_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${XHTTP_SERVICE}" >/dev/null 2>&1
}

do_install_xhttp() {
    echo
    if [[ -n "${DOMAIN}" ]]; then
        log_info "使用预设域名 (环境变量 DOMAIN): ${DOMAIN}"
    else
        log_confirm "请输入你的域名 (xhttp 需要 TLS 证书,必须已解析 A 记录到本机):"
        read -rp "域名: " DOMAIN
    fi
    DOMAIN="${DOMAIN//[$'\r\n']/}"
    DOMAIN="${DOMAIN,,}"
    if [[ -z "${DOMAIN}" ]] || ! check_domain "${DOMAIN}"; then
        log_error "域名校验未通过。"
        exit 1
    fi

    # xhttp 需要证书;若还没有,先探测 Nginx 环境、建伪装站并申请
    detect_nginx_env
    check_domain_conflict "${DOMAIN}"
    create_webroot
    # xhttp 传输只有 Xray 核心支持 (v2fly 无此传输), 不用 ensure_v2ray
    ensure_xray
    ensure_xray_geo_data
    issue_certificate

    UUID="$(gen_uuid)"
    if ! pick_port "xhttp+tls" 8443; then
        log_info "已取消 xhttp 安装。"
        return 1
    fi
    XHTTP_PORT="${PICK_PORT_RESULT}"
    record_port "${XHTTP_PORT}"
    WS_PATH="$(gen_random 12)"
    CLIENT_REMARK="${DOMAIN}-${PROTOCOL}-xhttp"

    write_xhttp_v2ray_config
    write_xhttp_service
    write_ssl_update_script
    build_share_link
    open_firewall

    log_info "重启服务..."
    if ! validate_core_config /usr/local/bin/xray "${XHTTP_CONF}"; then
        exit 1
    fi
    systemctl restart "${XHTTP_SERVICE}"
    sleep 1

    if ! systemctl is-active --quiet "${XHTTP_SERVICE}"; then
        log_error "${XHTTP_SERVICE} 服务未正常运行:"
        journalctl -u "${XHTTP_SERVICE}" --no-pager -n 20
        exit 1
    fi
    if ! verify_port_listening "${XHTTP_PORT}"; then
        journalctl -u "${XHTTP_SERVICE}" --no-pager -n 20
        exit 1
    fi

    show_mode_info
    show_xhttp_client_notice
    log_confirm "xhttp+tls 安装完成 (端口: ${XHTTP_PORT},请在防火墙/安全组放行)。"
}

# ---------- socks5 模式 (V2Ray socks 入站, 无需域名/证书) ----------

write_socks_config() {
    local config
    config=$(cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${SOCKS_PORT},
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "${SOCKS_USER}",
            "pass": "${SOCKS_PASS}"
          }
        ],
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
)

    # 服务以 nobody 运行, 配置需可读: root:nogroup 640 (不放 world)
    echo "${config}" > "${SOCKS_CONF}"
    chmod 640 "${SOCKS_CONF}"
    chgrp nogroup "${SOCKS_CONF}" 2>/dev/null || chgrp nobody "${SOCKS_CONF}" 2>/dev/null || true
}

write_socks_service() {
    detect_nobody_group
    cat > "/etc/systemd/system/${SOCKS_SERVICE}.service" <<EOF
[Unit]
Description=V2Ray (socks5)
After=network.target nss-lookup.target

[Service]
User=nobody
Group=${NOBODY_GROUP}
ExecStart=/usr/local/bin/v2ray run -config ${SOCKS_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SOCKS_SERVICE}" >/dev/null 2>&1
}

do_install_socks() {
    ensure_v2ray

    if ! pick_port "socks5" 10808; then
        log_info "已取消 socks5 安装。"
        return 1
    fi
    SOCKS_PORT="${PICK_PORT_RESULT}"
    record_port "${SOCKS_PORT}"
    SOCKS_USER="$(gen_random 8)"
    SOCKS_PASS="$(gen_random 16)"
    CLIENT_REMARK="socks5-$(get_public_ip && echo "${PUBLIC_IP:-server}")"
    CLIENT_REMARK="${CLIENT_REMARK//[$'\r\n']/}"

    write_socks_config
    write_socks_service
    build_share_link
    open_firewall

    log_info "重启服务..."
    if ! validate_core_config /usr/local/bin/v2ray "${SOCKS_CONF}"; then
        exit 1
    fi
    systemctl restart "${SOCKS_SERVICE}"
    sleep 1

    if ! systemctl is-active --quiet "${SOCKS_SERVICE}"; then
        log_error "${SOCKS_SERVICE} 服务未正常运行:"
        journalctl -u "${SOCKS_SERVICE}" --no-pager -n 20
        exit 1
    fi
    if ! verify_port_listening "${SOCKS_PORT}"; then
        journalctl -u "${SOCKS_SERVICE}" --no-pager -n 20
        exit 1
    fi

    show_mode_info
    log_confirm "socks5 安装完成 (端口: ${SOCKS_PORT},请在防火墙/安全组放行)。"
    log_warn "socks5 为明文代理,请务必使用随机生成的强密码,不要改为弱密码对外提供服务。"
}

# ---------- vless + REALITY 模式 (Xray core, 抗封锁首选, 无需域名/证书) ----------

# 候选目标站按地区分组:格式 "站点:端口|地区" (地区用于按 VPS 位置智能排序)
# 选站原则: 大厂自有域名、支持 TLS1.3+H2、非 CDN 共享域、在当地访问质量好,
#           且必须"大陆可正常访问" —— 被墙站作 SNI 会触发 GFW 的 SNI 级回程阻断 (实战教训)
# 每地区 3 个, 全部经真实探测 (TLS1.3+H2) 与 GFW 列表双重校验 (2026-10)
REALITY_DEST_POOL=(
    # 香港 (大陆可达; hkjc 实战曾触发 SNI 回程阻断, 已移除)
    "www.octopus.com.hk:443|香港"
    "www.cathaypacific.com:443|香港"
    "www.hkex.com.hk:443|香港"
    # 台湾 (大陆可达; 台湾金融/媒体站多无 H2 或被墙, 用科技大厂)
    "www.tsmc.com:443|台湾"
    "www.mediatek.com:443|台湾"
    "www.asus.com:443|台湾"
    # 新加坡
    "www.singtel.com:443|新加坡"
    "www.dbs.com:443|新加坡"
    "www.grab.com:443|新加坡"
    # 日本
    "www.rakuten.co.jp:443|日本"
    "www.sony.com:443|日本"
    "www.nintendo.com:443|日本"
    # 韩国
    "www.samsung.com:443|韩国"
    "www.hyundai.com:443|韩国"
    "www.lg.com:443|韩国"
    # 美国 (大陆可达, 推荐优先)
    "www.tesla.com:443|美国"
    # 不用 www.microsoft.com: Xray 26.x 对 serverNames 含 apple/icloud/microsoft
    # 的目标站直接告警 "will increase the likelihood of your server's IP being
    # blocked by the GFW" (infra/conf/transport_security.go), 属上游明确点名的
    # 高风险伪装目标, 因此从候选池移除, 用 adobe 补位。
    "www.adobe.com:443|美国"
    "www.nvidia.com:443|美国"
    "www.cloudflare.com:443|美国"
    "www.intel.com:443|美国"
    # 欧洲
    "www.bmw.de:443|德国"
    "www.siemens.com:443|德国"
    "www.airbus.com:443|法国"
    "www.ns.nl:443|荷兰"
    "www.rolls-roycemotorcars.com:443|英国"
)

# 每地区补充候选 (主要地区凑满 3 个以上; 全部经 TLS1.3+H2 与 GFW 列表校验)
# 美国/德国/日本已有 >=3, 韩国补 lge 已在上方; 此处为各地区第 4-5 备选 (可选)
REALITY_EXTRA_POOL=(
    "www.acer.com:443|台湾"
    "www.gigabyte.com:443|台湾"
    "www.intel.com:443|美国"
)
REALITY_DEST_POOL+=("${REALITY_EXTRA_POOL[@]}")

# 已知被墙/大陆不可达站点 (从候选池移除, 仅作参考说明):
#   www.hk01.com / www.chinatimes.com / www.yahoo.co.jp / www.naver.com /
#   www.lovelive-anime.jp / www.bbc.co.uk —— 实战验证: 作 SNI 会触发 GFW 按
#   ClientHello 中的 SNI 选择性阻断回程, 节点表现为延迟 -1 (2026-10 真实案例)

# 检查域名是否在 GFW 封锁列表 (Loyalsoldier gfw.txt)
# 匹配: 精确域名 + 其父域在列表 (如 gfw.txt 有 "yahoo.com" 时, xxx.yahoo.com 视为命中)
# 返回 0 = 命中 (大陆不可达倾向, 应降权), 1 = 不在或检测失败
check_gfw_list() {
    local domain="$1"
    local base="${domain#www.}"
    local list_file="${V2RAY_CONF_DIR}/gfw_list.txt"
    # 列表缓存 7 天
    if [[ ! -s "${list_file}" ]] || [[ $(find "${list_file}" -mtime +7 2>/dev/null | wc -l) -gt 0 ]]; then
        mkdir -p "${V2RAY_CONF_DIR}"
        curl -sL --max-time 30 -o "${list_file}" \
            "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt" 2>/dev/null || return 1
    fi
    [[ -s "${list_file}" ]] || return 1
    # 逐级父域检查: a.b.c -> b.c -> c
    local parts rest
    rest="${base}"
    while [[ "${rest}" == *.* ]]; do
        if grep -qE "^${rest}$|^\.${rest}$" "${list_file}" 2>/dev/null; then
            return 0
        fi
        rest="${rest#*.}"
    done
    return 1
}

# 获取 VPS 所在地区 (基于时区, 无外部依赖; 失败返回空)
detect_vps_region() {
    # 三级兜底: timedatectl show (systemd 220+) / /etc/timezone (Debian 系) /
    # /etc/localtime 符号链接 (RHEL 系 CentOS 7 无前两者)
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null)" || tz=""
    [[ -z "${tz}" ]] && tz="$(cat /etc/timezone 2>/dev/null)" || true
    [[ -z "${tz}" ]] && tz="$(readlink /etc/localtime 2>/dev/null | sed 's|^.*zoneinfo/||')" || true
    case "${tz}" in
        Asia/Hong_Kong|Asia/Macau)              echo "香港" ;;
        Asia/Taipei)                            echo "台湾" ;;
        Asia/Singapore)                         echo "新加坡" ;;
        Asia/Tokyo)                             echo "日本" ;;
        Asia/Seoul)                             echo "韩国" ;;
        America/New_York|America/Chicago|America/Denver|America/Los_Angeles|America/Phoenix) echo "美国" ;;
        Europe/Berlin|Europe/Zurich|Europe/Vienna)  echo "德国" ;;
        Europe/Paris|Europe/Brussels|Europe/Amsterdam) echo "法国" ;;
        Europe/Amsterdam)                       echo "荷兰" ;;
        Europe/London|Europe/Dublin)            echo "英国" ;;
        *)                                      echo "" ;;
    esac
}

# REALITY 目标站交互选择:
#   1..N  从探测通过的候选站中挑选 (按实测延迟升序, 列表带延迟)
#   c     自定义输入任意域名:port (校验 TLS1.3/H2 达标才接受, 不达标可重输)
#   直接回车 = 默认第一个 (延迟最低)
# 参数: $1 = 可用候选数组名 (nameref, 元素格式 "dest|延迟ms")
select_reality_dest_interactive() {
    local -n _ok="$1"
    echo
    echo "请选择 REALITY 伪装目标站 (探测通过 $((${#_ok[@]})) 个, 按延迟排序):"
    local i
    for (( i=0; i<${#_ok[@]}; i++ )); do
        echo "  $((i+1)). ${_ok[$i]%%|*}  (${_ok[$i]##*|}ms)"
    done
    echo "  c. 自定义其他域名 (自动校验 TLS1.3/H2, 达标才接受)"
    echo "  q. 返回上一级 / 放弃 (更换场景下原配置不动)"
    echo
    echo "提示: 优先选与 VPS 同地区、你平时常访问的大站, 伪装更自然。"
    while :; do
        read -rp "请输入编号 / c 自定义 / q 放弃 / 直接回车默认 [${_ok[0]%%|*}]: " pick || return 1
        case "${pick}" in
            q|Q)
                return 1
                ;;
            "")
                REALITY_DEST="${_ok[0]%%|*}"
                REALITY_SNI="${REALITY_DEST%%:*}"
                log_info "已选择默认目标站 ${REALITY_DEST}"
                return 0
                ;;
            c|C)
                local custom ok=0
                while :; do
                    read -rp "输入自定义目标站 (格式 域名:端口, 如 www.example.com:443): " custom || return 1
                    custom="${custom//[$'\r\n']/}"
                    custom="${custom,,}"
                    if ! echo "${custom}" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+:[0-9]+$'; then
                        log_error "格式不对,应为 域名:端口 (如 www.example.com:443)"
                        continue
                    fi
                    local cs="${custom%%:*}"
                    log_info "校验 ${custom} ..."
                    if check_reality_dest "${custom}" "${cs}"; then
                        log_info "  -> 校验通过,使用 ${custom}"
                        REALITY_DEST="${custom}"
                        REALITY_SNI="${cs}"
                        ok=1
                        break
                    else
                        log_error "  -> 校验未通过 (需支持 TLS 1.3 + H2, 且本机可达), 请换一个域名或重试。"
                    fi
                done
                [[ "${ok}" == "1" ]] && return 0
                ;;
            *)
                if [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#_ok[@]} )); then
                    REALITY_DEST="${_ok[$((pick-1))]%%|*}"
                    REALITY_SNI="${REALITY_DEST%%:*}"
                    log_info "已选择目标站 ${REALITY_DEST}"
                    return 0
                fi
                log_error "无效输入,请重试。"
                ;;
        esac
    done
}

do_install_reality() {
    ensure_xray

    # 端口: 443 空闲则用 443 (最优), 否则分配随机端口 (可与 ws 共存)
    # 注意: ss 检测必须独占判断, 不能与其他条件混合 (&&/|| 优先级坑)
    local port443_busy=0
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]443$' && port443_busy=1
    if [[ -f "${V2RAY_CONF_DIR}/used_ports.txt" ]] && grep -qw 443 "${V2RAY_CONF_DIR}/used_ports.txt" 2>/dev/null; then
        port443_busy=1
    fi
    if [[ "${port443_busy}" == "1" ]]; then
        if ! pick_port "REALITY (443 已被占用, 需独立端口)" 8443; then
            log_info "已取消 REALITY 安装。"
            return 1
        fi
        REALITY_PORT="${PICK_PORT_RESULT}"
        log_info "443 端口已被占用 (如 ws 模式的 Nginx),REALITY 使用独立端口 ${REALITY_PORT}。"
    else
        REALITY_PORT=443
        log_info "443 端口空闲,REALITY 将监听 443 (最优伪装效果)。"
    fi
    record_port "${REALITY_PORT}"

    # 探测候选池: 大陆可达性过滤 + TLS 探测 + 实测延迟排序 (数据驱动, 无地区预设)
    # 环境变量 REALITY_DEST="域名:端口" 可直接指定目标站 (跳过探测与选择, 仍做部署前终验)
    if [[ -n "${REALITY_DEST:-}" ]]; then
        REALITY_DEST="${REALITY_DEST//[$'\r\n']/}"
        REALITY_DEST="${REALITY_DEST,,}"
        REALITY_SNI="${REALITY_DEST%%:*}"
        REALITY_DEST_REALIZED=1
        log_info "使用环境变量指定的目标站: ${REALITY_DEST}"
    else
    local vps_region
    vps_region="$(detect_vps_region)"
    local sorted_pool=()
    local entry
    # 同地区的排前面 (仅作为探测顺序的初始参考, 最终以实测延迟排序)
    for entry in "${REALITY_DEST_POOL[@]}"; do
        [[ "${entry##*|}" == "${vps_region}" ]] && sorted_pool+=("${entry}")
    done
    for entry in "${REALITY_DEST_POOL[@]}"; do
        [[ "${entry##*|}" != "${vps_region}" ]] && sorted_pool+=("${entry}")
    done

    # GFW 列表检查: 一次下载, 全池复用; 在列表中的站移到尾部
    local pool_head=() pool_tail=()
    for entry in "${sorted_pool[@]}"; do
        local d="${entry%%|*}"
        if check_gfw_list "${d}"; then
            log_info "${d} 在 GFW 封锁列表内,降权 (作伪装站会被 SNI 阻断)。"
            pool_tail+=("${entry}")
        else
            pool_head+=("${entry}")
        fi
    done
    if (( ${#pool_tail[@]} > 0 )); then
        sorted_pool=("${pool_head[@]}" "${pool_tail[@]}")
    fi

    # TLS 探测 + 实测 TCP 延迟: 通过的记入 "dest|延迟ms", 之后按延迟升序排
    local ok_dests=()
    local probed=()
    for entry in "${sorted_pool[@]}"; do
        local d="${entry%%|*}"
        local region="${entry##*|}"
        local s="${d%%:*}"
        local dup=0
        local pd
        for pd in "${probed[@]}"; do [[ "${pd}" == "${d}" ]] && dup=1; done
        [[ "${dup}" == "1" ]] && continue
        probed+=("${d}")
        log_info "校验伪装目标站 ${d} (${region}) ..."
        if check_reality_dest "${d}" "${s}"; then
            # 实测 TCP 握手延迟 (毫秒, 取整)
            local ms
            ms=$( { TIMEFORMAT=%R; time timeout 5 bash -c "echo > /dev/tcp/${d%%:*}/${s}" 2>/dev/null; } 2>&1 )
            [[ -z "${ms}" ]] && ms=9999
            ms=$(awk -v t="${ms}" 'BEGIN{printf "%d", t*1000}')
            ok_dests+=("${d}|${ms}")
            log_info "  -> 可用 (TCP 延迟 ${ms}ms)"
        else
            log_info "  -> 不可用,跳过"
        fi
        # 最多探测通过 10 个即可
        (( ${#ok_dests[@]} >= 10 )) && break
    done

    if (( ${#ok_dests[@]} > 0 )); then
        # 按实测延迟升序排序 (稳定: 同延迟保持原序)
        ok_dests=($(printf '%s\n' "${ok_dests[@]}" | sort -t'|' -k2 -n))
        log_info "候选按实测延迟排序: ${ok_dests[0]%%|*} (${ok_dests[0]##*|}ms) 最快"
    fi
    fi   # end REALITY_DEST env override

    # 目标站选择: 交互模式列出可用候选让用户挑, 或自定义任意域名 (校验达标才接受);
    # 非交互模式 (stdin 非终端) 自动选延迟最低的候选
    # 注意: REALITY_DEST 环境变量已指定时跳过本段 (env 分支已完成赋值)
    if [[ -z "${REALITY_DEST_REALIZED:-}" ]]; then
        if [[ -t 0 ]]; then
            select_reality_dest_interactive ok_dests
        else
            if (( ${#ok_dests[@]} > 0 )); then
                REALITY_DEST="${ok_dests[0]%%|*}"
                REALITY_SNI="${REALITY_DEST%%:*}"
                log_info "非交互模式,自动选用延迟最低的 ${REALITY_DEST} (${ok_dests[0]##*|}ms)"
            else
                log_warn "所有预置目标站校验均未通过,使用 ${REALITY_DEST_POOL[0]%%|*} 兜底 (若后续连接异常请手动更换 dest/sni)。"
                REALITY_DEST="${REALITY_DEST_POOL[0]%%|*}"
                REALITY_SNI="${REALITY_DEST%%:*}"
            fi
        fi
    fi

    # 部署前终验: 选定/自定义的站再即时校验一次 (防探测与选择之间的状态变化)
    # 校验不通过时回退重选 (交互模式) 或自动换下一候选 (非交互), 全部失败才中止;
    # env 明确指定的站不通过则直接退出 (尊重用户明确意图, 不静默替换)
    if [[ -z "${REALITY_DEST_REALIZED:-}" ]]; then
        # 候选来自探测池 (交互选择或自动选站): 校验失败可回退重选
        while :; do
            log_info "部署前终验目标站 ${REALITY_DEST} ..."
            if check_reality_dest "${REALITY_DEST}" "${REALITY_SNI}"; then
                log_info "  -> 终验通过,开始部署。"
                break
            fi
            log_error "  -> 目标站 ${REALITY_DEST} 部署前校验未通过 (状态已变化)。"
            # 非交互模式: 从 ok_dests 中剔除失败项, 自动换下一个
            if [[ ! -t 0 ]] && (( ${#ok_dests[@]} > 0 )); then
                local remain=() od
                for od in "${ok_dests[@]}"; do
                    [[ "${od%%|*}" == "${REALITY_DEST}" ]] || remain+=("${od}")
                done
                ok_dests=("${remain[@]}")
                if (( ${#ok_dests[@]} > 0 )); then
                    REALITY_DEST="${ok_dests[0]%%|*}"
                    REALITY_SNI="${REALITY_DEST%%:*}"
                    log_info "自动切换到下一候选 ${REALITY_DEST} (${ok_dests[0]##*|}ms), 重新终验..."
                    continue
                fi
                # 候选耗尽: 交回用户自定义输入 (校验通过才接受, 输 q 放弃)
                while :; do
                    log_error "所有预置候选均未通过终验。"
                    read -rp "请手动输入自定义目标站 (格式 域名:端口, 如 www.example.com:443; 输入 q 放弃安装): " custom || exit 1
                    custom="${custom//[$'\r\n']/}"
                    custom="${custom,,}"
                    [[ "${custom}" == "q" || "${custom}" == "Q" ]] && { log_error "已放弃,本次安装中止。"; exit 1; }
                    if ! echo "${custom}" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+:[0-9]+$'; then
                        log_error "格式不对,应为 域名:端口"
                        continue
                    fi
                    REALITY_DEST="${custom}"
                    REALITY_SNI="${custom%%:*}"
                    log_info "校验自定义目标站 ${REALITY_DEST} ..."
                    if check_reality_dest "${REALITY_DEST}" "${REALITY_SNI}"; then
                        log_info "  -> 校验通过,开始部署。"
                        break 2
                    fi
                    log_error "  -> 校验未通过,请换一个域名或输 q 放弃。"
                done
                break
            fi
            # 交互模式: 回退重选
            if (( ${#ok_dests[@]} > 0 )); then
                # 把失败项从候选中剔除后再进选择菜单
                local remain2=() od2
                for od2 in "${ok_dests[@]}"; do
                    [[ "${od2%%|*}" == "${REALITY_DEST}" ]] || remain2+=("${od2}")
                done
                ok_dests=("${remain2[@]}")
            fi
            if (( ${#ok_dests[@]} == 0 )); then
                log_error "候选已全部尝试完毕且均未通过,本次安装中止。"
                exit 1
            fi
            log_confirm "请重新选择目标站:"
            select_reality_dest_interactive ok_dests || exit 1
        done
    else
        # env 明确指定: 不通过直接退出, 不静默替换
        log_info "部署前终验目标站 ${REALITY_DEST} (环境变量指定) ..."
        if ! check_reality_dest "${REALITY_DEST}" "${REALITY_SNI}"; then
            log_error "目标站 ${REALITY_DEST} 部署前校验未通过,本次安装中止。"
            log_confirm "可更换 REALITY_DEST 后重试,或不带环境变量运行以启用自动探测选站。"
            exit 1
        fi
        log_info "  -> 终验通过,开始部署。"
    fi

    # 密钥对与 shortId
    if ! gen_x25519; then
        log_error "生成 x25519 密钥对失败 (xray 命令不可用)。"
        exit 1
    fi
    REALITY_PUBKEY="${X25519_PUBKEY}"
    # shortId 必须是 0-16 位的偶数长度十六进制字符串
    REALITY_SID="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

    UUID="$(gen_uuid)"
    CLIENT_REMARK="${REALITY_SNI}-reality"

    write_reality_config
    write_reality_service
    build_share_link
    open_firewall

    log_info "重启服务..."
    if ! validate_core_config /usr/local/bin/xray "${REALITY_CONF}"; then
        exit 1
    fi
    systemctl restart "${REALITY_SERVICE}"
    sleep 1

    if ! systemctl is-active --quiet "${REALITY_SERVICE}"; then
        log_error "${REALITY_SERVICE} 服务未正常运行:"
        journalctl -u "${REALITY_SERVICE}" --no-pager -n 20
        exit 1
    fi
    if ! verify_port_listening "${REALITY_PORT}"; then
        journalctl -u "${REALITY_SERVICE}" --no-pager -n 20
        exit 1
    fi

    show_mode_info
    log_confirm "vless + REALITY 安装完成 (端口: ${REALITY_PORT},请在防火墙/安全组放行)。"
    log_confirm "REALITY 无需域名与证书,当前为抗封锁能力最强的模式。"
}

write_reality_config() {
    local config
    config=$(cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${REALITY_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${X25519_PRIVKEY}",
          "shortIds": [
            "${REALITY_SID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
)

    # 服务以 nobody 运行, 配置需可读: root:nogroup 640 (不放 world)
    echo "${config}" > "${REALITY_CONF}"
    chmod 640 "${REALITY_CONF}"
    chgrp nogroup "${REALITY_CONF}" 2>/dev/null || chgrp nobody "${REALITY_CONF}" 2>/dev/null || true
}

write_reality_service() {
    detect_nobody_group
    cat > "/etc/systemd/system/${REALITY_SERVICE}.service" <<EOF
[Unit]
Description=Xray (vless + reality)
After=network.target nss-lookup.target

[Service]
User=nobody
Group=${NOBODY_GROUP}
# REALITY_PORT 可能为 443 (<1024 特权端口), 非任意端口时该 capability 无害
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/xray run -config ${REALITY_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${REALITY_SERVICE}" >/dev/null 2>&1 || true
}

# ---------- 分享链接 (兼容最新版 v2rayN / v2rayNG) ----------

# 重建导出文件: 把传入的链接集合整体写入 URL_FILE (非追加),
# 供菜单 7 与菜单 10/11/12 变更完成后共用, 保证文件里永远只有最新链接
rebuild_url_file() {
    {
        local u
        for u in "$@"; do
            echo "${u}"
        done
    } > "${URL_FILE}"
}

# 从磁盘上的实际配置现场生成全部当前有效链接并重建导出文件 (do_show_info 的生成逻辑,
# 不依赖内存变量/历史记录)。菜单 10/11/12 改完配置后调用, 文件里不残留失效的旧链接。
rebuild_url_file_from_config() {
    local tmp_exported=() ex
    collect_current_urls tmp_exported
    # 工具格式行是菜单 7 专用展示, 不入导出文件
    local filtered=()
    for ex in "${tmp_exported[@]}"; do
        [[ "${ex}" == 工具格式* ]] && continue
        filtered+=("${ex}")
    done
    rebuild_url_file "${filtered[@]}"
}

url_encode() {
    local s="$1" out="" c
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "${c}" in
            [a-zA-Z0-9.~_-]) out+="${c}" ;;
            *) printf -v hex '%%%02X' "'${c}"; out+="${hex}" ;;
        esac
    done
    echo "${out}"
}

build_share_link() {
    if [[ "${MODE}" == "socks" ]]; then
        # socks 新格式 (v2rayN/v2rayNG 均支持): socks://base64(user:pass)@host:port#备注
        local cred b64cred host
        cred="${SOCKS_USER}:${SOCKS_PASS}"
        b64cred=$(printf '%s' "${cred}" | openssl base64 -A | tr -d '=')
        get_public_ip
        host="${PUBLIC_IP:-127.0.0.1}"
        SHARE_URL="socks://${b64cred}@${host}:${SOCKS_PORT}#$(url_encode "${CLIENT_REMARK}")"
        # 附加格式 1: IP:端口:用户:密码{备注} (部分代理工具的导入格式)
        SHARE_URL_PLAIN="${host}:${SOCKS_PORT}:${SOCKS_USER}:${SOCKS_PASS}{${CLIENT_REMARK}}(刷新URL)"
        # 附加格式 2: 带协议前缀 (部分工具要求 socks5:// 开头才识别)
        SHARE_URL_PLAIN2="socks5://${SOCKS_USER}:${SOCKS_PASS}@${host}:${SOCKS_PORT}#${CLIENT_REMARK}"
        return
    fi

    if [[ "${MODE}" == "reality" ]]; then
        # vless + REALITY 标准 URI (v2rayN/v2rayNG 均支持):
        # security=reality, pbk=公钥, sid=shortId, fp 模拟客户端指纹, spx=spiderX
        get_public_ip
        local host="${PUBLIC_IP:-127.0.0.1}"
        SHARE_URL="vless://${UUID}@${host}:${REALITY_PORT}?type=tcp&security=reality&pbk=${REALITY_PUBKEY}&sid=${REALITY_SID}&sni=${REALITY_SNI}&fp=chrome&flow=xtls-rprx-vision&encryption=none#$(url_encode "${CLIENT_REMARK}")"
        return
    fi

    if [[ "${MODE}" == "xhttp" ]]; then
        local port="${XHTTP_PORT}" net="xhttp"
    else
        local port="${WS_PORT:-443}" net="ws"
    fi

    if [[ "${PROTOCOL}" == "vless" ]]; then
        # vless 标准 URI: encryption=none; path URL 编码
        # xhttp 用 type=xhttp + mode=auto (两端 Xray 都认这个值), alpn=h2 与服务端
        # tlsSettings.alpn=["h2"] 对齐; mode 省略时服务端默认也是 auto, 写明更清晰
        local enc_path
        enc_path="$(url_encode "/${WS_PATH}")"
        if [[ "${net}" == "xhttp" ]]; then
            SHARE_URL="vless://${UUID}@${DOMAIN}:${port}?type=xhttp&security=tls&host=${DOMAIN}&path=${enc_path}&mode=auto&sni=${DOMAIN}&fp=chrome&encryption=none&alpn=h2#$(url_encode "${CLIENT_REMARK}")"
        else
            SHARE_URL="vless://${UUID}@${DOMAIN}:${port}?type=${net}&security=tls&host=${DOMAIN}&path=${enc_path}&sni=${DOMAIN}&fp=chrome&encryption=none#$(url_encode "${CLIENT_REMARK}")"
        fi
    else
        # vmess v2 JSON base64; aid=0 走 AEAD, 带 scy/sni/fp 字段
        local json
        # xhttp: net=xhttp + type=auto (vmess 的 type 字段承载 xhttp mode),
        # alpn=h2 与服务端对齐。vmess 的 type 字段语义随 net 变化, xhttp 下即 mode。
        local net_field="${net}"
        local mode_field="none"
        [[ "${net}" == "xhttp" ]] && mode_field="auto"
        json=$(cat <<EOF
{
  "v": "2",
  "ps": "${CLIENT_REMARK}",
  "add": "${DOMAIN}",
  "port": "${port}",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "${net_field}",
  "type": "${mode_field}",
  "host": "${DOMAIN}",
  "path": "/${WS_PATH}",
  "tls": "tls",
  "sni": "${DOMAIN}",
  "alpn": "$([[ "${net}" == "xhttp" ]] && echo h2)",
  "fp": "chrome"
}
EOF
)
        local b64
        b64=$(printf '%s' "${json}" | openssl base64 -A | tr -d '=')
        SHARE_URL="vmess://${b64}"
    fi
}

# ---------- 信息展示 ----------

# 分享链接二维码 (ANSI 终端直接渲染, qrencode 未装时静默跳过)
show_qr() {
    local url="$1"
    [[ -z "${url}" ]] && return 0
    command -v qrencode >/dev/null 2>&1 || return 0
    echo -e "${BLUE}客户端扫码导入:${PLAIN}"
    echo "${url}" | qrencode -t ANSIUTF8
}

# xhttp 模式的客户端支持提示。
# xhttp 由两个客户端在 2024-11 同期加入 (v2rayN 7.1.0 / v2rayNG 1.9.10), 之后一直保留;
# 而旧的 h2 传输已被 Xray 内核删除, 老客户端才需要这条提示。
# 凡输出 xhttp 节点链接的入口 (安装完成 / 菜单 7 / 菜单 12 重置) 都调用本函数。
show_xhttp_client_notice() {
    log_warn "xhttp 模式客户端支持提示:"
    log_warn "  - v2rayN 7.1.0+ / v2rayNG 1.9.10+ 可直接导入使用"
    log_warn "  - 更早的客户端不支持 xhttp 传输 (旧 h2 传输已被内核删除, 也无法使用)"
}

append_info() {
    local section="$1"
    # 同名段落已存在 (同模式重装) 时先删除旧段落, 避免菜单 7 出现重复/过期条目
    # 多个同名段落时循环删除直至清零
    if [[ -f "${INFO_FILE}" ]] && grep -q "^### ${section}$" "${INFO_FILE}"; then
        local tmp="${INFO_FILE}.dedup.$$"
        local dedup_body='
            $0 == s {skip=1; next}
            skip && /^### / {skip=0}
            skip && /^$/ {skip=0; next}
            !skip
        '
        while grep -q "^### ${section}$" "${INFO_FILE}"; do
            awk -v s="### ${section}" "${dedup_body}" "${INFO_FILE}" \
                | sed '/./,/^$/!d' > "${tmp}" && mv -f "${tmp}" "${INFO_FILE}"
        done
    fi
    {
        echo "### ${section}"
        echo "share_url=${SHARE_URL}"
        if [[ "${MODE}" == "socks" ]]; then
            echo "port=${SOCKS_PORT}"
            echo "socks_user=${SOCKS_USER}"
            echo "socks_pass=${SOCKS_PASS}"
        elif [[ "${MODE}" == "reality" ]]; then
            echo "address=${PUBLIC_IP:-127.0.0.1}"
            echo "port=${REALITY_PORT}"
            echo "uuid=${UUID}"
            echo "dest=${REALITY_DEST}"
            echo "sni=${REALITY_SNI}"
        elif [[ "${MODE}" == "xhttp" ]]; then
            echo "domain=${DOMAIN}"
            echo "port=${XHTTP_PORT}"
            echo "uuid=${UUID}"
            echo "path=/${WS_PATH}"
        else
            echo "domain=${DOMAIN}"
            echo "port=${WS_PORT:-443}"
            echo "uuid=${UUID}"
            echo "path=/${WS_PATH}"
        fi
        echo "installed_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo
    } >> "${INFO_FILE}"
    chmod 600 "${INFO_FILE}"
}

show_mode_info() {
    echo
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}   ${MODE} 安装成功,配置如下            ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e " 协议        : ${PROTOCOL:+${PROTOCOL} + }${MODE}"
    if [[ "${MODE}" == "reality" ]]; then
        get_public_ip
        echo -e " 地址        : ${PUBLIC_IP:-127.0.0.1}"
        echo -e " 端口        : ${REALITY_PORT}"
        echo -e " 用户 ID     : ${UUID}"
        echo -e " 流控        : xtls-rprx-vision"
        echo -e " 传输协议    : tcp + reality"
        echo -e " 伪装目标    : ${REALITY_DEST} (sni: ${REALITY_SNI})"
        echo -e " 公钥 pbk    : ${REALITY_PUBKEY}"
        echo -e " shortId sid : ${REALITY_SID}"
    elif [[ "${MODE}" != "socks" ]]; then
        echo -e " 域名        : ${DOMAIN}"
    fi
    echo -e " 端口        : $([[ "${MODE}" == "ws" ]] && echo "${WS_PORT:-443}" || { [[ "${MODE}" == "xhttp" ]] && echo "${XHTTP_PORT}" || echo "${SOCKS_PORT}"; })"
    if [[ "${MODE}" == "socks" ]]; then
        echo -e " 用户名      : ${SOCKS_USER}"
        echo -e " 密码        : ${SOCKS_PASS}"
    else
        echo -e " 用户 ID     : ${UUID}"
        if [[ "${PROTOCOL}" == "vmess" ]]; then
            echo -e " alterId     : 0 (AEAD)"
            echo -e " 加密方式    : auto"
        else
            echo -e " 加密        : none (vless)"
        fi
        echo -e " 传输协议    : ${MODE}"
        echo -e " 路径        : /${WS_PATH}"
        echo -e " TLS         : 开启 (sni: ${DOMAIN})"
        [[ "${MODE}" == "ws" ]] && echo -e " 伪装站点    : https://${DOMAIN}"
    fi
    echo -e " 分享链接    : ${SHARE_URL}"
    [[ -n "${SHARE_URL_PLAIN:-}" ]] && echo -e " 工具格式    : ${SHARE_URL_PLAIN}"
    [[ -n "${SHARE_URL_PLAIN2:-}" ]] && echo -e " 工具格式2   : ${SHARE_URL_PLAIN2}"
    echo -e "${GREEN}==========================================${PLAIN}"

    append_info "$([[ "${PROTOCOL}" ]] && echo "${PROTOCOL}+${MODE}" || echo "${MODE}")"

    # 导出文件整体重建 (非追加): 只含当前真实配置对应的链接, 已卸载模式的失效链接不入文件
    rebuild_url_file_from_config

    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${BLUE}客户端扫码导入:${PLAIN}"
        echo "${SHARE_URL}" | qrencode -t ANSIUTF8
    fi
}

# 从磁盘配置现场收集全部当前有效链接到传入的数组 (nameref)。
# 被 do_show_info 与 rebuild_url_file_from_config 共用; 展示行由 do_show_info 自行组织。
collect_current_urls() {
    local -n _urls_ref="$1"
    _urls_ref=()
    get_public_ip
    local p ip proto
    ip="${PUBLIC_IP:-127.0.0.1}"

    # --- REALITY: 全部参数在 config_reality.json ---
    if [[ -f "${REALITY_CONF}" ]]; then
        p="$(grep -o '"port": [0-9]*' "${REALITY_CONF}" | head -1 | grep -o '[0-9]*')"
        local r_uuid r_sni r_sid r_pbk r_priv
        r_uuid="$(grep -o '"id": "[^"]*"' "${REALITY_CONF}" | head -1 | cut -d'"' -f4)"
        r_sni="$(grep -A1 '"serverNames"' "${REALITY_CONF}" | grep -o '"[^"]*"' | tr -d '"' | sed -n 2p)"
        r_sid="$(grep -A1 '"shortIds"' "${REALITY_CONF}" | grep -o '"[0-9a-f]*"' | tr -d '"' | head -1)"
        r_priv="$(grep -o '"privateKey": "[^"]*"' "${REALITY_CONF}" | cut -d'"' -f4)"
        r_pbk="$(xray x25519 -i "${r_priv}" 2>/dev/null | awk '/Public key|Password/{print $NF}')"
        # 私钥推导失败才回退沿用历史链接的 pbk (此时提示可能不可用)
        if [[ -z "${r_pbk}" ]]; then
            r_pbk="$(grep reality "${URL_FILE}" 2>/dev/null | tail -1 | grep -o 'pbk=[^&]*' | cut -d= -f2)"
        fi
        _urls_ref+=("vless://${r_uuid}@${ip}:${p}?type=tcp&security=reality&pbk=${r_pbk}&sid=${r_sid}&sni=${r_sni}&fp=chrome&flow=xtls-rprx-vision&encryption=none#${r_sni}-reality")
    fi

    # --- socks5: 全部参数在 config_socks.json ---
    if [[ -f "${SOCKS_CONF}" ]]; then
        p="$(grep -o '"port": [0-9]*' "${SOCKS_CONF}" | head -1 | grep -o '[0-9]*')"
        local s_user s_pass s_b64
        s_user="$(grep -o '"user": "[^"]*"' "${SOCKS_CONF}" | cut -d'"' -f4)"
        s_pass="$(grep -o '"pass": "[^"]*"' "${SOCKS_CONF}" | cut -d'"' -f4)"
        s_b64=$(printf '%s' "${s_user}:${s_pass}" | openssl base64 -A | tr -d '=')
        _urls_ref+=("socks://${s_b64}@${ip}:${p}#socks5-${ip}")
        # 菜单 7 展示用工具格式 (与安装时 SHARE_URL_PLAIN/PLAIN2 一致):
        # 前缀 "工具格式:" 供 do_show_info 识别展示, rebuild 时会剔除带该前缀的行
        _urls_ref+=("工具格式:${ip}:${p}:${s_user}:${s_pass}{socks5-${ip}}(刷新URL)")
        _urls_ref+=("工具格式2:socks5://${s_user}:${s_pass}@${ip}:${p}#socks5-${ip}")
    fi

    # --- ws / xhttp: 域名从 nginx server_name 或证书 SAN 推导, 端口/uuid/path 从各自配置 ---
    # 同时识别旧版 h2 配置 (未跑菜单 15 迁移的机器), 保证菜单 7 反映真实安装状态
    local m conf svc
    for m in ws xhttp h2; do
        if [[ "${m}" == "ws" ]]; then
            conf="${WS_CONF}"; svc="${WS_SERVICE}"
        elif [[ "${m}" == "xhttp" ]]; then
            conf="${XHTTP_CONF}"; svc="${XHTTP_SERVICE}"
        else
            conf="${LEGACY_H2_CONF}"; svc="${LEGACY_H2_SERVICE}"
        fi
        [[ -f "${conf}" ]] || continue
        local m_uuid m_path m_port m_domain m_proto
        m_uuid="$(grep -o '"id": "[^"]*"' "${conf}" | head -1 | cut -d'"' -f4)"
        m_path="$(grep -o '"path": "/[^"]*"' "${conf}" | head -1 | cut -d'"' -f4)"
        m_path="${m_path#/}"
        if [[ "${m}" == "ws" ]]; then
            # 客户端连接端口是 nginx 监听端口 (443 并入式部署时内部端口 ≠ 对外端口)
            if [[ -f "${WS_NGINX_CONF}" ]]; then
                m_port="$(grep -m1 -oE "listen [0-9]+ ssl" "${WS_NGINX_CONF}" | grep -o "[0-9]*")"
                m_port="${m_port:-443}"
                # 域名: 同一 vhost 的 server_name (首个, 排除 _)
                m_domain="$(grep -m1 "server_name" "${WS_NGINX_CONF}" | awk '{print $2}' | tr -d ';')"
            else
                m_port="443"; m_domain=""
            fi
        else
            m_port="$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')"
            m_domain=""
        fi
        if [[ -z "${m_domain}" ]]; then
            # 域名兜底: 证书 SAN (xhttp/旧 h2 或 nginx conf 缺 server_name 时)
            # -ext 需 OpenSSL 1.1.1+; 1.1.0 (Ubuntu 18.04) 报 "Unknown digest ext",
            # 此时退回 -text 解析全文再提取 DNS: (输出更啰嗦但通用)
            m_domain="$(openssl x509 -in "${CRT_FILE}" -noout -ext subjectAltName 2>/dev/null \
                | grep -o 'DNS:[^,]*' | head -1 | cut -d: -f2)"
            if [[ -z "${m_domain}" ]]; then
                m_domain="$(openssl x509 -in "${CRT_FILE}" -noout -text 2>/dev/null \
                    | grep -A1 'Subject Alternative Name' | grep -o 'DNS:[^,]*' | head -1 | cut -d: -f2)"
            fi
        fi
        [[ -n "${m_domain}" && -n "${m_uuid}" ]] || continue
        local enc_path m_url
        enc_path="$(url_encode "/${m_path}")"
        m_proto="$(grep -o '"protocol": "[^"]*"' "${conf}" | head -1 | cut -d'"' -f4)"
        # 客户端侧网络名: xhttp 直接用; 旧 h2 配置沿用 http (历史上唯一能被旧客户端识别的写法)
        local net_field="${m}"
        local xhttp_mode_json="none"
        if [[ "${net_field}" == "h2" ]]; then
            net_field="http"
        elif [[ "${net_field}" == "xhttp" ]]; then
            xhttp_mode_json="auto"
        fi
        if [[ "${m_proto}" == "vmess" ]]; then
            local j b64
            j=$(cat <<EOF
{
  "v": "2",
  "ps": "${m_domain}-${m_proto}-${m}",
  "add": "${m_domain}",
  "port": "${m_port}",
  "id": "${m_uuid}",
  "aid": "0",
  "scy": "auto",
  "net": "${net_field}",
  "type": "${xhttp_mode_json}",
  "host": "${m_domain}",
  "path": "/${m_path}",
  "tls": "tls",
  "sni": "${m_domain}",
  "alpn": "$([[ "${m}" == "h2" || "${m}" == "xhttp" ]] && echo h2)",
  "fp": "chrome"
}
EOF
)
            b64=$(printf '%s' "${j}" | openssl base64 -A | tr -d '=')
            m_url="vmess://${b64}"
        else
            local xhttp_extra=""
            [[ "${m}" == "xhttp" ]] && xhttp_extra="&mode=auto&alpn=h2"
            [[ "${m}" == "h2" ]] && xhttp_extra="&alpn=h2"
            m_url="vless://${m_uuid}@${m_domain}:${m_port}?type=${net_field}&security=tls&host=${m_domain}&path=${enc_path}${xhttp_extra}&sni=${m_domain}&fp=chrome&encryption=none#${m_domain}-${m_proto}-${m}"
        fi
        _urls_ref+=("${m_url}")
    done
}

do_show_info() {
    local any=0
    local out_lines=() exported=()
    # 全部参数从实际配置文件现场提取 (不信任 INFO_FILE/URL_FILE 历史记录:
    # 手工改过配置、或任何历史 bug 都可能让记录陈旧), 每次运行重建导出文件,
    # 保证导出的链接与磁盘上的真实配置一致; 链接生成复用 collect_current_urls,
    # 展示信息在此另行组织 (含工具格式等仅展示用行)
    collect_current_urls exported
    [[ ${#exported[@]} -gt 0 ]] && any=1

    if [[ "${any}" == "0" ]]; then
        log_warn "未找到任何已安装模式的配置。"
        return
    fi

    # 提示判定看配置文件是否存在, 不看链接文本: vmess 链接是 base64,
    # 无法用 "net": "xhttp" 之类的明文特征匹配 (vless 能匹配, vmess 不能)
    local ol
    local has_xhttp=0
    [[ -f "${XHTTP_CONF}" ]] && has_xhttp=1
    for ol in "${exported[@]}"; do
        if [[ "${ol}" == 工具格式* ]]; then
            # socks 工具格式行 (菜单 7 专用展示, 不入导出文件)
            out_lines+=(" ${ol}")
            continue
        fi
        out_lines+=(" 分享链接: ${ol}")
    done
    [[ "${has_xhttp}" == "1" ]] && show_xhttp_client_notice

    clear
    echo -e "${GREEN}================ 已安装节点 (实时读取配置) ================${PLAIN}"
    for ol in "${out_lines[@]}"; do
        echo -e "${ol}"
    done
    echo -e "${GREEN}=============================================${PLAIN}"
    # 导出文件每次重建 (而非追加): 只含当前真实配置对应的链接, 旧链接不入文件;
    # 工具格式行是展示辅助, 过滤掉不入文件
    rebuild_url_file $(printf '%s\n' "${exported[@]}" | grep -v '^工具格式' || true)
    log_confirm "全部分享链接已导出到: ${URL_FILE} (每次运行重建, 保证与当前配置一致)"
}

# ---------- 卸载 ----------

do_uninstall() {
    check_root
    echo "当前已安装的服务:"
    for svc in "${WS_SERVICE}" "${XHTTP_SERVICE}" "${SOCKS_SERVICE}" "${REALITY_SERVICE}" "${LEGACY_H2_SERVICE}"; do
        if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            local state="未运行"
            systemctl is-active --quiet "${svc}" && state="运行中"
            echo "  - ${svc} (${state})"
        fi
    done
    echo
    echo "请选择要卸载的模式:"
    echo "  1. ws+tls (v2ray-ws + nginx 配置)"
    echo "  2. xhttp+tls (xray-xhttp, 旧版为 v2ray-h2)"
    echo "  3. socks5 (v2ray-socks)"
    echo "  4. vless+REALITY (xray-reality)"
    echo "  5. 全部卸载"
    echo "  0. 返回主菜单"
    read -rp "请选择: " choice

    case "${choice}" in
        1)
            stop_service_sync "${WS_SERVICE}" v2ray
            systemctl disable "${WS_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${WS_SERVICE}.service" "${WS_CONF}"
            # 兼容宝塔与发行版: 两个可能位置都尝试清理 (文件不存在则无操作)
            rm -f "${WS_NGINX_CONF}" "/etc/nginx/conf.d/v2ray-ws-tls.conf" "${BT_NGINX_VHOST_DIR}/v2ray-ws-tls.conf"
            if [[ "${NGINX_ENV}" == "btpanel" && -x "${NGINX_BIN}" ]]; then
                "${NGINX_BIN}" -t >/dev/null 2>&1 && "${NGINX_BIN}" -s reload
            elif command -v nginx >/dev/null 2>&1; then
                nginx -t >/dev/null 2>&1 && systemctl reload nginx
            fi
            sed -i '/### vmess+ws/,/^$/d;/### vless+ws/,/^$/d' "${INFO_FILE}" 2>/dev/null
            ;;
        2)
            # 新旧两套都要清: xhttp 模式 (xray-xhttp) 与未迁移的旧 h2 (v2ray-h2)
            stop_service_sync "${XHTTP_SERVICE}" xray
            systemctl disable "${XHTTP_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${XHTTP_SERVICE}.service" "${XHTTP_CONF}"
            if [[ -f "/etc/systemd/system/${LEGACY_H2_SERVICE}.service" || -f "${LEGACY_H2_CONF}" ]]; then
                stop_service_sync "${LEGACY_H2_SERVICE}" v2ray
                systemctl disable "${LEGACY_H2_SERVICE}" >/dev/null 2>&1
                rm -f "/etc/systemd/system/${LEGACY_H2_SERVICE}.service" "${LEGACY_H2_CONF}"
            fi
            sed -i '/### vmess+h2/,/^$/d;/### vless+h2/,/^$/d;/### vmess+xhttp/,/^$/d;/### vless+xhttp/,/^$/d' "${INFO_FILE}" 2>/dev/null
            ;;
        3)
            stop_service_sync "${SOCKS_SERVICE}" v2ray
            systemctl disable "${SOCKS_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${SOCKS_SERVICE}.service" "${SOCKS_CONF}"
            sed -i '/### socks$/,/^$/d' "${INFO_FILE}" 2>/dev/null
            ;;
        4)
            stop_service_sync "${REALITY_SERVICE}" xray
            systemctl disable "${REALITY_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${REALITY_SERVICE}.service" "${REALITY_CONF}"
            sed -i '/### vless+reality$/,/^$/d' "${INFO_FILE}" 2>/dev/null
            ;;
        5)
            stop_service_sync "${WS_SERVICE}" v2ray
            stop_service_sync "${XHTTP_SERVICE}" xray
            stop_service_sync "${SOCKS_SERVICE}" v2ray
            stop_service_sync "${REALITY_SERVICE}" xray
            # 未迁移的旧 h2 服务一并停用清理
            stop_service_sync "${LEGACY_H2_SERVICE}" v2ray
            systemctl disable "${WS_SERVICE}" "${XHTTP_SERVICE}" "${SOCKS_SERVICE}" "${REALITY_SERVICE}" "${LEGACY_H2_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${WS_SERVICE}.service" "/etc/systemd/system/${XHTTP_SERVICE}.service" \
                  "/etc/systemd/system/${SOCKS_SERVICE}.service" "/etc/systemd/system/${REALITY_SERVICE}.service" \
                  "/etc/systemd/system/${LEGACY_H2_SERVICE}.service"
            rm -f "${WS_NGINX_CONF}" "/etc/nginx/conf.d/v2ray-ws-tls.conf" "${BT_NGINX_VHOST_DIR}/v2ray-ws-tls.conf" \
                  "${WS_CONF}" "${XHTTP_CONF}" "${SOCKS_CONF}" "${REALITY_CONF}" "${LEGACY_H2_CONF}" \
                  "${INFO_FILE}" "${URL_FILE}" "${SSL_UPDATE_SH}"
            if [[ -f /usr/local/bin/v2ray-uninstall ]]; then
                bash /usr/local/bin/v2ray-uninstall || true
            else
                # fhs-install 的卸载是独立脚本, 不存在时在线拉取执行 (--remove)
                bash <(curl -L -s https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --remove 2>/dev/null || true
            fi
            if [[ -f /usr/local/bin/xray-uninstall ]]; then
                bash /usr/local/bin/xray-uninstall || true
            fi
            # Xray 官方安装脚本无 --remove 选项, 手动清理其安装内容
            systemctl stop xray 2>/dev/null || true
            systemctl disable xray 2>/dev/null || true
            rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
            rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
            rm -f /usr/local/bin/xray
            rm -rf /usr/local/share/xray /usr/local/etc/xray
            # 官方卸载后的残余: 模板配置与空目录清理
            # (fhs-install-v2ray 会生成模板 config.json "{}", 不删则 rmdir 必然失败)
            rm -f "${V2RAY_CONF_DIR}/config.json" "${XRAY_CONF_DIR}/config.json"
            rm -rf "${V2RAY_CONF_DIR}" "${XRAY_CONF_DIR}"
            rmdir "${V2RAY_CONF_DIR}" "${XRAY_CONF_DIR}" 2>/dev/null || true
            # 平滑重载 Nginx (宝塔或发行版), 绝不 stop 现有网站服务
            if [[ "${NGINX_ENV}" == "btpanel" && -x "${NGINX_BIN}" ]]; then
                "${NGINX_BIN}" -t >/dev/null 2>&1 && "${NGINX_BIN}" -s reload
            elif command -v nginx >/dev/null 2>&1; then
                nginx -t >/dev/null 2>&1 && systemctl reload nginx
            fi
            # 清理脚本自身的缓存与记录文件
            rm -f "${V2RAY_CONF_DIR}/used_ports.txt" "${V2RAY_CONF_DIR}/gfw_list.txt"
            # 目录为空则删除, 非空 (还有用户文件) 保留
            rmdir "${V2RAY_CONF_DIR}" "${XRAY_CONF_DIR}" 2>/dev/null || true
            log_info "全部卸载完成。证书 (acme.sh / ${CERT_DIR}) 与伪装站点目录保留,如需彻底清理请手动删除。"
            systemctl daemon-reload
            return
            ;;
        *) return ;;
    esac
    systemctl daemon-reload
    # 导出文件整体重建: 只保留仍安装模式的链接 (链接一律从实际配置现场生成,
    # 卸载后其配置已删, 重建自然剔除该模式的链接, 含 vmess/base64 等无法按特征匹配的行)
    rebuild_url_file_from_config
    log_info "卸载完成。"
}

# 从当前 REALITY 配置生成分享链接 (uuid/端口/sni/sid/私钥从 conf 提取, 公钥由私钥推导)
build_reality_link_from_conf() {
    local uuid sni sid pubkey ip
    uuid="$(grep -o '"id": "[^"]*"' "${REALITY_CONF}" | head -1 | cut -d'"' -f4)"
    sni="$(grep -A1 '"serverNames"' "${REALITY_CONF}" | grep -o '"[^"]*"' | sed -n 2p | tr -d '"')"
    sid="$(grep -A1 '"shortIds"' "${REALITY_CONF}" | grep -o '"[0-9a-f]*"' | tr -d '"' | head -1)"
    # 公钥必须与配置中的私钥配对 (密钥重置后旧 pbk 失效), 由私钥推导;
    # 推导失败才回退沿用 URL_FILE 里的旧值 (此时提示可能不可用)
    local privkey
    privkey="$(grep -o '"privateKey": "[^"]*"' "${REALITY_CONF}" | cut -d'"' -f4)"
    pubkey="$(xray x25519 -i "${privkey}" 2>/dev/null | awk '/Public key|Password/{print $NF}')"
    if [[ -z "${pubkey}" ]]; then
        pubkey="$(grep reality "${URL_FILE}" 2>/dev/null | tail -1 | grep -o 'pbk=[^&]*' | cut -d= -f2)"
        log_warn "公钥推导失败,链接沿用旧 pbk (若刚更换过密钥则此链接不可用)。"
    fi
    local port
    port="$(grep -o '"port": [0-9]*' "${REALITY_CONF}" | head -1 | grep -o '[0-9]*')"
    ip="$(curl -4 -s --max-time 8 https://api.ip.sb/ip || curl -4 -s --max-time 8 https://api.ipify.org)"
    ip="${ip//[$'\r\n']/}"
    echo "vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${pubkey}&sid=${sid}&sni=${sni}&fp=chrome&flow=xtls-rprx-vision&encryption=none#${sni}-reality"
}

# 重置 REALITY 节点要素 (端口/UUID/密钥/全部), 保留伪装站; 变更后输出新链接, 失败回滚
do_reset_reality() {
    check_root
    if [[ ! -f "${REALITY_CONF}" || ! -f "/etc/systemd/system/${REALITY_SERVICE}.service" ]]; then
        log_error "未安装 REALITY 模式,请先通过菜单 6 或 bash install.sh reality 安装。"
        return
    fi

    echo "请选择要重置的项目:"
    echo "  1. 仅更换端口     (旧端口释放, 自动分配新端口)"
    echo "  2. 仅更换 UUID    (旧客户端立即失效)"
    echo "  3. 仅更换密钥对   (pbk 变化, 节点身份重置)"
    echo "  4. 全部重置       (端口+UUID+密钥)"
    echo "  0. 返回主菜单"
    read -rp "请选择: " choice || return

    local reset_port=0 reset_uuid=0 reset_key=0
    case "${choice}" in
        1) reset_port=1 ;;
        2) reset_uuid=1 ;;
        3) reset_key=1 ;;
        4) reset_port=1; reset_uuid=1; reset_key=1 ;;
        *) return ;;
    esac

    # 备份当前配置 (回滚用)
    cp "${REALITY_CONF}" "${REALITY_CONF}.bak"

    local old_port
    old_port="$(grep -o '"port": [0-9]*' "${REALITY_CONF}" | head -1 | grep -o '[0-9]*')"
    local changed=()

    if [[ "${reset_port}" == "1" ]]; then
        local new_port
        if ! pick_port "REALITY 新端口" 8443; then
            log_info "已取消重置 (原配置未动)。"
            rm -f "${REALITY_CONF}.bak"
            return 1
        fi
        new_port="${PICK_PORT_RESULT}"
        sed -i "s/\"port\": ${old_port},/\"port\": ${new_port},/" "${REALITY_CONF}"
        changed+=("端口 ${old_port} -> ${new_port}")
        record_port "${new_port}"
        unrecord_port "${old_port}"
    fi
    if [[ "${reset_uuid}" == "1" ]]; then
        local old_uuid new_uuid
        old_uuid="$(grep -o '"id": "[^"]*"' "${REALITY_CONF}" | head -1 | cut -d'"' -f4)"
        new_uuid="$(gen_uuid)"
        sed -i "s/\"id\": \"${old_uuid}\"/\"id\": \"${new_uuid}\"/" "${REALITY_CONF}"
        changed+=("UUID 已更换")
    fi
    if [[ "${reset_key}" == "1" ]]; then
        if ! gen_x25519; then
            log_error "生成新密钥对失败,原配置未动。"
            rm -f "${REALITY_CONF}.bak"
            return 1
        fi
        sed -i "s|\"privateKey\": \"[^\"]*\"|\"privateKey\": \"${X25519_PRIVKEY}\"|" "${REALITY_CONF}"
        changed+=("密钥对已更换 (新 pbk 见下方链接)")
    fi
    fix_config_perm "${REALITY_CONF}"

    systemctl restart "${REALITY_SERVICE}"
    sleep 1
    if ! systemctl is-active --quiet "${REALITY_SERVICE}"; then
        log_error "服务重启失败,回滚配置:"
        mv "${REALITY_CONF}.bak" "${REALITY_CONF}"
        # 回滚端口记录: 新端口已记录、旧端口已删除, 与配置恢复保持一致
        if [[ "${reset_port}" == "1" ]]; then
            unrecord_port "${new_port:-0}"
            record_port "${old_port}"
        fi
        systemctl restart "${REALITY_SERVICE}"
        journalctl -u "${REALITY_SERVICE}" --no-pager -n 10
        return 1
    fi
    rm -f "${REALITY_CONF}.bak"

    # 端口变更时放行新端口
    if [[ "${reset_port}" == "1" ]]; then
        open_firewall
    fi

    local new_url
    new_url="$(build_reality_link_from_conf)"
    # 导出文件重建而非追加: 新链接替换旧 REALITY 链接, 文件里不残留失效链接
    rebuild_url_file_from_config
    # 同步 INFO_FILE 的 reality 段落 (端口/UUID/链接), 保持菜单 7 与导出一致
    REALITY_PORT="$(grep -o '"port": [0-9]*' "${REALITY_CONF}" | head -1 | grep -o '[0-9]*')"
    UUID="$(grep -o '"id": "[^"]*"' "${REALITY_CONF}" | head -1 | cut -d'"' -f4)"
    MODE="reality"
    sync_info_block "vless+reality" "${new_url}"

    echo
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}   REALITY 节点重置完成                   ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    local c
    for c in "${changed[@]}"; do
        echo -e " - ${c}"
    done
    echo -e " 新链接   : ${new_url}"
    echo -e "${GREEN}==========================================${PLAIN}"
    show_qr "${new_url}"
    log_confirm "客户端请删除旧节点并导入上面的新链接 (旧链接已失效)。"
}

# 重置 ws/xhttp/socks 节点要素: 选模式 -> 选要素 -> 改配置重启 -> 失败回滚 -> 重建分享链接
do_reset_node() {
    check_root
    # 必须局部化: b 分支会递归调用本函数, 全局残留会让上一轮的
    # reset_port/reset_uuid/reset_creds 泄漏进新一轮选择 (如先选换端口
    # 再 b 返回改选换 UUID, 结果端口也被重置)
    local reset_port=0 reset_uuid=0 reset_creds=0
    while :; do
        echo "请选择要重置的节点模式:"
        echo "  1. ws+tls     (v2ray-ws)"
        echo "  2. xhttp+tls  (xray-xhttp)"
        echo "  3. socks5     (v2ray-socks)"
        echo "  0. 返回主菜单"
        read -rp "请选择: " mode_pick || return

        local conf svc svc_label port_var old_port new_port new_uuid new_user new_pass
        local is_socks=0 new_internal=""
        case "${mode_pick}" in
            1) conf="${WS_CONF}";   svc="${WS_SERVICE}";   svc_label="ws+tls" ;;
            2) conf="${XHTTP_CONF}";   svc="${XHTTP_SERVICE}";   svc_label="xhttp+tls" ;;
            3) conf="${SOCKS_CONF}"; svc="${SOCKS_SERVICE}"; svc_label="socks5"; is_socks=1 ;;
            0|*) return ;;
        esac
        if [[ ! -f "${conf}" || ! -f "/etc/systemd/system/${svc}.service" ]]; then
            log_error "未安装 ${svc_label} 模式,请先安装。"
            return
        fi
        break
    done

    echo
    if [[ "${is_socks}" == "1" ]]; then
        echo "请选择要重置的项目:"
        echo "  1. 仅更换端口"
        echo "  2. 仅更换用户名/密码"
        echo "  3. 端口 + 用户名/密码 全部重置"
        echo "  b. 返回上一级 (重新选模式)"
        echo "  0. 返回主菜单"
        read -rp "请选择: " elem_pick || return
        case "${elem_pick}" in
            1) reset_port=1 ;;
            2) reset_creds=1 ;;
            3) reset_port=1; reset_creds=1 ;;
            b|B) do_reset_node; return ;;
            0|*) return ;;
        esac
    else
        echo "请选择要重置的项目:"
        echo "  1. 仅更换端口"
        echo "  2. 仅更换 UUID"
        echo "  3. 端口 + UUID 全部重置"
        echo "  b. 返回上一级 (重新选模式)"
        echo "  0. 返回主菜单"
        read -rp "请选择: " elem_pick || return
        case "${elem_pick}" in
            1) reset_port=1 ;;
            2) reset_uuid=1 ;;
            3) reset_port=1; reset_uuid=1 ;;
            b|B) do_reset_node; return ;;
            0|*) return ;;
        esac
    fi

    cp "${conf}" "${conf}.bak"
    local changed=()

    if [[ "${is_socks}" == "1" ]]; then
        old_port="$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')"
        if [[ "${reset_port:-0}" == "1" ]]; then
            if ! pick_port "socks5 新端口" 10808; then
                log_info "已取消重置 (原配置未动)。"
                rm -f "${conf}.bak"
                return 1
            fi
            new_port="${PICK_PORT_RESULT}"
            sed -i "s/\"port\": ${old_port},/\"port\": ${new_port},/" "${conf}"
            SOCKS_PORT="${new_port}"
            changed+=("端口 ${old_port} -> ${new_port}")
            record_port "${new_port}"
            unrecord_port "${old_port}"
        fi
        if [[ "${reset_creds:-0}" == "1" ]]; then
            new_user="$(gen_random 8)"
            new_pass="$(gen_random 16)"
            sed -i "s/\"user\": \"[^\"]*\"/\"user\": \"${new_user}\"/; s/\"pass\": \"[^\"]*\"/\"pass\": \"${new_pass}\"/" "${conf}"
            SOCKS_USER="${new_user}"; SOCKS_PASS="${new_pass}"
            changed+=("用户名/密码已更换: ${new_user} / ${new_pass}")
        fi
    else
        old_port="$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')"
        if [[ "${reset_port:-0}" == "1" ]]; then
            if ! pick_port "新端口 (ws 为客户端连接端口, xhttp 为服务端口)" 8443; then
                log_info "已取消重置 (原配置未动)。"
                rm -f "${conf}.bak"
                return 1
            fi
            new_port="${PICK_PORT_RESULT}"
            sed -i "s/\"port\": ${old_port},/\"port\": ${new_port},/" "${conf}"
            if [[ "${mode_pick}" == "1" ]]; then
                # ws 模式: 客户端连接的是 nginx 监听端口, "更换端口"应作用于它;
                # 443 并入式部署 (nginx 已占 443) 只换内部端口, 对外仍走 443
                local old_ws_port new_ws_port
                old_ws_port="$(grep -m1 -oE "listen [0-9]+ ssl" "${WS_NGINX_CONF}" | grep -o "[0-9]*")"
                old_ws_port="${old_ws_port:-443}"
                # proxy_pass 可能与 conf 漂移 (历史版本 bug 或手工改动):
                # 以 nginx 实际指向为准改写, sed 匹配不到时兜底, 避免静默失配
                local cur_proxy_port
                cur_proxy_port="$(grep -m1 -oE 'proxy_pass http://127\.0\.0\.1:[0-9]+' "${WS_NGINX_CONF}" | grep -o '[0-9]*$')"
                if [[ "${old_ws_port}" == "443" ]]; then
                    INTERNAL_PORT="${new_port}"
                    sed -i "s|proxy_pass http://127.0.0.1:${cur_proxy_port};|proxy_pass http://127.0.0.1:${new_port};|" "${WS_NGINX_CONF}"
                    if ! grep -q "proxy_pass http://127.0.0.1:${new_port};" "${WS_NGINX_CONF}"; then
                        sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:${new_port};|" "${WS_NGINX_CONF}"
                    fi
                    log_info "ws 模式: 对外端口仍为 443 (nginx 并入), v2ray 内部端口已更新为 ${new_port}。"
                else
                    new_ws_port="${new_port}"
                    local new_internal
                    new_internal="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
                    sed -i "s/\"port\": ${new_port},/\"port\": ${new_internal},/" "${conf}"
                    sed -i "s|proxy_pass http://127.0.0.1:${cur_proxy_port};|proxy_pass http://127.0.0.1:${new_internal};|" "${WS_NGINX_CONF}"
                    if ! grep -q "proxy_pass http://127.0.0.1:${new_internal};" "${WS_NGINX_CONF}"; then
                        sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:${new_internal};|" "${WS_NGINX_CONF}"
                    fi
                    # listen 行有两种格式: 旧版 "listen <p> ssl http2;" / "listen [::]:<p> ssl http2;",
                    # nginx >=1.25.1 "listen <p> ssl;" / "listen [::]:<p);" (http2 独立指令)。
                    # IPv4 行固定有 ssl 后缀, IPv6 行可能没有, 两种变体都要替换。
                    sed -i "s|listen ${old_ws_port} ssl|listen ${new_ws_port} ssl|; s|listen \[::\]:${old_ws_port}|listen [::]:${new_ws_port}|" "${WS_NGINX_CONF}"
                    INTERNAL_PORT="${new_internal}"
                    WS_PORT="${new_ws_port}"
                    record_port "${new_internal}"
                    # 旧内部端口与新端口相同时 (如手工改过配置致 sed 未命中) 不删, 防误删在用记录
                    [[ "${old_port}" != "${new_port}" ]] && unrecord_port "${old_port}"
                    log_info "ws 模式: 对外监听端口 ${old_ws_port} -> ${new_ws_port} (nginx 配置将一并 reload)。"
                fi
            else
                XHTTP_PORT="${new_port}"
                INTERNAL_PORT="${new_port}"
            fi
            changed+=("端口 ${old_port} -> ${new_port}")
            record_port "${new_port}"
            unrecord_port "${old_port}"
        fi
        if [[ "${reset_uuid:-0}" == "1" ]]; then
            local old_uuid
            old_uuid="$(grep -o '"id": "[^"]*"' "${conf}" | head -1 | cut -d'"' -f4)"
            new_uuid="$(gen_uuid)"
            sed -i "s/\"id\": \"${old_uuid}\"/\"id\": \"${new_uuid}\"/" "${conf}"
            UUID="${new_uuid}"
            changed+=("UUID 已更换")
        fi
    fi

    fix_config_perm "${conf}"
    systemctl restart "${svc}"
    if [[ "${mode_pick}" == "1" ]]; then
        nginx_check_reload 2>/dev/null || true
    fi
    sleep 1
    if ! systemctl is-active --quiet "${svc}"; then
        log_error "服务重启失败,回滚配置:"
        mv "${conf}.bak" "${conf}"
        if [[ "${mode_pick}" == "1" && "${reset_port:-0}" == "1" ]]; then
            sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:${old_port};|" "${WS_NGINX_CONF}"
            # 独立端口部署时 listen 行已被改成新端口, 一并还原
            sed -i "s|listen ${new_port} ssl|listen ${old_ws_port} ssl|; s|listen \[::\]:${new_port}|listen [::]:${old_ws_port}|" "${WS_NGINX_CONF}" 2>/dev/null || true
        fi
        # 回滚端口记录 (ws 独立端口场景记录了外部+内部两个新端口)
        if [[ "${reset_port:-0}" == "1" ]]; then
            unrecord_port "${new_port:-0}"
            [[ -n "${new_internal:-}" ]] && unrecord_port "${new_internal}"
            record_port "${old_port}"
        fi
        systemctl restart "${svc}"
        journalctl -u "${svc}" --no-pager -n 10
        return 1
    fi

    # 端口监听终验: 重启成功但端口没监听 (被抢/绑定失败) 同样按失败回滚
    # 注意: 备份文件在终验通过后才删除, 保证此分支可回滚
    if [[ "${reset_port:-0}" == "1" ]]; then
        local final_port
        final_port="$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')"
        if ! verify_port_listening "${final_port}"; then
            log_error "新端口 ${final_port} 未监听,回滚配置:"
            mv "${conf}.bak" "${conf}"
            if [[ "${mode_pick}" == "1" ]]; then
                sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:${old_port};|" "${WS_NGINX_CONF}"
                [[ "${old_ws_port:-}" != "${new_port}" ]] && sed -i "s|listen ${new_port} ssl|listen ${old_ws_port} ssl|; s|listen \[::\]:${new_port}|listen [::]:${old_ws_port}|" "${WS_NGINX_CONF}" 2>/dev/null || true
            fi
            # 回滚端口记录 (ws 独立端口场景记录了外部+内部两个新端口)
            unrecord_port "${new_port:-0}"
            [[ -n "${new_internal:-}" ]] && unrecord_port "${new_internal}"
            record_port "${old_port}"
            systemctl restart "${svc}"
            journalctl -u "${svc}" --no-pager -n 10
            return 1
        fi
        open_firewall
    fi
    rm -f "${conf}.bak"

    # 重建分享链接: 从当前配置读取参数复用 build_share_link 的变量约定
    if [[ "${is_socks}" == "1" ]]; then
        MODE="socks"; PROTOCOL=""
        # 端口/凭据未重置时, 从配置补齐全局变量 (本次会话可能未安装过该模式)
        SOCKS_PORT="${SOCKS_PORT:-$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')}"
        SOCKS_USER="${SOCKS_USER:-$(grep -o '"user": "[^"]*"' "${conf}" | cut -d'"' -f4)}"
        SOCKS_PASS="${SOCKS_PASS:-$(grep -o '"pass": "[^"]*"' "${conf}" | cut -d'"' -f4)}"
        # 备注与安装时/菜单 7 一致 (socks5-<ip>), 避免同节点出现两个名字
        CLIENT_REMARK="${CLIENT_REMARK:-socks5-${PUBLIC_IP:-$(get_public_ip && echo "${PUBLIC_IP:-server}")}}"
        CLIENT_REMARK="${CLIENT_REMARK//[$'\r\n']/}"
    else
        # mode_pick 是菜单序号 (1=ws 2=xhttp 3=socks), 不能直接当 MODE 用:
        # build_share_link 按 MODE 的语义名分派, 传序号会全部落到 ws 分支。
        if [[ "${mode_pick}" == "1" ]]; then
            MODE="ws"
        else
            MODE="xhttp"
        fi
        PROTOCOL="vless"
        # 实际安装协议可能为 vmess (安装时决定), 从 info 段落名恢复, 保持段落名不变
        local section_key="${svc_label%%+*}"
        local infoblock
        infoblock="$(awk -v s="### .*${section_key}" 'BEGIN{IGNORECASE=0} $0 ~ s {f=1} f && /^### / && $0 !~ s {f=0} f' "${INFO_FILE}" 2>/dev/null)"
        PROTOCOL="$(grep -m1 '^### ' <<< "${infoblock}" | grep -o '^### \(vmess\|vless\)' | cut -d' ' -f2)"
        PROTOCOL="${PROTOCOL:-vless}"
        DOMAIN="$(echo "${infoblock}" | grep "^domain=" | tail -1 | cut -d= -f2)"
        [[ -z "${DOMAIN}" ]] && DOMAIN="$(grep "^domain=" "${INFO_FILE}" 2>/dev/null | tail -1 | cut -d= -f2)"
        WS_PATH="$(grep -o '"path": "/[^"]*"' "${conf}" | head -1 | cut -d'"' -f4)"
        WS_PATH="${WS_PATH#/}"
        UUID="$(grep -o '"id": "[^"]*"' "${conf}" | head -1 | cut -d'"' -f4)"
        # 端口: nginx 监听端口才是客户端连接端口 (ws 可能因 443 被占而用独立端口)
        if [[ "${mode_pick}" == "1" && -f "${WS_NGINX_CONF}" ]]; then
            WS_PORT="$(grep -m1 -oE "listen [0-9]+ ssl" "${WS_NGINX_CONF}" | grep -o "[0-9]*")"
            WS_PORT="${WS_PORT:-443}"
        else
            XHTTP_PORT="$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')"
        fi
        CLIENT_REMARK="${DOMAIN}-${PROTOCOL}-${svc_label%%+*}"
    fi
    build_share_link
    # 导出文件重建而非追加: 新链接替换旧链接, 文件里不残留失效链接
    rebuild_url_file_from_config
    sync_info_block "$([[ "${MODE}" == "socks" ]] && echo "socks" || echo "${PROTOCOL}+${svc_label%%+*}")" "${SHARE_URL}"

    echo
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}   ${svc_label} 节点重置完成                   ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    local c
    for c in "${changed[@]}"; do
        echo -e " - ${c}"
    done
    echo -e " 新链接   : ${SHARE_URL}"
    [[ -n "${SHARE_URL_PLAIN:-}" ]] && echo -e " 工具格式 : ${SHARE_URL_PLAIN}"
    [[ -n "${SHARE_URL_PLAIN2:-}" ]] && echo -e " 工具格式2: ${SHARE_URL_PLAIN2}"
    [[ "${svc_label}" == "xhttp+tls" ]] && show_xhttp_client_notice
    echo -e "${GREEN}==========================================${PLAIN}"
    show_qr "${SHARE_URL}"
    log_confirm "客户端请删除旧节点并导入上面的新链接 (旧链接已失效)。"
}

# 重置后同步 INFO_FILE 对应段落 (端口/UUID/凭据), 保持菜单 7 与导出一致
sync_info_block() {
    local section="$1" new_share_url="$2"
    [[ ! -f "${INFO_FILE}" ]] && return
    if ! grep -q "^### ${section}$" "${INFO_FILE}"; then
        append_info "${section}"
        return
    fi
    local tmp="${INFO_FILE}.tmp.$$"
    awk -v s="### ${section}" -v newurl="share_url=${new_share_url}" '
        $0 == s {inblk=1}
        inblk && /^share_url=/ {print newurl; inblk=2; next}
        inblk == 2 && /^port=/ {
            if (mode == "socks") print "port=" socks_port
            else if (mode == "h2" || mode == "xhttp") print "port=" h2_port
            else if (mode == "reality") print "port=" reality_port
            else print "port=" ws_port
            next
        }
        inblk == 2 && /^uuid=/ {print "uuid=" uuid; next}
        inblk == 2 && /^socks_user=/ {print "socks_user=" socks_user; next}
        inblk == 2 && /^socks_pass=/ {print "socks_pass=" socks_pass; next}
        inblk == 2 && /^### / {inblk=0}
        {print}
    ' mode="${MODE}" socks_port="${SOCKS_PORT:-}" h2_port="${XHTTP_PORT:-}" ws_port="${WS_PORT:-443}" \
      reality_port="${REALITY_PORT:-}" uuid="${UUID:-}" \
      socks_user="${SOCKS_USER:-}" socks_pass="${SOCKS_PASS:-}" \
      "${INFO_FILE}" > "${tmp}" && mv -f "${tmp}" "${INFO_FILE}"
    chmod 600 "${INFO_FILE}"
}

# 仅更换 REALITY 伪装目标站: 保留 UUID/端口/密钥, 只改 dest+sni, 客户端只需更新 sni 字段
do_change_reality_dest() {
    check_root
    if [[ ! -f "${REALITY_CONF}" || ! -f "/etc/systemd/system/${REALITY_SERVICE}.service" ]]; then
        log_error "未安装 REALITY 模式,请先通过菜单 6 或 bash install.sh reality 安装。"
        return
    fi
    # 从现有配置读取保留参数
    local cur_dest
    cur_dest="$(grep -o '"dest": "[^"]*"' "${REALITY_CONF}" | head -1 | cut -d'"' -f4)"
    # 当前 SNI 取自 serverNames 数组 (dest 与 serverNames 可能因历史 bug 不一致, 以
    # serverNames 为准 —— 它才是客户端握手的校验对象)
    local cur_sni
    cur_sni="$(grep -A1 '"serverNames"' "${REALITY_CONF}" | grep -o '"[^"]*"' | tr -d '"' | sed -n 2p)"
    [[ -z "${cur_sni}" ]] && cur_sni="${cur_dest%%:*}"
    local cur_port
    cur_port="$(grep -o '"port": [0-9]*' "${REALITY_CONF}" | head -1 | grep -o '[0-9]*')"
    log_info "当前伪装站: ${cur_dest} (端口 ${cur_port}, SNI ${cur_sni})"

    # 选择新站: 复用候选池探测 + GFW 过滤 + 延迟排序 + 交互选择/自定义 (与安装同一套逻辑)
    local sorted_pool=() entry
    for entry in "${REALITY_DEST_POOL[@]}"; do
        [[ "${entry%%|*}" != "${cur_dest}" ]] && sorted_pool+=("${entry}")
    done
    local pool_head=() pool_tail=()
    for entry in "${sorted_pool[@]}"; do
        if check_gfw_list "${entry%%|*}"; then
            pool_tail+=("${entry}")
        else
            pool_head+=("${entry}")
        fi
    done
    sorted_pool=("${pool_head[@]}" "${pool_tail[@]}")

    local ok_dests=() probed=()
    for entry in "${sorted_pool[@]}"; do
        local d="${entry%%|*}" s="${d%%:*}"
        local dup=0 pd
        for pd in "${probed[@]}"; do [[ "${pd}" == "${d}" ]] && dup=1; done
        [[ "${dup}" == "1" ]] && continue
        probed+=("${d}")
        log_info "校验伪装目标站 ${d} ..."
        if check_reality_dest "${d}" "${s}"; then
            local ms
            ms=$( { TIMEFORMAT=%R; time timeout 5 bash -c "echo > /dev/tcp/${d%%:*}/${s}" 2>/dev/null; } 2>&1 )
            [[ -z "${ms}" ]] && ms=9999
            ms=$(awk -v t="${ms}" 'BEGIN{printf "%d", t*1000}')
            ok_dests+=("${d}|${ms}")
            log_info "  -> 可用 (TCP 延迟 ${ms}ms)"
        else
            log_info "  -> 不可用,跳过"
        fi
        (( ${#ok_dests[@]} >= 10 )) && break
    done
    if (( ${#ok_dests[@]} > 0 )); then
        ok_dests=($(printf '%s\n' "${ok_dests[@]}" | sort -t'|' -k2 -n))
    fi

    if [[ -t 0 ]]; then
        select_reality_dest_interactive ok_dests
    else
        if (( ${#ok_dests[@]} == 0 )); then
            log_error "候选池为空 (所有预置目标站均不可达),已放弃更换 (原配置未动)。"
            return 1
        fi
        REALITY_DEST="${ok_dests[0]%%|*}"
        REALITY_SNI="${REALITY_DEST%%:*}"
        log_info "非交互模式,自动选用延迟最低的 ${REALITY_DEST} (${ok_dests[0]##*|}ms)"
    fi

    # 终验 (失败回退: 剔除失败项后回到选择菜单, 库里选或自定义均可, 直到通过或用户主动放弃)
    while ! check_reality_dest "${REALITY_DEST}" "${REALITY_SNI}"; do
        log_error "目标站 ${REALITY_DEST} 终验未通过。"
        # 从候选中剔除失败项
        local remain=() od
        for od in "${ok_dests[@]}"; do
            [[ "${od%%|*}" != "${REALITY_DEST}" ]] && remain+=("${od}")
        done
        ok_dests=("${remain[@]}")
        if (( ${#ok_dests[@]} == 0 )); then
            log_warn "预置候选已用完,请自定义输入目标站 (校验通过才接受)。"
        fi
        log_confirm "请重新选择目标站 (库里选编号 / c 自定义 / q 放弃更换):"
        if ! select_reality_dest_interactive ok_dests; then
            log_error "已放弃更换 (原配置未动)。"
            return 1
        fi
    done

    # 仅改 dest/sni, 保留 port/uuid/密钥/sid。
    # serverNames 必须精确替换数组内元素: 泛化的 "s|旧sni|新sni|" 会先命中
    # dest 行 (此时 dest 已改成新站) 造成漏改/错改 (实战踩坑: 换站后
    # serverNames 残留旧站, 客户端 SNI 校验不过, 报
    # "REALITY: received real certificate (potential MITM or redirection)")。
    sed -i "s|\"dest\": \"${cur_dest}\"|\"dest\": \"${REALITY_DEST}\"|" "${REALITY_CONF}"
    sed -i "/\"serverNames\"/,/]/ s|\"${cur_sni}\"|\"${REALITY_SNI}\"|" "${REALITY_CONF}"
    fix_config_perm "${REALITY_CONF}"
    systemctl restart "${REALITY_SERVICE}"
    sleep 1
    if ! systemctl is-active --quiet "${REALITY_SERVICE}"; then
        log_error "服务重启失败,回滚配置:"
        sed -i "s|\"dest\": \"${REALITY_DEST}\"|\"dest\": \"${cur_dest}\"|" "${REALITY_CONF}"
        sed -i "/\"serverNames\"/,/]/ s|\"${REALITY_SNI}\"|\"${cur_sni}\"|" "${REALITY_CONF}"
        systemctl restart "${REALITY_SERVICE}"
        journalctl -u "${REALITY_SERVICE}" --no-pager -n 10
        return 1
    fi

    # 更新 info 文件并输出新链接: 直接从当前配置读全部参数生成 (不依赖 URL_FILE 历史条目)
    local uuid cur_pubkey cur_sid
    uuid="$(grep -o '"id": "[^"]*"' "${REALITY_CONF}" | head -1 | cut -d'"' -f4)"
    # shortIds 是多行数组, 用 -A1 抓第一个值
    cur_sid="$(grep -A1 '"shortIds"' "${REALITY_CONF}" | grep -o '"[0-9a-f]*"' | tr -d '"' | head -1)"
    # pbk 必须与配置内私钥配对, 私钥推导优先; URL_FILE 历史值只作推导失败的兜底
    local privkey
    privkey="$(grep -o '"privateKey": "[^"]*"' "${REALITY_CONF}" | cut -d'"' -f4)"
    cur_pubkey="$(xray x25519 -i "${privkey}" 2>/dev/null | awk '/Public key|Password/{print $NF}')"
    if [[ -z "${cur_pubkey}" ]]; then
        cur_pubkey="$(grep reality "${URL_FILE}" 2>/dev/null | tail -1 | grep -o 'pbk=[^&]*' | cut -d= -f2)"
        log_warn "公钥推导失败,链接沿用历史 pbk (可能与当前密钥不配对, 请重置密钥)。"
    fi
    local ip
    ip="$(curl -4 -s --max-time 8 https://api.ip.sb/ip || curl -4 -s --max-time 8 https://api.ipify.org)"
    ip="${ip//[$'\r\n']/}"
    new_url="vless://${uuid}@${ip}:${cur_port}?type=tcp&security=reality&pbk=${cur_pubkey}&sid=${cur_sid}&sni=${REALITY_SNI}&fp=chrome&flow=xtls-rprx-vision&encryption=none#${REALITY_SNI}-reality"
    # 导出文件重建而非追加: 换站后旧 REALITY 链接 (旧 sni) 不再残留
    rebuild_url_file_from_config
    # 同步 INFO_FILE 的 dest/sni/share_url
    MODE="reality"; REALITY_PORT="${cur_port}"; UUID="${uuid}"
    sync_info_block "vless+reality" "${new_url}"
    sed -i "/### vless+reality/,/^$/ { s|^dest=.*|dest=${REALITY_DEST}|; s|^sni=.*|sni=${REALITY_SNI}|; }" "${INFO_FILE}"

    echo
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}   伪装站已更换 (UUID/端口/密钥不变)      ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e " 新伪装站 : ${REALITY_DEST}"
    echo -e " 新链接   : ${new_url}"
    echo -e "${GREEN}==========================================${PLAIN}"
    show_qr "${new_url}"
    log_confirm "客户端只需把该节点的 SNI 改为 ${REALITY_SNI} (或删旧导新上面的链接)。"
    log_confirm "同时请更新本地直连验证: 你所在网络需能正常访问 ${REALITY_SNI}。"
}


do_update_v2ray() {
    check_root
    log_info "更新 V2Ray core..."
    bash <(curl -L -s "${V2RAY_INSTALL_SCRIPT}")
    log_info "更新 Xray core..."
    bash <(curl -L -s "${XRAY_INSTALL_SCRIPT}")
    # 官方安装脚本重跑会重新启用自带的 xray.service (跑占位 config.json),
    # 与 ensure_xray 同样处理: 停用禁用, 只保留本脚本的 xray-reality.service
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray >/dev/null 2>&1 || true
    systemctl restart "${WS_SERVICE}" "${XHTTP_SERVICE}" "${SOCKS_SERVICE}" "${REALITY_SERVICE}" 2>/dev/null
    log_info "V2Ray / Xray 已更新,相关服务已重启。"
}

# ---------- 安装流程调度 ----------

do_install() {
    # check_root / check_system / 依赖补齐已在 main() 入口完成 (含非交互路径),
    # 这里只做安装专属的检查: 未验证发行版确认 + 深度预检 + 安装完整依赖集。
    if ! confirm_untested_distro; then
        log_info "已取消安装。"
        exit 0
    fi
    preflight_check
    # 启动阶段只装了 RUNTIME_DEPS; 安装还需要 qrencode/socat/cron 等完整集合
    install_dependencies

    case "${MODE}" in
        ws)      do_install_ws ;;
        xhttp)   do_install_xhttp ;;
        socks)   do_install_socks ;;
        reality) do_install_reality ;;
    esac
}

# ---------- 菜单 ----------

show_menu() {
    clear
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}          V2Ray/Xray 多模式一键脚本                 ${PLAIN}"
    echo -e "${GREEN}  ws/xhttp/socks5/REALITY 可同时安装互不冲突        ${PLAIN}"
    echo -e "${GREEN}          适配最新版 v2rayN / v2rayNG               ${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e " 1. 安装  vmess + ws    + tls  (Nginx 伪装站, 443)"
    echo -e " 2. 安装  vless + ws    + tls  (Nginx 伪装站, 443)"
    echo -e " 3. 安装  vmess + xhttp + tls  (Xray 直连, 独立端口)"
    echo -e " 4. 安装  vless + xhttp + tls  (Xray 直连, 独立端口)"
    echo -e " 5. 安装  socks5               (独立端口, 带认证)"
    echo -e " 6. 安装  vless + REALITY      (Xray, 抗封锁首选, 免域名证书)"
    echo -e " 7. 查看已安装节点 / 导出全部分享链接"
    echo -e " 8. 手动续签 / 重新申请证书"
    echo -e " 9. 更新 V2Ray / Xray core"
    echo -e "10. 更换 REALITY 伪装站 (保留 UUID/端口, 客户端只改 SNI)"
    echo -e "11. 重置 REALITY 节点 (端口 / UUID / 密钥 / 全部)"
    echo -e "12. 重置 ws/xhttp/socks 节点 (端口 / UUID / 用户密码)"
    echo -e "13. 卸载 (可选单模式或全部)"
    echo -e "14. 更新脚本 (从 GitHub 下载最新版覆盖本脚本)"
    echo -e "15. 升级已装节点配置 (保留 UUID/端口/密钥, 补齐新版功能)"
    echo -e " 0. 退出"
    echo
    read -rp "请选择: " choice || exit 0
    case "${choice}" in
        1) MODE="ws";      PROTOCOL="vmess"; do_install ;;
        2) MODE="ws";      PROTOCOL="vless"; do_install ;;
        3) MODE="xhttp";   PROTOCOL="vmess"; do_install ;;
        4) MODE="xhttp";   PROTOCOL="vless"; do_install ;;
        5) MODE="socks";   PROTOCOL="";      do_install ;;
        6) MODE="reality"; PROTOCOL="vless"; do_install ;;
        7) do_show_info ;;
        8) do_renew_cert ;;
        9) do_update_v2ray ;;
        10) do_change_reality_dest ;;
        11) do_reset_reality ;;
        12) do_reset_node ;;
        13) do_uninstall ;;
        14) do_self_update ;;
        15) do_upgrade_nodes ;;
        0) exit 0 ;;
        *) ;;
    esac
}

do_renew_cert() {
    if [[ ! -f "${SSL_UPDATE_SH}" ]]; then
        log_warn "未找到续签脚本 (${SSL_UPDATE_SH}),可能尚未安装。"
        return
    fi
    bash "${SSL_UPDATE_SH}"
}

# ---------- 已装节点配置升级 (菜单 15) ----------
# 机制: 配置模板随脚本版本演进 (如 1.3.0 的 freedom UseIPv4), 已安装机器的存量配置
# 不会自动跟上。这里登记按版本排序的迁移补丁, 菜单 15 按序补跑未应用的迁移:
# 每条补丁幂等 (先检测字段已存在则跳过)、改前备份、改后 validate_core_config 校验,
# 失败自动回滚。已应用记录写 MIGRATION_STATE (版本|迁移名 一行一条)。
# 【维护纪律】改任何配置模板必须同步在此追加一条迁移 (见 AGENTS.md 门禁)。

MIGRATION_STATE="${V2RAY_CONF_DIR}/migrations_done.txt"

# 迁移注册表: "版本|函数名|描述" (按版本从旧到新排序, 追加到末尾)
MIGRATIONS=(
    "1.3.0|migr_useipv4|所有模式 freedom 出站补 domainStrategy=UseIPv4"
    "1.5.0|migr_h2_to_xhttp|h2 节点迁移到 xhttp 传输 (h2 已被内核删除, 核心换 Xray)"
)

# --- 迁移: 1.3.0 freedom 出站 UseIPv4 ---
# 配置由本脚本生成, 但存量机器可能被手工改过, freedom 行有两种常见形态:
#   "protocol": "freedom",   (1.3.0+ 模板, 尾逗号)
#   "protocol": "freedom"    (手工 sed 删行后的变体, 无尾逗号)
# 两种都要兼容; 已带 domainStrategy 的配置检测后跳过, 幂等。
migr_useipv4() {
    local conf="$1" bin="$2"
    [[ -f "${conf}" ]] || return 0   # 该模式未安装, 跳过
    if grep -q '"domainStrategy"' "${conf}"; then
        return 0   # 已有字段, 幂等跳过
    fi
    local hit=0
    if grep -q '"protocol": *"freedom",' "${conf}"; then
        # 形态 1: freedom 带尾逗号 (后面还有别的 outbound), 在该行后插 settings 块
        sed -i '/"protocol": *"freedom",/a\      "settings": {\n        "domainStrategy": "UseIPv4"\n      },' "${conf}" && hit=1
    elif grep -q '"protocol": *"freedom"' "${conf}"; then
        # 形态 2: freedom 无尾逗号 (手工删改后的存量), 原行补逗号 + settings 块
        # (settings 块不带尾逗号, 无论 freedom 后面是 "}" 还是 "}," 都合法)
        awk '{
            if ($0 ~ /"protocol": *"freedom"$/ && $0 !~ /,$/) {
                sub(/$/, ",")
                print
                print "      \"settings\": {"
                print "        \"domainStrategy\": \"UseIPv4\""
                print "      }"
            } else print
        }' "${conf}" > "${conf}.migr.$$" && mv -f "${conf}.migr.$$" "${conf}" && hit=1
    fi
    if [[ "${hit}" != "1" ]] || ! grep -q '"domainStrategy": "UseIPv4"' "${conf}"; then
        # 失败时打印实际结构供诊断, 而不是无声失败
        log_error "  无法在 ${conf} 定位 freedom outbound, 实际结构:"
        grep -n -A3 '"protocol"' "${conf}" | head -20
        return 1
    fi
    validate_core_config "${bin}" "${conf}" || return 1
    fix_config_perm "${conf}"
    return 0
}

# --- 迁移: 1.5.0 h2 传输 -> xhttp (含核心 v2ray -> xray) ---
# 背景: Xray 自 v24.12.31 删除 HTTP(h2) 传输, v2rayN 的 Networks 白名单也已移除
# h2/http, 因此 h2 节点对当前客户端全部失效。xhttp 是官方继任者。
# 本迁移做四件事, 全部成功后写入 state:
#   1. 把 config_h2.json 搬到 config_xhttp.json (保留 UUID/端口/path 不动)
#   2. streamSettings 里 network h2->xhttp, httpSettings 键改名 xhttpSettings
#   3. tlsSettings 的 alpn 保持 ["h2"] (xhttp 跑在 HTTP/2 之上)
#   4. 服务单元从 v2ray-h2 (v2ray 核心) 换成 xray-xhttp (xray 核心)
# 幂等: 已无 config_h2.json 或已是 xhttp 则跳过。旧 h2 文件保留备份, 不删。
migr_h2_to_xhttp() {
    # 与 migr_useipv4 不同, 本迁移跨文件/跨服务, 通用执行器传入的 $1/$2
    # 是 xhttp 的目标路径与 xray 二进制; 旧 h2 配置另按 LEGACY_H2_CONF 处理。
    # 执行器会把本函数对四种配置各调一次, 只有目标为 xhttp 路径时才动作,
    # 否则会误把 h2 配置写到别的模式上。
    local conf="$1" bin="$2"
    [[ "${conf}" == "${XHTTP_CONF}" ]] || return 0
    [[ -f "${LEGACY_H2_CONF}" ]] || return 0    # 没装过旧 h2, 跳过 (幂等)

    # 1) 旧配置搬到新路径 (若目标已存在说明已迁移过, 只清理旧文件)
    if [[ -f "${conf}" ]]; then
        log_warn "  检测到 config_h2.json 与 config_xhttp.json 并存, 以 xhttp 为准, 移除旧文件。"
        rm -f "${LEGACY_H2_CONF}"
    else
        cp -a "${LEGACY_H2_CONF}" "${conf}" || return 1
    fi

    # 2) 传输改为 xhttp: 键名与值一起换
    #    旧模板结构:  "network": "h2",  ... "httpSettings": { "path": ... }
    #    目标结构:    "network": "xhttp", ... "xhttpSettings": { "path": ... }
    if grep -q '"network": *"h2"' "${conf}"; then
        sed -i 's/"network": *"h2"/"network": "xhttp"/' "${conf}" || return 1
    fi
    if grep -q '"httpSettings"' "${conf}"; then
        sed -i 's/"httpSettings"/"xhttpSettings"/' "${conf}" || return 1
    fi
    # 兜底: 手工改过的配置可能既无 network 也无 httpSettings, 视为无法迁移
    if ! grep -q '"network": *"xhttp"' "${conf}"; then
        log_error "  无法在 ${conf} 定位 h2 传输字段, 实际结构:"
        grep -n '"network"\|Settings"' "${conf}" | head -10
        return 1
    fi
    # 旧模板没有 xhttpSettings 时补一个 (只带 path, 值取自原 httpSettings 或空)
    # 用 awk 而非 sed 的 \n 插入: busybox sed 对替换串里的 \n 支持不一致
    # (Alpine 等精简系统会写出字面 \n), awk 在各发行版的 awk 实现上行为一致。
    if ! grep -q '"xhttpSettings"' "${conf}"; then
        local old_path
        old_path="$(grep -o '"path": "/[^"]*"' "${conf}" | head -1 | cut -d'"' -f4)"
        old_path="${old_path:-/xhttp}"
        awk -v p="${old_path}" '
            {
                print
                if ($0 ~ /"network": *"xhttp",/) {
                    print "        \"xhttpSettings\": {"
                    print "          \"path\": \"" p "\""
                    print "        },"
                }
            }
        ' "${conf}" > "${conf}.migr.$$" && mv -f "${conf}.migr.$$" "${conf}" || return 1
    fi

    # 3) 用 Xray 校验新配置 (xhttp 只有 Xray 认)
    if [[ -x "${bin}" ]]; then
        validate_core_config "${bin}" "${conf}" || return 1
    fi
    fix_config_perm "${conf}"

    # 4) 服务单元: 停旧起新。旧 unit 删掉, 新 unit 由 write_xhttp_service 生成
    if [[ -f "/etc/systemd/system/${LEGACY_H2_SERVICE}.service" ]]; then
        stop_service_sync "${LEGACY_H2_SERVICE}" v2ray
        systemctl disable "${LEGACY_H2_SERVICE}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${LEGACY_H2_SERVICE}.service"
    fi
    # 生成新 unit 需要 XHTTP_CONF/XHTTP_PORT 已就位; 端口从配置现场读取
    XHTTP_PORT="$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')"
    if ! write_xhttp_service; then
        log_error "  无法生成 ${XHTTP_SERVICE} 服务单元。"
        return 1
    fi

    # 旧配置改名保留为备份, 便于回滚; 不参与任何后续逻辑
    mv -f "${LEGACY_H2_CONF}" "${LEGACY_H2_CONF}.migrated" 2>/dev/null || rm -f "${LEGACY_H2_CONF}"
    return 0
}

# 迁移通用执行器: 逐条检查 state, 未应用的执行, 失败回滚该条并继续报告
do_upgrade_nodes() {
    check_root
    local applied=0 skipped=0 failed=0
    local any_installed=0
    for c in "${REALITY_CONF}" "${WS_CONF}" "${XHTTP_CONF}" "${SOCKS_CONF}" "${LEGACY_H2_CONF}"; do
        [[ -f "${c}" ]] && any_installed=1
    done
    if [[ "${any_installed}" == "0" ]]; then
        log_warn "未检测到已安装的节点,无需升级。"
        return 0
    fi
    touch "${MIGRATION_STATE}" 2>/dev/null || { log_error "无法写入迁移状态文件 (${MIGRATION_STATE})"; return 1; }
    echo -e "${GREEN}========== 已装节点配置升级 (保留 UUID/端口/密钥) ==========${PLAIN}"
    log_info "脚本版本 v${SCRIPT_VERSION},待检迁移 ${#MIGRATIONS[@]} 条。"

    local entry ver fn desc conf bin svc_name need_restart=()
    for entry in "${MIGRATIONS[@]}"; do
        ver="${entry%%|*}"; rest="${entry#*|}"
        fn="${rest%%|*}"; desc="${rest#*|}"
        if grep -q "^${ver}|${fn}$" "${MIGRATION_STATE}" 2>/dev/null; then
            skipped=$((skipped+1))
            continue
        fi
        echo
        log_info "[迁移 ${ver}] ${desc}"
        local entry_failed=0
        # 五种模式逐个补 (未安装的配置在迁移函数内部检测后跳过)
        for pair in "${REALITY_CONF}:/usr/local/bin/xray:${REALITY_SERVICE}" \
                    "${WS_CONF}:/usr/local/bin/v2ray:${WS_SERVICE}" \
                    "${XHTTP_CONF}:/usr/local/bin/xray:${XHTTP_SERVICE}" \
                    "${SOCKS_CONF}:/usr/local/bin/v2ray:${SOCKS_SERVICE}"; do
            conf="${pair%%:*}"
            bin="${pair#*:}"; bin="${bin%%:*}"
            svc_name="${pair##*:}"
            # 源文件判定: 一般迁移的源就是目标配置; 但 h2->xhttp 的源是旧
            # config_h2.json, 目标 config_xhttp.json 此时尚未生成, 需单独放行,
            # 否则该迁移永远不会被调用。
            local src_ok=0
            [[ -f "${conf}" ]] && src_ok=1
            if [[ "${fn}" == "migr_h2_to_xhttp" && "${conf}" == "${XHTTP_CONF}" && -f "${LEGACY_H2_CONF}" ]]; then
                src_ok=1
            fi
            [[ "${src_ok}" == "1" ]] || continue
            # 目标配置不存在时 (h2->xhttp 首次迁移) 没有可备份的旧目标, 回滚靠删新建文件
            local had_target=0
            if [[ -f "${conf}" ]]; then
                cp -a "${conf}" "${conf}.migrbak" || { entry_failed=1; break; }
                had_target=1
            fi
            if ! "${fn}" "${conf}" "${bin}"; then
                log_error "  ${svc_name}: 迁移失败,已回滚。"
                if [[ "${had_target}" == "1" ]]; then
                    mv -f "${conf}.migrbak" "${conf}"
                else
                    rm -f "${conf}"
                fi
                fix_config_perm "${conf}"
                entry_failed=1
                break
            fi
            rm -f "${conf}.migrbak"
            need_restart+=("${svc_name}")
        done
        if [[ "${entry_failed}" == "1" ]]; then
            failed=$((failed+1))
        else
            echo "${ver}|${fn}" >> "${MIGRATION_STATE}"
            applied=$((applied+1))
            log_confirm "  [${ver}] 完成。"
        fi
    done

    # 重启受影响的服务 (有实际改动才重启, 秒级断连客户端自动重连)
    local restarted=()
    for svc_name in "${need_restart[@]:-}"; do
        [[ -z "${svc_name}" ]] && continue
        [[ " ${restarted[*]} " == *" ${svc_name} "* ]] && continue
        systemctl restart "${svc_name}" 2>/dev/null && restarted+=("${svc_name}")
    done

    echo
    echo -e "${GREEN}=============================================${PLAIN}"
    log_confirm "升级完成: 应用 ${applied} 条, 已是最新 ${skipped} 条, 失败 ${failed} 条。"
    if [[ ${#restarted[@]} -gt 0 ]]; then
        log_confirm "已重启服务: ${restarted[*]}"
    fi
    if [[ "${failed}" != "0" ]]; then
        log_warn "有迁移失败,请查看上方错误信息;失败条目未记录,修复后重跑本菜单会再次尝试。"
        return 1
    fi
    # 升级后链接参数可能变化, 重建导出文件保证与当前配置一致
    rebuild_url_file_from_config
    return 0
}

# 从 GitHub 下载最新脚本覆盖本地: 校验通过才替换, 失败保留原脚本
do_self_update() {
    check_root
    local self_path
    self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    if [[ ! -f "${self_path}" ]] || [[ "${self_path}" == *"downloaded from stdin"* ]]; then
        log_error "无法定位当前脚本文件,请用 bash <路径>/install.sh 方式运行后再更新。"
        return 1
    fi
    log_info "当前脚本版本: v${SCRIPT_VERSION}"
    log_info "正在从 GitHub 下载最新脚本..."
    local tmp="${self_path}.new.$$"
    if ! curl -fsSL --max-time 60 "${SELF_UPDATE_URL}" -o "${tmp}"; then
        log_error "下载失败 (网络不通或代理未配置),原脚本未改动。"
        rm -f "${tmp}"
        return 1
    fi
    # 校验 1: 是本脚本的合法副本 (含版本行), 防止把错误页/404 文本覆盖进去
    if ! grep -q '^SCRIPT_VERSION=' "${tmp}" || ! grep -q 'v2ray-ws-tls-onekey' "${tmp}"; then
        log_error "下载内容校验失败 (不是合法脚本),原脚本未改动。"
        rm -f "${tmp}"
        return 1
    fi
    # 校验 2: 语法正确
    if ! bash -n "${tmp}"; then
        log_error "下载脚本语法校验失败,原脚本未改动。"
        rm -f "${tmp}"
        return 1
    fi
    local new_ver
    new_ver="$(grep -m1 '^SCRIPT_VERSION=' "${tmp}" | cut -d'"' -f2)"
    if [[ "${new_ver}" == "${SCRIPT_VERSION}" ]]; then
        log_info "已是最新版本 (v${SCRIPT_VERSION}),无需更新。"
        rm -f "${tmp}"
        return 0
    fi
    # 校验通过: 备份 -> 原子替换 -> 失败回滚
    cp -a "${self_path}" "${self_path}.bak.$$" || { rm -f "${tmp}"; return 1; }
    if mv -f "${tmp}" "${self_path}" && chmod +x "${self_path}"; then
        rm -f "${self_path}.bak.$$"
        log_info "更新完成: v${SCRIPT_VERSION} -> v${new_ver}。重新运行 bash ${self_path} 生效。"
        # 新版脚本若有待执行迁移, 提示跑升级 (已装机器追平新配置)
        if bash -c "grep -q 'MIGRATIONS=' '${self_path}'" 2>/dev/null; then
            log_confirm "提示: 若本机已安装节点, 建议再运行一次菜单 15 (升级已装节点配置), 补齐新版脚本的配置变更。"
        fi
        exit 0
    else
        log_error "替换失败,已回滚到原脚本。"
        mv -f "${self_path}.bak.$$" "${self_path}" 2>/dev/null
        rm -f "${tmp}"
        return 1
    fi
}

main() {
    # 启动即做环境检查与依赖补齐, 保证主菜单弹出时环境已就绪。
    # 原先这些只在 do_install 里做, 导致菜单 7/10/11/12/15 在精简系统上
    # 因缺 curl/openssl 而静默出错 (调用多带 2>/dev/null, 用户看不到失败)。
    check_root
    check_system
    ensure_runtime_deps

    # 非交互入口: install.sh <ws|xhttp|socks|reality> [vmess|vless]
    # h2 作为旧参数名保留为别名 (历史文档/用户脚本里可能还在用), 统一映射到 xhttp
    if [[ -n "${1:-}" ]]; then
        case "${1}" in
            ws|xhttp|h2)
                case "${1}" in
                    ws)    MODE="ws" ;;
                    *)     MODE="xhttp" ;;
                esac
                PROTOCOL="${2:-vmess}"
                [[ "${PROTOCOL}" != "vmess" && "${PROTOCOL}" != "vless" ]] && { log_error "协议只支持 vmess 或 vless"; exit 1; }
                do_install
                exit 0
                ;;
            socks)
                MODE="socks"
                do_install
                exit 0
                ;;
            reality)
                MODE="reality"
                PROTOCOL="vless"
                do_install
                exit 0
                ;;
            info)
                do_show_info
                exit 0
                ;;
            upgrade)
                do_upgrade_nodes
                exit 0
                ;;
            uninstall)
                do_uninstall
                exit 0
                ;;
        esac
    fi

    while true; do
        show_menu
        # stdin 已关闭(非交互/source 场景)时退出, 避免菜单死循环
        [[ -t 0 ]] || exit 0
        read -rp "按回车键返回菜单..." _
    done
}

main "$@"
