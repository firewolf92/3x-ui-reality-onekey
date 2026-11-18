#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROJECT_DIR="/etc/3xui-onekey"
STATE_FILE="$PROJECT_DIR/config.env"
CLIENT_FILE="$PROJECT_DIR/client-link.txt"
SITE_ROOT="/var/www/onekey-site"
INSTALL_MARKER="$PROJECT_DIR/.installation-incomplete"
XRAY_INTERNAL_PORT_DEFAULT="2443"
CADDY_TLS_PORT_DEFAULT="8443"
REALITY_SNI_DEFAULT="www.microsoft.com"
REALITY_PORT="443"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() { if [[ -n "${COOKIE_FILE:-}" ]]; then rm -f -- "$COOKIE_FILE"; fi; }
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
  if [[ -e "$INSTALL_MARKER" ]]; then
    die "发现上次未完成的安装记录。请先检查机器；确需清理时使用 install.sh --cleanup-failed。"
  fi
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

mark_install_incomplete() {
  install -d -m 0700 "$PROJECT_DIR"
  printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALL_MARKER"
  chmod 0600 "$INSTALL_MARKER"
}

# Deliberate, manual cleanup only for an installation that this script marked
# incomplete. It never changes APT packages or existing firewall/SSH rules.
cleanup_failed_install() {
  require_root
  [[ -f "$INSTALL_MARKER" && ! -L "$INSTALL_MARKER" ]] ||
    die "没有本脚本创建的未完成安装标记；拒绝清理。"
  [[ -t 0 ]] || die "清理必须在交互式终端确认。"
  printf '将停止 x-ui/Caddy/HAProxy 并卸载失败安装时装入的 Caddy/HAProxy 软件包；其他基础软件包和 UFW 配置保持不变。\n'
  read -r -p '确认请输入 CLEANUP：' ans
  [[ "$ans" == CLEANUP ]] || die "用户取消。"
  local dir rel
  dir="/root/3xui-onekey-backups/failed-install-$(date -u +%Y%m%d-%H%M%S)-${BASHPID}"
  install -d -m 0700 "$dir"
  local -a save=()
  for rel in /etc/3xui-onekey /etc/x-ui /usr/local/x-ui /usr/bin/x-ui              /etc/systemd/system/x-ui.service /etc/systemd/system/x-ui.service.d              /etc/caddy/Caddyfile /etc/haproxy/haproxy.cfg /var/www/onekey-site; do
    [[ -e "$rel" || -L "$rel" ]] && save+=("$rel")
  done
  if (( ${#save[@]} > 0 )); then
    tar -czf "$dir/partial-state.tar.gz" "${save[@]}"
    ( cd "$dir"; sha256sum partial-state.tar.gz > partial-state.tar.gz.sha256 )
  fi
  for svc in haproxy caddy x-ui; do
    systemctl disable --now "$svc" 2>/dev/null || true
  done
  # Caddy/HAProxy were absent during the clean-host preflight and are
  # installed by this script. Remove them now so a second preflight does
  # not reject their leftover systemd units. No autoremove or UFW reset.
  DEBIAN_FRONTEND=noninteractive apt-get remove -y caddy haproxy ||
    die "无法卸载失败安装留下的 Caddy/HAProxy；请检查 APT 错误。安装标记仍保留。"
  rm -rf -- /usr/local/x-ui /etc/x-ui /etc/systemd/system/x-ui.service.d     /etc/3xui-onekey /var/www/onekey-site
  rm -f -- /usr/bin/x-ui /etc/systemd/system/x-ui.service     /etc/caddy/Caddyfile /etc/haproxy/haproxy.cfg     /usr/local/sbin/onekey-status /usr/local/sbin/onekey-update     /usr/local/sbin/onekey-uninstall /usr/local/sbin/onekey-recovery
  systemctl daemon-reload
  printf '清理完成；部分状态已保存至 %s。其他基础软件包及 UFW 规则未删除。\n' "$dir"
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl jq openssl iproute2 dnsutils ufw haproxy python3 debian-keyring debian-archive-keyring apt-transport-https
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
  XUI_NONINTERACTIVE=1   XUI_USERNAME="$PANEL_USER"   XUI_PASSWORD="$PANEL_PASSWORD"   XUI_PANEL_PORT="$PANEL_PORT"   XUI_WEB_BASE_PATH="$PANEL_BASE"   XUI_SSL_MODE=none   bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh)

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

fetch_panel_csrf() {
  local result
  result=$(curl -fsS --max-time 10 -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
    "$PANEL_LOCAL/csrf-token") || die "无法取得 3x-ui CSRF Token。"
  CSRF_TOKEN=$(jq -er 'select(.success == true) | .obj | strings | select(length > 0)' \
    <<< "$result") || die "3x-ui 未返回有效 CSRF Token。"
}

panel_login() {
  PANEL_LOCAL="http://127.0.0.1:${PANEL_PORT}${PANEL_BASE%/}"
  local payload response
  COOKIE_FILE=$(mktemp /tmp/3xui-onekey-cookie.XXXXXXXX)
  chmod 0600 "$COOKIE_FILE"
  fetch_panel_csrf
  payload=$(jq -n --arg u "$PANEL_USER" --arg p "$PANEL_PASSWORD" '{username:$u,password:$p}')
  response=$(curl -fsS --max-time 10 -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
    -H "X-CSRF-Token: $CSRF_TOKEN" -H 'Content-Type: application/json' \
    --data "$payload" "$PANEL_LOCAL/login") || die "3x-ui 自动登录请求失败。"
  jq -e '.success == true' <<< "$response" >/dev/null ||
    die "3x-ui API 登录失败；请确认安装凭据及后台安全设置。"
  # 3x-ui clears anonymous CSRF state when login privileges change.
  fetch_panel_csrf
}
create_reality_inbound() {
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 8)
  CLIENT_EMAIL="default-$(openssl rand -hex 3)"
  XRAY_INTERNAL_PORT="$XRAY_INTERNAL_PORT_DEFAULT"

  local key_json private_key public_key payload response
  key_json=$(curl -fsS -b "$COOKIE_FILE" "$PANEL_LOCAL/panel/api/server/getNewX25519Cert")
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

  response=$(curl -fsS -b "$COOKIE_FILE" -H "X-CSRF-Token: $CSRF_TOKEN" -H 'Content-Type: application/json' --data "$payload" "$PANEL_LOCAL/panel/api/inbounds/add")
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

render_caddyfile() {
  local output="$1"
  cat > "$output" <<EOF_CADDY
{
    email ${ACME_EMAIL}
    auto_https disable_redirects
    http_port 80
    https_port ${CADDY_TLS_PORT}
}
http://${SITE_DOMAIN} {
    redir https://${SITE_DOMAIN}{uri} permanent
}
http://${PANEL_DOMAIN} {
    redir https://${PANEL_DOMAIN}{uri} permanent
}
${SITE_DOMAIN} {
    root * ${SITE_ROOT}
    encode zstd gzip
    file_server
}
${PANEL_DOMAIN} {
    reverse_proxy 127.0.0.1:${PANEL_PORT}
}
EOF_CADDY
}

configure_caddy() {
  CADDY_TLS_PORT="$CADDY_TLS_PORT_DEFAULT"
  local candidate
  candidate=$(mktemp /etc/caddy/.Caddyfile.onekey.XXXXXXXX)
  render_caddyfile "$candidate"
  # Validation must complete BEFORE the live Caddyfile is replaced.
  if ! caddy validate --config "$candidate" --adapter caddyfile; then
    rm -f -- "$candidate"
    die "Caddyfile 语法检查失败；没有覆盖当前配置。"
  fi
  if [[ -e /etc/caddy/Caddyfile ]]; then
    cp -a -- /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.pre-onekey.$(date -u +%Y%m%d%H%M%S).$$"
  fi
  install -m 0644 "$candidate" /etc/caddy/Caddyfile
  rm -f -- "$candidate"
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

resolve_ssh_port() {
  local port="" candidates=""
  if [[ -n "${ONEKEY_SSH_PORT:-}" ]]; then
    port="$ONEKEY_SSH_PORT"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    port=$(awk '{print $4}' <<< "$SSH_CONNECTION")
  elif command -v sshd >/dev/null 2>&1; then
    candidates=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u)
    [[ $(wc -w <<< "$candidates") -eq 1 ]] ||
      die "无法唯一确定 SSH 端口；请显式传入 ONEKEY_SSH_PORT=实际端口。"
    port="$candidates"
  else
    die "无法确定 SSH 端口。为避免 UFW 锁定，请设置 ONEKEY_SSH_PORT=实际端口。"
  fi
  if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]]; then die "无效 SSH 端口：$port"; fi
  if (( port > 65535 )); then die "无效 SSH 端口：$port"; fi
  SSH_PORT="$port"
  log "UFW 将保留 SSH TCP 端口：$SSH_PORT"
}

configure_firewall() {
  local ssh_port="$SSH_PORT"
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
  CLIENT_LINK="vless://${UUID}@${PUBLIC_IPV4}:${REALITY_PORT}?type=tcp&security=reality&sni=${REALITY_SNI}&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&fp=chrome&spx=%2F&flow=xtls-rprx-vision#onekey-reality"
  printf '%s\n' "$CLIENT_LINK" > "$CLIENT_FILE"
  chmod 600 "$CLIENT_FILE"
}

install_helpers() {
  curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/status.sh -o /usr/local/sbin/onekey-status
  curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/update.sh -o /usr/local/sbin/onekey-update
  curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/uninstall.sh -o /usr/local/sbin/onekey-uninstall
  curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/recovery.sh -o /usr/local/sbin/onekey-recovery
  chmod 0755 /usr/local/sbin/onekey-status /usr/local/sbin/onekey-update /usr/local/sbin/onekey-uninstall /usr/local/sbin/onekey-recovery
}

health_check() {
  systemctl is-active --quiet x-ui || die "健康检查失败: x-ui 未运行。"
  systemctl is-active --quiet caddy || die "健康检查失败: caddy 未运行。"
  systemctl is-active --quiet haproxy || die "健康检查失败: haproxy 未运行。"
  ss -ltnH | awk '{print $4}' | grep -Eq '(:|\])443$' || die "健康检查失败: 公网 443 未监听。"
  ss -ltnH | awk '{print $4}' | grep -Eq "(:|\\])${XRAY_INTERNAL_PORT}$" || die "健康检查失败: Xray 内部端口未监听。"
  ss -ltnH | awk '{print $4}' | grep -Eq "(:|\\])${CADDY_TLS_PORT}$" || die "健康检查失败: Caddy 内部 TLS 端口未监听。"
  local ok=0
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 --resolve "${SITE_DOMAIN}:443:127.0.0.1" "https://${SITE_DOMAIN}/" >/dev/null 2>&1 &&
      curl -fsS --max-time 5 --resolve "${PANEL_DOMAIN}:443:127.0.0.1" "https://${PANEL_DOMAIN}${PANEL_BASE}" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  if [[ "$ok" != 1 ]]; then
    journalctl -u caddy -n 60 --no-pager >&2 || true
    die "健康检查失败: 120 秒内 HTTPS 网站或面板未通过检查，请排查 DNS、ACME 证书和 Caddy。"
  fi
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


# Only resumes the narrow failure window after official 3x-ui installation
# and before this script has created the Reality inbound or written our state.
load_existing_panel() {
  local result_file=/etc/x-ui/install-result.env
  [[ -f "$INSTALL_MARKER" && ! -L "$INSTALL_MARKER" ]] ||
    die "没有上次安装未完成标记，拒绝续装。"
  [[ ! -e "$STATE_FILE" && ! -e "$CLIENT_FILE" && ! -e "$SITE_ROOT" ]] ||
    die "检测到已经生成的 OneKey 配置或站点；拒绝从早期阶段重复续装。"
  [[ -f "$result_file" && ! -L "$result_file" && -r "$result_file" ]] ||
    die "缺少官方 root 专用的 3x-ui 安装凭据文件，不能续装。"
  [[ "$(stat -c %u "$result_file")" == 0 ]] ||
    die "安装凭据文件不是 root 所有，拒绝加载。"
  [[ ! -e /etc/default/x-ui || "$(stat -c %u /etc/default/x-ui)" == 0 ]] ||
    die "检测到异常的 3x-ui 配置文件权限。"
  # Official installer writes a root-only shell-escaped file using printf %q.
  # shellcheck disable=SC1090
  . "$result_file"
  [[ "${XUI_DB_TYPE:-sqlite}" == sqlite ]] || die "仅支持 SQLite 3x-ui 部署续装。"
  [[ -n "${XUI_USERNAME:-}" && -n "${XUI_PASSWORD:-}" ]] ||
    die "安装凭据缺少用户或密码。"
  [[ "${XUI_PANEL_PORT:-}" =~ ^[1-9][0-9]{0,4}$ ]] ||
    die "安装凭据中的面板端口不合法。"
  (( XUI_PANEL_PORT <= 65535 )) || die "面板端口超出范围。"
  [[ -n "${XUI_WEB_BASE_PATH:-}" ]] || die "缺少原有面板路径。"
  PANEL_BASE="/${XUI_WEB_BASE_PATH#/}"
  PANEL_BASE="${PANEL_BASE%/}/"
  [[ "$PANEL_BASE" =~ ^/[A-Za-z0-9_-]{8,64}/$ ]] ||
    die "原有面板路径格式不符合 OneKey 预期，拒绝续装。"
  PANEL_USER="$XUI_USERNAME"
  PANEL_PASSWORD="$XUI_PASSWORD"
  PANEL_PORT="$XUI_PANEL_PORT"
  [[ -x /usr/local/x-ui/x-ui && -s /etc/x-ui/x-ui.db ]] ||
    die "已安装 3x-ui 程序或 SQLite 数据库缺失，拒绝续装。"
  systemctl is-active --quiet x-ui || die "x-ui 未运行，拒绝续装。"
  if ss -ltnH | awk '{print $4}' | grep -Eq ':2443$'; then
    die "Reality 内部端口 2443 已占用；请人工核查，不自动覆盖。"
  fi
  log "已确认可续装的 3x-ui 实例；将复用原有账号、端口及面板路径。"
}

ensure_reality_port_free_in_panel() {
  local result
  result=$(curl -fsS --max-time 10 -b "$COOKIE_FILE" \
    "$PANEL_LOCAL/panel/api/inbounds/list") ||
    die "无法检查面板已有入站；拒绝创建重复节点。"
  jq -e '.success == true and (.obj | type == "array")' <<< "$result" >/dev/null ||
    die "无法识别已有入站列表；拒绝重复创建节点。"
  if jq -e --argjson p "$XRAY_INTERNAL_PORT_DEFAULT" \
     '.obj[] | select((.port | tonumber) == $p)' <<< "$result" >/dev/null; then
    die "面板中已有 2443 端口入站；拒绝重复创建节点。"
  fi
}

resume_failed_install() {
  require_root
  load_os
  # No packages or existing 3x-ui installation are modified during preflight.
  prompt_values
  resolve_ssh_port
  load_existing_panel
  get_public_ipv4
  verify_dns "$SITE_DOMAIN"
  verify_dns "$PANEL_DOMAIN"
  log "继续未完成的一键部署，不重装 3x-ui..."
  complete_install 1
}

complete_install() {
  local resumed="$1"
  wait_panel
  panel_login
  if [[ "$resumed" == 1 ]]; then ensure_reality_port_free_in_panel; fi
  create_reality_inbound
  create_site
  configure_caddy
  configure_haproxy
  configure_firewall
  save_state
  install_helpers
  health_check
  rm -f -- "$INSTALL_MARKER"
  if ! /usr/local/sbin/onekey-recovery create; then
    printf '[!] 首次恢复快照创建失败；服务已完成部署，请检查磁盘空间和数据库后手动执行 onekey-recovery create。\n' >&2
  fi
  print_summary
}

main() {
  require_root
  if [[ "${1:-}" == "--cleanup-failed" && $# -eq 1 ]]; then
    cleanup_failed_install
    return
  fi
  if [[ "${1:-}" == "--resume-failed" && $# -eq 1 ]]; then
    resume_failed_install
    return
  fi
  (( $# == 0 )) || die "不支持的安装参数。"
  load_os
  prompt_values
  resolve_ssh_port
  preflight_clean_host
  mark_install_incomplete
  log "安装基础依赖..."
  install_base_packages
  install_caddy
  get_public_ipv4
  log "检测到 VPS IPv4: $PUBLIC_IPV4"
  verify_dns "$SITE_DOMAIN"
  verify_dns "$PANEL_DOMAIN"
  install_3xui
  complete_install 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
