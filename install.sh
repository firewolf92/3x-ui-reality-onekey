#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROJECT_DIR="/etc/3xui-onekey"
STATE_FILE="$PROJECT_DIR/config.env"
CLIENT_FILE="$PROJECT_DIR/client-link.txt"
SITE_ROOT="/var/www/onekey-site"
XRAY_INTERNAL_PORT_DEFAULT="2443"
CADDY_TLS_PORT_DEFAULT="8443"
REALITY_SNI_DEFAULT="www.microsoft.com"
REALITY_PORT="443"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() { rm -f /tmp/3xui-onekey-cookie.txt; }
trap cleanup EXIT
trap 'die "安装过程中发生错误（行 $LINENO）。请保存屏幕输出后再排查，不要重复强行安装。"' ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户执行。"
}

load_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  case "$OS_ID" in
    debian|ubuntu) ;;
    *) die "当前仅支持 Debian/Ubuntu，检测到: $OS_ID" ;;
  esac
}

random_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(shuf -i 20000-45000 -n 1)
    if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${p}$"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

prompt_values() {
  SITE_DOMAIN="${SITE_DOMAIN:-}"
  PANEL_DOMAIN="${PANEL_DOMAIN:-}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  REALITY_SNI="${REALITY_SNI:-$REALITY_SNI_DEFAULT}"

  if [[ -t 0 ]]; then
    [[ -n "$SITE_DOMAIN" ]] || read -r -p "正常网站域名（例如 example.com）: " SITE_DOMAIN
    [[ -n "$PANEL_DOMAIN" ]] || read -r -p "面板域名（例如 panel.example.com）: " PANEL_DOMAIN
    [[ -n "$ACME_EMAIL" ]] || read -r -p "证书联系邮箱: " ACME_EMAIL
    read -r -p "Reality SNI [${REALITY_SNI}]: " _sni || true
    [[ -z "${_sni:-}" ]] || REALITY_SNI="$_sni"
  fi

  [[ "$SITE_DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || die "SITE_DOMAIN 格式不正确。"
  [[ "$PANEL_DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || die "PANEL_DOMAIN 格式不正确。"
  [[ "$REALITY_SNI" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || die "REALITY_SNI 格式不正确。"
  [[ "$SITE_DOMAIN" != "$PANEL_DOMAIN" ]] || die "站点域名和面板域名不能相同。"
  [[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "ACME_EMAIL 格式不正确。"
}

preflight_clean_host() {
  if [[ -e /etc/x-ui/x-ui.db || -e /usr/local/x-ui ]]; then
    die "检测到现有 3x-ui/x-ui。第一版仅支持干净 VPS，为避免覆盖现有配置已停止。"
  fi
  if systemctl list-unit-files 2>/dev/null | grep -Eq '^(caddy|haproxy)\.service'; then
    die "检测到已有 Caddy/HAProxy。第一版不会覆盖已有反代配置。"
  fi
  if command -v ss >/dev/null 2>&1; then
    local used
    used=$(ss -ltnH | awk '{print $4}' | grep -E '(:80|:443)$' || true)
    [[ -z "$used" ]] || die "端口 80/443 已被占用:\n$used"
  fi
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl jq openssl iproute2 dnsutils ufw haproxy debian-keyring debian-archive-keyring apt-transport-https
  systemctl stop haproxy 2>/dev/null || true
}

install_caddy() {
  if apt-cache show caddy >/dev/null 2>&1; then
    apt-get install -y caddy
  else
    log "系统源没有 Caddy，切换到 Caddy 官方软件源。"
    apt-get install -y gnupg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y
    apt-get install -y caddy
  fi
  systemctl stop caddy 2>/dev/null || true
}

get_public_ipv4() {
  PUBLIC_IPV4=$(curl -4fsS --max-time 10 https://api.ipify.org || true)
  if [[ ! "$PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    PUBLIC_IPV4=$(curl -4fsS --max-time 10 https://ipv4.icanhazip.com | tr -d '[:space:]' || true)
  fi
  [[ "$PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "无法获取 VPS 公网 IPv4。"
}

verify_dns() {
  local domain="$1" ips
  ips=$(dig +short A "$domain" | tr -d '\r' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)
  grep -Fxq "$PUBLIC_IPV4" <<<"$ips" || die "$domain 当前没有直接解析到 $PUBLIC_IPV4。请检查 A 记录；Cloudflare 首次部署请使用 DNS only（灰云）。"
}

install_3xui() {
  PANEL_PORT=$(random_port) || die "无法找到可用的随机面板端口。"
  PANEL_USER="admin_$(openssl rand -hex 4)"
  PANEL_PASSWORD=$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'Aa' | cut -c1-28)
  PANEL_BASE="/$(openssl rand -hex 10)/"

  log "安装 3x-ui 官方稳定版（无人值守模式）..."
  XUI_NONINTERACTIVE=1   XUI_USERNAME="$PANEL_USER"   XUI_PASSWORD="$PANEL_PASSWORD"   XUI_PANEL_PORT="$PANEL_PORT"   XUI_WEB_BASE_PATH="$PANEL_BASE"   XUI_SSL_MODE=none   bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

  [[ -r /etc/x-ui/install-result.env ]] || die "3x-ui 安装结果文件缺失。"
  systemctl is-active --quiet x-ui || die "3x-ui 服务未正常启动。"
}

wait_panel() {
  local url="http://127.0.0.1:${PANEL_PORT}${PANEL_BASE}"
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "3x-ui 面板在本机端口没有正常响应。"
}

panel_login() {
  PANEL_LOCAL="http://127.0.0.1:${PANEL_PORT}${PANEL_BASE%/}"
  local payload response
  payload=$(jq -n --arg u "$PANEL_USER" --arg p "$PANEL_PASSWORD" '{username:$u,password:$p}')
  response=$(curl -fsS -c /tmp/3xui-onekey-cookie.txt -H 'Content-Type: application/json' --data "$payload" "$PANEL_LOCAL/login")
  jq -e '.success == true' <<<"$response" >/dev/null || die "3x-ui API 登录失败: $response"
}

create_reality_inbound() {
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 8)
  CLIENT_EMAIL="default-$(openssl rand -hex 3)"
  XRAY_INTERNAL_PORT="$XRAY_INTERNAL_PORT_DEFAULT"

  local key_json private_key public_key payload response
  key_json=$(curl -fsS -b /tmp/3xui-onekey-cookie.txt "$PANEL_LOCAL/panel/api/server/getNewX25519Cert")
  jq -e '.success == true' <<<"$key_json" >/dev/null || die "Reality X25519 密钥生成失败: $key_json"
  private_key=$(jq -r '.obj.privateKey' <<<"$key_json")
  public_key=$(jq -r '.obj.publicKey' <<<"$key_json")
  [[ -n "$private_key" && "$private_key" != null && -n "$public_key" && "$public_key" != null ]] || die "Reality 密钥为空。"

  payload=$(jq -n     --arg uuid "$UUID" --arg email "$CLIENT_EMAIL" --arg sni "$REALITY_SNI"     --arg priv "$private_key" --arg pub "$public_key" --arg sid "$SHORT_ID"     --argjson port "$XRAY_INTERNAL_PORT"     '{
      enable:true,remark:"onekey-reality-443",listen:"127.0.0.1",port:$port,protocol:"vless",expiryTime:0,total:0,
      settings:{clients:[{id:$uuid,email:$email,flow:"xtls-rprx-vision",enable:true,expiryTime:0,totalGB:0,limitIp:0,subId:""}],decryption:"none",fallbacks:[]},
      streamSettings:{network:"tcp",security:"reality",tcpSettings:{header:{type:"none"}},realitySettings:{
        show:false,xver:0,target:($sni + ":443"),serverNames:[$sni],privateKey:$priv,minClientVer:"",maxClientVer:"",maxTimediff:0,
        shortIds:[$sid],mldsa65Seed:"",settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/",mldsa65Verify:""}
      }},
      sniffing:{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}
    }')

  response=$(curl -fsS -b /tmp/3xui-onekey-cookie.txt -H 'Content-Type: application/json' --data "$payload" "$PANEL_LOCAL/panel/api/inbounds/add")
  jq -e '.success == true' <<<"$response" >/dev/null || die "创建 Reality 入站失败: $response"
  REALITY_PUBLIC_KEY="$public_key"

  for _ in $(seq 1 20); do
    if ss -ltnH | awk '{print $4}' | grep -Eq "(:|\\])${XRAY_INTERNAL_PORT}$"; then return 0; fi
    sleep 1
  done
  die "Reality 入站已写入面板，但 Xray 内部端口没有启动。"
}

create_site() {
  install -d -m 0755 "$SITE_ROOT"
  cat > "$SITE_ROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="index,follow"><title>Aster Systems</title>
<meta name="description" content="Independent software and infrastructure studio.">
<style>
:root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;font:16px/1.6 system-ui,-apple-system,Segoe UI,sans-serif;background:#f7f7f5;color:#1b1b1b}.wrap{max-width:980px;margin:auto;padding:64px 24px}.nav{display:flex;justify-content:space-between;align-items:center}.brand{font-weight:700;letter-spacing:.06em}.hero{padding:120px 0 90px}.hero h1{font-size:clamp(42px,8vw,82px);line-height:1.02;margin:0 0 24px;max-width:850px}.hero p{max-width:620px;color:#555;font-size:19px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:18px}.card{padding:24px;border:1px solid #ddd;border-radius:18px;background:#fff}.card h2{font-size:18px;margin:0 0 8px}.footer{padding:80px 0 20px;color:#777;font-size:14px}@media(prefers-color-scheme:dark){body{background:#111;color:#eee}.hero p{color:#aaa}.card{background:#171717;border-color:#333}.footer{color:#888}}
</style>
</head><body><main class="wrap">
<nav class="nav"><div class="brand">ASTER SYSTEMS</div><div>Independent studio</div></nav>
<section class="hero"><h1>Software, systems and practical infrastructure.</h1><p>We build focused digital tools and reliable infrastructure for small teams and independent projects.</p></section>
<section class="grid"><article class="card"><h2>Software</h2><p>Small, maintainable applications designed around real workflows.</p></article><article class="card"><h2>Infrastructure</h2><p>Simple deployments, observability and operational automation.</p></article><article class="card"><h2>Research</h2><p>Prototype-driven technical research with clear documentation.</p></article></section>
<footer class="footer">© <span id="y"></span> Aster Systems</footer></main>
<script>document.getElementById('y').textContent=new Date().getFullYear()</script></body></html>
HTML
  printf 'User-agent: *\nAllow: /\n' > "$SITE_ROOT/robots.txt"
}

configure_caddy() {
  CADDY_TLS_PORT="$CADDY_TLS_PORT_DEFAULT"
  cat > /etc/caddy/Caddyfile <<EOF_CADDY
{
    email ${ACME_EMAIL}
    auto_https disable_redirects
    http_port 80
    https_port ${CADDY_TLS_PORT}
}
http://${SITE_DOMAIN} { redir https://${SITE_DOMAIN}{uri} permanent }
http://${PANEL_DOMAIN} { redir https://${PANEL_DOMAIN}{uri} permanent }
${SITE_DOMAIN} {
    root * ${SITE_ROOT}
    encode zstd gzip
    file_server
}
${PANEL_DOMAIN} {
    reverse_proxy 127.0.0.1:${PANEL_PORT}
}
EOF_CADDY

  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  systemctl enable --now caddy
  for _ in $(seq 1 45); do
    if ss -ltnH | awk '{print $4}' | grep -Eq "(:|\\])${CADDY_TLS_PORT}$"; then return 0; fi
    sleep 1
  done
  journalctl -u caddy -n 80 --no-pager >&2 || true
  die "Caddy 没有在内部 TLS 端口启动。"
}

configure_haproxy() {
  cat > /etc/haproxy/haproxy.cfg <<EOF_HAPROXY
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 4096
defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1m
    timeout server 1m
frontend tls_mux
    bind *:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl is_site req_ssl_sni -i ${SITE_DOMAIN}
    acl is_panel req_ssl_sni -i ${PANEL_DOMAIN}
    use_backend caddy_tls if is_site
    use_backend caddy_tls if is_panel
    default_backend xray_reality
backend caddy_tls
    mode tcp
    server caddy 127.0.0.1:${CADDY_TLS_PORT} check
backend xray_reality
    mode tcp
    server xray 127.0.0.1:${XRAY_INTERNAL_PORT} check
EOF_HAPROXY
  haproxy -c -f /etc/haproxy/haproxy.cfg
  systemctl enable haproxy
  systemctl restart haproxy
  systemctl is-active --quiet haproxy || die "HAProxy 启动失败。"
}

configure_firewall() {
  local ssh_port="22"
  if [[ -n "${SSH_CONNECTION:-}" ]]; then ssh_port=$(awk '{print $4}' <<<"$SSH_CONNECTION"); fi
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || ssh_port=22
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "${ssh_port}/tcp" >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
  UFW_SSH_PORT="$ssh_port"
}

save_state() {
  install -d -m 0700 "$PROJECT_DIR"
  cat > "$STATE_FILE" <<EOF_STATE
SITE_DOMAIN=${SITE_DOMAIN}
PANEL_DOMAIN=${PANEL_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
PUBLIC_IPV4=${PUBLIC_IPV4}
PANEL_PORT=${PANEL_PORT}
PANEL_USER=${PANEL_USER}
PANEL_PASSWORD=${PANEL_PASSWORD}
PANEL_BASE=${PANEL_BASE}
XRAY_INTERNAL_PORT=${XRAY_INTERNAL_PORT}
CADDY_TLS_PORT=${CADDY_TLS_PORT}
REALITY_SNI=${REALITY_SNI}
UUID=${UUID}
SHORT_ID=${SHORT_ID}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
UFW_SSH_PORT=${UFW_SSH_PORT}
EOF_STATE
  chmod 600 "$STATE_FILE"
  CLIENT_LINK="vless://${UUID}@${SITE_DOMAIN}:${REALITY_PORT}?type=tcp&security=reality&sni=${REALITY_SNI}&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&fp=chrome&spx=%2F&flow=xtls-rprx-vision#onekey-reality"
  printf '%s\n' "$CLIENT_LINK" > "$CLIENT_FILE"
  chmod 600 "$CLIENT_FILE"
}

install_helpers() {
  curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/status.sh -o /usr/local/sbin/onekey-status
  curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/update.sh -o /usr/local/sbin/onekey-update
  curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/uninstall.sh -o /usr/local/sbin/onekey-uninstall
  chmod 0755 /usr/local/sbin/onekey-status /usr/local/sbin/onekey-update /usr/local/sbin/onekey-uninstall
}

health_check() {
  systemctl is-active --quiet x-ui || die "健康检查失败: x-ui 未运行。"
  systemctl is-active --quiet caddy || die "健康检查失败: caddy 未运行。"
  systemctl is-active --quiet haproxy || die "健康检查失败: haproxy 未运行。"
  ss -ltnH | awk '{print $4}' | grep -Eq '(:|\])443$' || die "健康检查失败: 公网 443 未监听。"
  ss -ltnH | awk '{print $4}' | grep -Eq "(:|\\])${XRAY_INTERNAL_PORT}$" || die "健康检查失败: Xray 内部端口未监听。"
  ss -ltnH | awk '{print $4}' | grep -Eq "(:|\\])${CADDY_TLS_PORT}$" || die "健康检查失败: Caddy 内部 TLS 端口未监听。"
  curl -fsS --resolve "${SITE_DOMAIN}:443:127.0.0.1" "https://${SITE_DOMAIN}/" >/dev/null || die "健康检查失败: HTTPS 网站不可访问。"
  curl -fsS --resolve "${PANEL_DOMAIN}:443:127.0.0.1" "https://${PANEL_DOMAIN}${PANEL_BASE}" >/dev/null || die "健康检查失败: HTTPS 面板不可访问。"
}

print_summary() {
  cat <<EOF_SUMMARY

============================================================
  3x-ui Reality OneKey 部署完成
============================================================
网站：      https://${SITE_DOMAIN}/
面板：      https://${PANEL_DOMAIN}${PANEL_BASE}
面板用户：  ${PANEL_USER}
面板密码：  ${PANEL_PASSWORD}

协议：      VLESS + REALITY + XTLS-Vision
公网端口：  443
Reality SNI: ${REALITY_SNI}
UUID：      ${UUID}
Public Key：${REALITY_PUBLIC_KEY}
Short ID：  ${SHORT_ID}

客户端链接：
${CLIENT_LINK}

状态： onekey-status
升级： onekey-update
卸载： onekey-uninstall
============================================================
EOF_SUMMARY
}

main() {
  require_root
  load_os
  prompt_values
  preflight_clean_host
  log "安装基础依赖..."
  install_base_packages
  install_caddy
  get_public_ipv4
  log "检测到 VPS IPv4: $PUBLIC_IPV4"
  verify_dns "$SITE_DOMAIN"
  verify_dns "$PANEL_DOMAIN"
  install_3xui
  wait_panel
  panel_login
  create_reality_inbound
  create_site
  configure_caddy
  configure_haproxy
  configure_firewall
  save_state
  install_helpers
  health_check
  print_summary
}

main "$@"
