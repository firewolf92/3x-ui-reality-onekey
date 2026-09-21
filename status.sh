#!/usr/bin/env bash
set -Eeuo pipefail
STATE_FILE="/etc/3xui-onekey/config.env"
CLIENT_FILE="/etc/3xui-onekey/client-link.txt"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root 执行。" >&2; exit 1; }
[[ -r "$STATE_FILE" ]] || { echo "未找到 $STATE_FILE，可能尚未完成部署。" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE_FILE"

check_service() {
  local s="$1"
  if systemctl is-active --quiet "$s"; then
    printf '  %-10s %s\n' "$s" 'RUNNING'
  else
    printf '  %-10s %s\n' "$s" 'DOWN'
  fi
}

printf '\n3x-ui Reality OneKey 状态\n'
printf '%s\n' '----------------------------------------'
check_service x-ui
check_service caddy
check_service haproxy
printf '%s\n' '----------------------------------------'
printf '网站:   https://%s/\n' "$SITE_DOMAIN"
printf '面板:   https://%s%s\n' "$PANEL_DOMAIN" "$PANEL_BASE"
printf '公网IP: %s\n' "$PUBLIC_IPV4"
printf 'Reality SNI: %s\n' "$REALITY_SNI"
printf '%s\n' '----------------------------------------'

site=FAIL
panel=FAIL
if curl -fsS --max-time 8 --resolve "${SITE_DOMAIN}:443:127.0.0.1" "https://${SITE_DOMAIN}/" >/dev/null; then site=OK; fi
if curl -fsS --max-time 8 --resolve "${PANEL_DOMAIN}:443:127.0.0.1" "https://${PANEL_DOMAIN}${PANEL_BASE}" >/dev/null; then panel=OK; fi
printf 'HTTPS 网站: %s\n' "$site"
printf 'HTTPS 面板: %s\n' "$panel"

if [[ -r "$CLIENT_FILE" ]]; then
  printf '\n客户端链接（root only）:\n'
  cat "$CLIENT_FILE"
fi
