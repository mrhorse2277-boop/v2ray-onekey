#!/usr/bin/env bash
#
# v2ray-ws-tls-onekey —— V2Ray 多模式一键脚本
#
# 可同时安装、互不冲突:
#   1. vmess/vless + ws + tls + Nginx (443 端口, Nginx TLS 终结 + 伪装站)
#   2. vmess/vless + h2 + tls      (独立端口, V2Ray 直接监听 TLS, 不依赖 Nginx)
#   3. socks5                      (V2Ray socks 入站, 独立端口, 带用户名密码)
#   4. vless + REALITY             (Xray core, 抗封锁首选, 无需域名/证书)
#
# 每种模式独立 systemd 服务 (v2ray-ws / v2ray-h2 / v2ray-socks / xray-reality),
# 配置文件分离, 可任意组合安装、单独卸载, 端口互不占用。
#
# 分享链接适配最新版 v2rayN / v2rayNG。
#
# 支持系统: Debian 10+ / Ubuntu 18.04+ / CentOS 7+ (推荐 Debian 11+/Ubuntu 20.04+)
#
# 用法:
#   bash install.sh              交互式菜单
#   bash install.sh ws vmess     非交互安装 vmess+ws+tls
#   bash install.sh ws vless     非交互安装 vless+ws+tls
#   bash install.sh h2 vmess     非交互安装 vmess+h2+tls
#   bash install.sh h2 vless     非交互安装 vless+h2+tls
#   bash install.sh socks        非交互安装 socks5
#   bash install.sh reality      非交互安装 vless+REALITY
#   bash install.sh info         查看全部已安装节点
#   bash install.sh uninstall    交互卸载
#

export LC_ALL=C

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

V2RAY_CONF_DIR="/usr/local/etc/v2ray"
V2RAY_INSTALL_SCRIPT="https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh"

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

# --- h2 + tls 模式 (V2Ray 直接 TLS) ---
H2_CONF="${V2RAY_CONF_DIR}/config_h2.json"
H2_SERVICE="v2ray-h2"

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

DOMAIN=""
MODE=""                 # ws | h2 | socks | reality
PROTOCOL=""             # vmess | vless (socks/reality 模式下为空/固定)
UUID=""
INTERNAL_PORT=""
H2_PORT=""
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
check_reality_dest() {
    local dest="$1" sni="$2"
    if ! command -v openssl >/dev/null 2>&1; then
        return 0   # 无 openssl 时跳过强校验, 由用户自担
    fi
    local probe
    probe="$(echo | timeout 15 openssl s_client -connect "${dest}" -servername "${sni}" -alpn h2 -tls1_3 2>/dev/null)"
    if ! echo "${probe}" | grep -q "TLSv1.3\|TLS 1.3\|Protocol *: TLSv1.3"; then
        return 1
    fi
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

pause() { read -rp "按回车键继续..." _; }

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
}

install_dependencies() {
    log_info "安装基础依赖 (curl wget socat qrencode openssl cron)..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl wget socat qrencode openssl cron ca-certificates
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        # Rocky/Alma/Fedora: qrencode 在 EPEL (部分镜像已内置)
        dnf install -y epel-release >/dev/null 2>&1 || true
        dnf install -y curl wget socat qrencode openssl cronie || true
        command -v qrencode >/dev/null 2>&1 || dnf install -y qrencode >/dev/null 2>&1 || true
        systemctl enable --now crond >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        # CentOS 7 (EOL): 若官方源已归档失败, 不阻断; qrencode 在 EPEL
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y curl wget socat openssl cronie || true
        yum install -y qrencode >/dev/null 2>&1 || true
        systemctl enable --now crond >/dev/null 2>&1
    else
        log_error "未找到 apt-get / dnf / yum,无法自动安装依赖。"
        exit 1
    fi

    # 缺失项降级处理: 核心依赖必须存在, 次要依赖缺失仅告警
    local missing_core=""
    for c in curl wget openssl; do
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

# 探测系统现有 Nginx 环境 (宝塔面板 / 发行版 Nginx / 全新系统)
# 结果写入 NGINX_ENV / NGINX_BIN / NGINX_VHOST_DIR / NGINX_RELOAD_CMD / WS_NGINX_CONF
detect_nginx_env() {
    # 1) 宝塔面板: 使用宝塔自编译 Nginx, 配置写进其 vhost 目录
    if [[ -d "${BT_PANEL_DIR}" && -d "${BT_NGINX_VHOST_DIR}" && -x /www/server/nginx/sbin/nginx ]]; then
        NGINX_ENV="btpanel"
        NGINX_BIN="/www/server/nginx/sbin/nginx"
        NGINX_VHOST_DIR="${BT_NGINX_VHOST_DIR}"
        WS_NGINX_CONF="${NGINX_VHOST_DIR}/v2ray-ws-tls.conf"
        NGINX_RELOAD_CMD="${NGINX_BIN} -s reload"
        log_info "检测到宝塔面板,将复用宝塔 Nginx (不安装第二个 Nginx): ${NGINX_BIN}"
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
        [[ -n "${H2_PORT}" ]]      && ufw allow "${H2_PORT}/tcp"      >/dev/null 2>&1
        [[ -n "${SOCKS_PORT}" ]]   && ufw allow "${SOCKS_PORT}/tcp"   >/dev/null 2>&1
        [[ -n "${REALITY_PORT}" ]] && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1
        log_info "已通过 ufw 放行相关端口。"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http  >/dev/null 2>&1
        firewall-cmd --permanent --add-service=https >/dev/null 2>&1
        [[ -n "${H2_PORT}" ]]      && firewall-cmd --permanent --add-port="${H2_PORT}/tcp"      >/dev/null 2>&1
        [[ -n "${SOCKS_PORT}" ]]   && firewall-cmd --permanent --add-port="${SOCKS_PORT}/tcp"   >/dev/null 2>&1
        [[ -n "${REALITY_PORT}" ]] && firewall-cmd --permanent --add-port="${REALITY_PORT}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log_info "已通过 firewalld 放行相关端口。"
    fi
}

get_public_ip() {
    local ip=""
    ip="$(curl -4 -s --max-time 8 https://api.ip.sb/ip || true)"
    [[ -z "${ip}" ]] && ip="$(curl -4 -s --max-time 8 https://ifconfig.me || true)"
    [[ -z "${ip}" ]] && ip="$(curl -4 -s --max-time 8 https://api.ipify.org || true)"
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
    mkdir -p "${XRAY_CONF_DIR}"
}

# ---------- 证书 (ws 与 h2 共用 /data 下的证书) ----------

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
            --reloadcmd "bash -c '${NGINX_BIN} -s reload 2>/dev/null; systemctl reload nginx 2>/dev/null; systemctl restart ${WS_SERVICE} ${H2_SERVICE} 2>/dev/null; exit 0'"
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
    --reloadcmd "bash -c '${NGINX_BIN} -s reload 2>/dev/null; systemctl reload nginx 2>/dev/null; systemctl restart ${WS_SERVICE} ${H2_SERVICE} 2>/dev/null; exit 0'"
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
      "protocol": "freedom"
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
      "protocol": "freedom"
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

    echo "${config}" > "${WS_CONF}"
    chmod 600 "${WS_CONF}"
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
    cat > "/etc/systemd/system/${WS_SERVICE}.service" <<EOF
[Unit]
Description=V2Ray (ws+tls via nginx)
After=network.target nss-lookup.target

[Service]
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
    log_confirm "请输入你的域名 (例如 www.example.com,必须已解析 A 记录到本机):"
    read -rp "域名: " DOMAIN
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
        WS_PORT="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
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

    show_mode_info
    if [[ "${NGINX_ENV}" == "btpanel" ]]; then
        log_confirm "宝塔环境: 站点配置已写入 ${WS_NGINX_CONF},可在宝塔面板正常管理原有网站。"
    fi
    log_confirm "ws+tls 安装完成。"
}

# ---------- h2 + tls 模式 (V2Ray 直接监听 TLS, 独立端口, 不依赖 Nginx) ----------

write_h2_v2ray_config() {
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
      "port": ${H2_PORT},
      "listen": "0.0.0.0",
      ${protocol_block},
      "streamSettings": {
        "network": "h2",
        "security": "tls",
        "httpSettings": {
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
      "protocol": "freedom"
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

    echo "${config}" > "${H2_CONF}"
    chmod 600 "${H2_CONF}"
}

write_h2_service() {
    cat > "/etc/systemd/system/${H2_SERVICE}.service" <<EOF
[Unit]
Description=V2Ray (h2+tls direct)
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/v2ray run -config ${H2_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${H2_SERVICE}" >/dev/null 2>&1
}

do_install_h2() {
    echo
    log_confirm "请输入你的域名 (h2 需要 TLS 证书,必须已解析 A 记录到本机):"
    read -rp "域名: " DOMAIN
    DOMAIN="${DOMAIN//[$'\r\n']/}"
    DOMAIN="${DOMAIN,,}"
    if [[ -z "${DOMAIN}" ]] || ! check_domain "${DOMAIN}"; then
        log_error "域名校验未通过。"
        exit 1
    fi

    # h2 需要证书;若还没有,先探测 Nginx 环境、建伪装站并申请
    detect_nginx_env
    check_domain_conflict "${DOMAIN}"
    create_webroot
    ensure_v2ray
    issue_certificate

    UUID="$(gen_uuid)"
    H2_PORT="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
    record_port "${H2_PORT}"
    WS_PATH="$(gen_random 12)"
    CLIENT_REMARK="${DOMAIN}-${PROTOCOL}-h2"

    write_h2_v2ray_config
    write_h2_service
    write_ssl_update_script
    build_share_link
    open_firewall

    log_info "重启服务..."
    systemctl restart "${H2_SERVICE}"
    sleep 1

    if ! systemctl is-active --quiet "${H2_SERVICE}"; then
        log_error "${H2_SERVICE} 服务未正常运行:"
        journalctl -u "${H2_SERVICE}" --no-pager -n 20
        exit 1
    fi

    show_mode_info
    log_confirm "h2+tls 安装完成 (端口: ${H2_PORT},请在防火墙/安全组放行)。"
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
      "protocol": "freedom"
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

    echo "${config}" > "${SOCKS_CONF}"
    chmod 600 "${SOCKS_CONF}"
}

write_socks_service() {
    cat > "/etc/systemd/system/${SOCKS_SERVICE}.service" <<EOF
[Unit]
Description=V2Ray (socks5)
After=network.target nss-lookup.target

[Service]
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

    SOCKS_PORT="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
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
    systemctl restart "${SOCKS_SERVICE}"
    sleep 1

    if ! systemctl is-active --quiet "${SOCKS_SERVICE}"; then
        log_error "${SOCKS_SERVICE} 服务未正常运行:"
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
    # 香港 (大陆可达)
    "www.hkjc.com:443|香港"
    "www.octopus.com.hk:443|香港"
    "www.cathaypacific.com:443|香港"
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
    "www.microsoft.com:443|美国"
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
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null)" || tz="$(cat /etc/timezone 2>/dev/null)" || tz=""
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
    echo "  q. 放弃 (更换场景下原配置不动)"
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
        REALITY_PORT="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
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
            if [[ ! -t 0 && ${#ok_dests[@]} > 0 ]]; then
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
    systemctl restart "${REALITY_SERVICE}"
    sleep 1

    if ! systemctl is-active --quiet "${REALITY_SERVICE}"; then
        log_error "${REALITY_SERVICE} 服务未正常运行:"
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

    echo "${config}" > "${REALITY_CONF}"
    chmod 600 "${REALITY_CONF}"
}

write_reality_service() {
    cat > "/etc/systemd/system/${REALITY_SERVICE}.service" <<EOF
[Unit]
Description=Xray (vless + reality)
After=network.target nss-lookup.target

[Service]
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
        b64cred=$(printf '%s' "${cred}" | openssl base64 -A | tr -d '=' | tr '+/' '-_')
        get_public_ip
        host="${PUBLIC_IP:-127.0.0.1}"
        SHARE_URL="socks://${b64cred}@${host}:${SOCKS_PORT}#$(url_encode "${CLIENT_REMARK}")"
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

    if [[ "${MODE}" == "h2" ]]; then
        local port="${H2_PORT}" net="h2"
    else
        local port="${WS_PORT:-443}" net="ws"
    fi

    if [[ "${PROTOCOL}" == "vless" ]]; then
        # vless 标准 URI: encryption=none; h2 的 type 为 h2, path URL 编码
        local enc_path
        enc_path="$(url_encode "/${WS_PATH}")"
        SHARE_URL="vless://${UUID}@${DOMAIN}:${port}?type=${net}&security=tls&host=${DOMAIN}&path=${enc_path}&sni=${DOMAIN}&fp=chrome&encryption=none#$(url_encode "${CLIENT_REMARK}")"
    else
        # vmess v2 JSON base64; aid=0 走 AEAD, 带 scy/sni/fp 字段
        local json
        json=$(cat <<EOF
{
  "v": "2",
  "ps": "${CLIENT_REMARK}",
  "add": "${DOMAIN}",
  "port": "${port}",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "${net}",
  "type": "none",
  "host": "${DOMAIN}",
  "path": "/${WS_PATH}",
  "tls": "tls",
  "sni": "${DOMAIN}",
  "alpn": "",
  "fp": "chrome"
}
EOF
)
        local b64
        b64=$(printf '%s' "${json}" | openssl base64 -A | tr -d '=' | tr '+/' '-_')
        SHARE_URL="vmess://${b64}"
    fi
}

# ---------- 信息展示 ----------

append_info() {
    local section="$1"
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
        elif [[ "${MODE}" == "h2" ]]; then
            echo "domain=${DOMAIN}"
            echo "port=${H2_PORT}"
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
    echo -e " 端口        : $([[ "${MODE}" == "ws" ]] && echo "${WS_PORT:-443}" || { [[ "${MODE}" == "h2" ]] && echo "${H2_PORT}" || echo "${SOCKS_PORT}"; })"
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
    echo -e "${GREEN}==========================================${PLAIN}"

    append_info "$([[ "${PROTOCOL}" ]] && echo "${PROTOCOL}+${MODE}" || echo "${MODE}")"

    # 追加到总链接文件
    echo "${SHARE_URL}" >> "${URL_FILE}"

    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${BLUE}客户端扫码导入:${PLAIN}"
        echo "${SHARE_URL}" | qrencode -t ANSIUTF8
    fi
}

do_show_info() {
    get_public_ip
    if [[ ! -f "${INFO_FILE}" ]]; then
        log_warn "未找到已安装的配置信息 (${INFO_FILE})。"
        return
    fi
    clear
    echo -e "${GREEN}================ 已安装节点 ================${PLAIN}"
    local section="" line url=""
    while IFS= read -r line; do
        case "${line}" in
            "### "*)
                if [[ -n "${url}" ]]; then
                    echo -e " 分享链接: ${url}"
                    echo
                    echo "${url}" >> "${URL_FILE}"
                fi
                section="${line#\#\# }"
                url=""
                echo -e "${GREEN}--- ${section} ---${PLAIN}"
                ;;
            share_url=*) url="${line#share_url=}" ;;
            domain=*|port=*|uuid=*|socks_user=*|socks_pass=*|path=*|address=*|dest=*|sni=*)
                if [[ "${line}" == socks_pass=* ]]; then
                    echo -e " ${line%%=*}     : ${line#*=}"
                else
                    echo -e " ${line%%=*}"$([[ "${#line%%=*}" -lt 10 ]] && printf '%*s' $((10 - ${#line%%=*})) "")": ${line#*=}"
                fi
                ;;
        esac
    done < "${INFO_FILE}"
    if [[ -n "${url}" ]]; then
        echo -e " 分享链接: ${url}"
        echo "${url}" >> "${URL_FILE}"
    fi
    echo -e "${GREEN}=============================================${PLAIN}"
    log_confirm "全部分享链接已导出到: ${URL_FILE}"
}

# ---------- 卸载 ----------

do_uninstall() {
    check_root
    echo "当前已安装的服务:"
    for svc in "${WS_SERVICE}" "${H2_SERVICE}" "${SOCKS_SERVICE}" "${REALITY_SERVICE}"; do
        if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            local state="未运行"
            systemctl is-active --quiet "${svc}" && state="运行中"
            echo "  - ${svc} (${state})"
        fi
    done
    echo
    echo "请选择要卸载的模式:"
    echo "  1. ws+tls (v2ray-ws + nginx 配置)"
    echo "  2. h2+tls (v2ray-h2)"
    echo "  3. socks5 (v2ray-socks)"
    echo "  4. vless+REALITY (xray-reality)"
    echo "  5. 全部卸载"
    echo "  0. 取消"
    read -rp "请选择: " choice

    case "${choice}" in
        1)
            systemctl disable --now "${WS_SERVICE}" >/dev/null 2>&1
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
            systemctl disable --now "${H2_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${H2_SERVICE}.service" "${H2_CONF}"
            sed -i '/### vmess+h2/,/^$/d;/### vless+h2/,/^$/d' "${INFO_FILE}" 2>/dev/null
            ;;
        3)
            systemctl disable --now "${SOCKS_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${SOCKS_SERVICE}.service" "${SOCKS_CONF}"
            sed -i '/### socks5/,/^$/d' "${INFO_FILE}" 2>/dev/null
            ;;
        4)
            systemctl disable --now "${REALITY_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${REALITY_SERVICE}.service" "${REALITY_CONF}"
            sed -i '/### reality/,/^$/d' "${INFO_FILE}" 2>/dev/null
            ;;
        5)
            systemctl disable --now "${WS_SERVICE}" "${H2_SERVICE}" "${SOCKS_SERVICE}" "${REALITY_SERVICE}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${WS_SERVICE}.service" "/etc/systemd/system/${H2_SERVICE}.service" \
                  "/etc/systemd/system/${SOCKS_SERVICE}.service" "/etc/systemd/system/${REALITY_SERVICE}.service"
            rm -f "${WS_NGINX_CONF}" "/etc/nginx/conf.d/v2ray-ws-tls.conf" "${BT_NGINX_VHOST_DIR}/v2ray-ws-tls.conf" \
                  "${WS_CONF}" "${H2_CONF}" "${SOCKS_CONF}" "${REALITY_CONF}" \
                  "${INFO_FILE}" "${URL_FILE}" "${SSL_UPDATE_SH}"
            if command -v v2ray >/dev/null 2>&1 && [[ -f /usr/local/bin/v2ray-uninstall ]]; then
                bash /usr/local/bin/v2ray-uninstall || true
            fi
            if command -v xray >/dev/null 2>&1 && [[ -f /usr/local/bin/xray-uninstall ]]; then
                bash /usr/local/bin/xray-uninstall || true
            fi
            # 平滑重载 Nginx (宝塔或发行版), 绝不 stop 现有网站服务
            if [[ "${NGINX_ENV}" == "btpanel" && -x "${NGINX_BIN}" ]]; then
                "${NGINX_BIN}" -t >/dev/null 2>&1 && "${NGINX_BIN}" -s reload
            elif command -v nginx >/dev/null 2>&1; then
                nginx -t >/dev/null 2>&1 && systemctl reload nginx
            fi
            log_info "全部卸载完成。证书 (acme.sh / ${CERT_DIR}) 与伪装站点目录保留,如需彻底清理请手动删除。"
            systemctl daemon-reload
            return
            ;;
        *) return ;;
    esac
    systemctl daemon-reload
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
    echo "  0. 取消"
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
        new_port="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
        sed -i "s/\"port\": ${old_port},/\"port\": ${new_port},/" "${REALITY_CONF}"
        changed+=("端口 ${old_port} -> ${new_port}")
        record_port "${new_port}"
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

    systemctl restart "${REALITY_SERVICE}"
    sleep 1
    if ! systemctl is-active --quiet "${REALITY_SERVICE}"; then
        log_error "服务重启失败,回滚配置:"
        mv "${REALITY_CONF}.bak" "${REALITY_CONF}"
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
    echo "${new_url}" >> "${URL_FILE}"

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
    log_confirm "客户端请删除旧节点并导入上面的新链接 (旧链接已失效)。"
}

# 重置 ws/h2/socks 节点要素: 选模式 -> 选要素 -> 改配置重启 -> 失败回滚 -> 重建分享链接
do_reset_node() {
    check_root
    echo "请选择要重置的节点模式:"
    echo "  1. ws+tls   (v2ray-ws)"
    echo "  2. h2+tls   (v2ray-h2)"
    echo "  3. socks5   (v2ray-socks)"
    echo "  0. 取消"
    read -rp "请选择: " mode_pick || return

    local conf svc svc_label port_var old_port new_port new_uuid new_user new_pass
    local is_socks=0
    case "${mode_pick}" in
        1) conf="${WS_CONF}";   svc="${WS_SERVICE}";   svc_label="ws+tls" ;;
        2) conf="${H2_CONF}";   svc="${H2_SERVICE}";   svc_label="h2+tls" ;;
        3) conf="${SOCKS_CONF}"; svc="${SOCKS_SERVICE}"; svc_label="socks5"; is_socks=1 ;;
        *) return ;;
    esac
    if [[ ! -f "${conf}" || ! -f "/etc/systemd/system/${svc}.service" ]]; then
        log_error "未安装 ${svc_label} 模式,请先安装。"
        return
    fi

    echo
    if [[ "${is_socks}" == "1" ]]; then
        echo "请选择要重置的项目:"
        echo "  1. 仅更换端口"
        echo "  2. 仅更换用户名/密码"
        echo "  3. 端口 + 用户名/密码 全部重置"
        echo "  0. 取消"
        read -rp "请选择: " elem_pick || return
        case "${elem_pick}" in
            1) reset_port=1 ;;
            2) reset_creds=1 ;;
            3) reset_port=1; reset_creds=1 ;;
            *) return ;;
        esac
    else
        echo "请选择要重置的项目:"
        echo "  1. 仅更换端口"
        echo "  2. 仅更换 UUID"
        echo "  3. 端口 + UUID 全部重置"
        echo "  0. 取消"
        read -rp "请选择: " elem_pick || return
        case "${elem_pick}" in
            1) reset_port=1 ;;
            2) reset_uuid=1 ;;
            3) reset_port=1; reset_uuid=1 ;;
            *) return ;;
        esac
    fi

    cp "${conf}" "${conf}.bak"
    local changed=()

    if [[ "${is_socks}" == "1" ]]; then
        old_port="$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')"
        if [[ "${reset_port:-0}" == "1" ]]; then
            new_port="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
            sed -i "s/\"port\": ${old_port},/\"port\": ${new_port},/" "${conf}"
            SOCKS_PORT="${new_port}"
            changed+=("端口 ${old_port} -> ${new_port}")
            record_port "${new_port}"
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
            new_port="$(gen_port "${V2RAY_CONF_DIR}/used_ports.txt")"
            sed -i "s/\"port\": ${old_port},/\"port\": ${new_port},/" "${conf}"
            if [[ "${mode_pick}" == "1" ]]; then
                # ws 模式: 配置内部端口 + nginx 反代目标端口都要改
                sed -i "s|proxy_pass http://127.0.0.1:${old_port};|proxy_pass http://127.0.0.1:${new_port};|" "${WS_NGINX_CONF}"
                INTERNAL_PORT="${new_port}"
                log_info "ws 模式: nginx 反代目标已同步更新为 ${new_port} (nginx 配置将一并 reload)。"
            else
                H2_PORT="${new_port}"
                INTERNAL_PORT="${new_port}"
            fi
            changed+=("端口 ${old_port} -> ${new_port}")
            record_port "${new_port}"
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

    systemctl restart "${svc}"
    if [[ "${mode_pick}" == "1" ]]; then
        nginx_check_reload 2>/dev/null || true
    fi
    sleep 1
    if ! systemctl is-active --quiet "${svc}"; then
        log_error "服务重启失败,回滚配置:"
        mv "${conf}.bak" "${conf}"
        if [[ "${mode_pick}" == "1" && "${reset_port:-0}" == "1" ]]; then
            sed -i "s|proxy_pass http://127.0.0.1:${new_port};|proxy_pass http://127.0.0.1:${old_port};|" "${WS_NGINX_CONF}"
        fi
        systemctl restart "${svc}"
        journalctl -u "${svc}" --no-pager -n 10
        return 1
    fi
    rm -f "${conf}.bak"

    if [[ "${reset_port:-0}" == "1" ]]; then
        open_firewall
    fi

    # 重建分享链接: 从当前配置读取参数复用 build_share_link 的变量约定
    if [[ "${is_socks}" == "1" ]]; then
        MODE="socks"; PROTOCOL=""
        # 端口/凭据未重置时, 从配置补齐全局变量 (本次会话可能未安装过该模式)
        SOCKS_PORT="${SOCKS_PORT:-$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')}"
        SOCKS_USER="${SOCKS_USER:-$(grep -o '"user": "[^"]*"' "${conf}" | cut -d'"' -f4)}"
        SOCKS_PASS="${SOCKS_PASS:-$(grep -o '"pass": "[^"]*"' "${conf}" | cut -d'"' -f4)}"
        CLIENT_REMARK="${CLIENT_REMARK:-socks5-node}"
    else
        MODE="${mode_pick}"; PROTOCOL="vless"
        # 域名/路径/端口全部从 info 文件与当前配置恢复 (与实际部署一致, 不依赖本次会话状态)
        local section_key="${svc_label%%+*}"
        local infoblock
        infoblock="$(awk -v s="### .*${section_key}" 'BEGIN{IGNORECASE=0} $0 ~ s {f=1} f && /^### / && $0 !~ s {f=0} f' "${INFO_FILE}" 2>/dev/null)"
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
            H2_PORT="$(grep -o '"port": [0-9]*' "${conf}" | head -1 | grep -o '[0-9]*')"
        fi
        CLIENT_REMARK="${DOMAIN}-${PROTOCOL}-${svc_label%%+*}"
    fi
    build_share_link
    echo "${SHARE_URL}" >> "${URL_FILE}"

    echo
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}   ${svc_label} 节点重置完成                   ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    local c
    for c in "${changed[@]}"; do
        echo -e " - ${c}"
    done
    echo -e " 新链接   : ${SHARE_URL}"
    echo -e "${GREEN}==========================================${PLAIN}"
    log_confirm "客户端请删除旧节点并导入上面的新链接 (旧链接已失效)。"
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
    local cur_port
    cur_port="$(grep -o '"port": [0-9]*' "${REALITY_CONF}" | head -1 | grep -o '[0-9]*')"
    log_info "当前伪装站: ${cur_dest} (端口 ${cur_port})"

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

    # 仅改 dest/sni, 保留 port/uuid/密钥/sid
    sed -i "s|\"dest\": \"${cur_dest}\"|\"dest\": \"${REALITY_DEST}\"|" "${REALITY_CONF}"
    sed -i "s|\"${cur_dest##*:}\"|\"${REALITY_SNI}\"|" "${REALITY_CONF}"
    systemctl restart "${REALITY_SERVICE}"
    sleep 1
    if ! systemctl is-active --quiet "${REALITY_SERVICE}"; then
        log_error "服务重启失败,回滚配置:"
        sed -i "s|\"dest\": \"${REALITY_DEST}\"|\"dest\": \"${cur_dest}\"|" "${REALITY_CONF}"
        sed -i "s|\"${REALITY_SNI}\"|\"${cur_dest##*:}\"|" "${REALITY_CONF}"
        systemctl restart "${REALITY_SERVICE}"
        journalctl -u "${REALITY_SERVICE}" --no-pager -n 10
        return 1
    fi

    # 更新 info 文件并输出新链接: 直接从当前配置读全部参数生成 (不依赖 URL_FILE 历史条目)
    local uuid cur_pubkey cur_sid
    uuid="$(grep -o '"id": "[^"]*"' "${REALITY_CONF}" | head -1 | cut -d'"' -f4)"
    # shortIds 是多行数组, 用 -A1 抓第一个值
    cur_sid="$(grep -A1 '"shortIds"' "${REALITY_CONF}" | grep -o '"[0-9a-f]*"' | tr -d '"' | head -1)"
    cur_pubkey="$(grep reality "${URL_FILE}" 2>/dev/null | tail -1 | grep -o 'pbk=[^&]*' | cut -d= -f2)"
    if [[ -z "${cur_pubkey}" ]]; then
        local privkey
        privkey="$(grep -o '"privateKey": "[^"]*"' "${REALITY_CONF}" | cut -d'"' -f4)"
        cur_pubkey="$("${NGINX_BIN:-/usr/local/bin/xray}" x25519 -i "${privkey}" 2>/dev/null | awk '/Public key|Password/{print $NF}')"
    fi
    local ip
    ip="$(curl -4 -s --max-time 8 https://api.ip.sb/ip || curl -4 -s --max-time 8 https://api.ipify.org)"
    ip="${ip//[$'\r\n']/}"
    new_url="vless://${uuid}@${ip}:${cur_port}?type=tcp&security=reality&pbk=${cur_pubkey}&sid=${cur_sid}&sni=${REALITY_SNI}&fp=chrome&flow=xtls-rprx-vision&encryption=none#${REALITY_SNI}-reality"
    echo "${new_url}" >> "${URL_FILE}"

    echo
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}   伪装站已更换 (UUID/端口/密钥不变)      ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e " 新伪装站 : ${REALITY_DEST}"
    echo -e " 新链接   : ${new_url}"
    echo -e "${GREEN}==========================================${PLAIN}"
    log_confirm "客户端只需把该节点的 SNI 改为 ${REALITY_SNI} (或删旧导新上面的链接)。"
    log_confirm "同时请更新本地直连验证: 你所在网络需能正常访问 ${REALITY_SNI}。"
}


do_update_v2ray() {
    check_root
    log_info "更新 V2Ray core..."
    bash <(curl -L -s "${V2RAY_INSTALL_SCRIPT}")
    log_info "更新 Xray core..."
    bash <(curl -L -s "${XRAY_INSTALL_SCRIPT}")
    systemctl restart "${WS_SERVICE}" "${H2_SERVICE}" "${SOCKS_SERVICE}" "${REALITY_SERVICE}" 2>/dev/null
    log_info "V2Ray / Xray 已更新,相关服务已重启。"
}

# ---------- 安装流程调度 ----------

do_install() {
    check_root
    check_system
    install_dependencies

    case "${MODE}" in
        ws)      do_install_ws ;;
        h2)      do_install_h2 ;;
        socks)   do_install_socks ;;
        reality) do_install_reality ;;
    esac
}

# ---------- 菜单 ----------

show_menu() {
    clear
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}          V2Ray/Xray 多模式一键脚本                 ${PLAIN}"
    echo -e "${GREEN}  ws/h2/socks5/REALITY 可同时安装互不冲突           ${PLAIN}"
    echo -e "${GREEN}          适配最新版 v2rayN / v2rayNG               ${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e " 1. 安装  vmess + ws  + tls  (Nginx 伪装站, 443)"
    echo -e " 2. 安装  vless + ws  + tls  (Nginx 伪装站, 443)"
    echo -e " 3. 安装  vmess + h2  + tls  (V2Ray 直连, 独立端口)"
    echo -e " 4. 安装  vless + h2  + tls  (V2Ray 直连, 独立端口)"
    echo -e " 5. 安装  socks5             (独立端口, 带认证)"
    echo -e " 6. 安装  vless + REALITY    (Xray, 抗封锁首选, 免域名证书)"
    echo -e " 7. 查看已安装节点 / 导出全部分享链接"
    echo -e " 8. 手动续签 / 重新申请证书"
    echo -e " 9. 更新 V2Ray / Xray core"
    echo -e "10. 更换 REALITY 伪装站 (保留 UUID/端口, 客户端只改 SNI)"
    echo -e "11. 重置 REALITY 节点 (端口 / UUID / 密钥 / 全部)"
    echo -e "12. 重置 ws/h2/socks 节点 (端口 / UUID / 用户密码)"
    echo -e "13. 卸载 (可选单模式或全部)"
    echo -e " 0. 退出"
    echo
    read -rp "请选择: " choice || exit 0
    case "${choice}" in
        1) MODE="ws";      PROTOCOL="vmess"; do_install ;;
        2) MODE="ws";      PROTOCOL="vless"; do_install ;;
        3) MODE="h2";      PROTOCOL="vmess"; do_install ;;
        4) MODE="h2";      PROTOCOL="vless"; do_install ;;
        5) MODE="socks";   PROTOCOL="";      do_install ;;
        6) MODE="reality"; PROTOCOL="vless"; do_install ;;
        7) do_show_info ;;
        8) do_renew_cert ;;
        9) do_update_v2ray ;;
        10) do_change_reality_dest ;;
        11) do_reset_reality ;;
        12) do_reset_node ;;
        13) do_uninstall ;;
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

main() {
    # 非交互入口: install.sh <ws|h2|socks|reality> [vmess|vless]
    if [[ -n "${1:-}" ]]; then
        case "${1}" in
            ws|h2)
                MODE="${1}"
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
