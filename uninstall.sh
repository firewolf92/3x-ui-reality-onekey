#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root 执行。" >&2; exit 1; }
STATE_FILE="/etc/3xui-onekey/config.env"
if [[ -r "$STATE_FILE" ]]; then
  backup_dir="/root/3xui-onekey-backups/uninstall-$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$backup_dir"
  cp -a /etc/x-ui/x-ui.db "$backup_dir/x-ui.db" 2>/dev/null || true
  cp -a "$STATE_FILE" "$backup_dir/config.env" 2>/dev/null || true
  echo "已备份到: $backup_dir"
fi

read -r -p "确认卸载 3x-ui OneKey、Caddy、HAProxy 配置？输入 DELETE 继续: " ans
[[ "$ans" == "DELETE" ]] || { echo "已取消。"; exit 0; }

systemctl disable --now haproxy 2>/dev/null || true
systemctl disable --now caddy 2>/dev/null || true
systemctl disable --now x-ui 2>/dev/null || true

if command -v x-ui >/dev/null 2>&1; then
  printf 'y\n' | x-ui uninstall >/dev/null 2>&1 || true
fi

rm -f /etc/haproxy/haproxy.cfg
rm -f /etc/caddy/Caddyfile
rm -rf /var/www/onekey-site
rm -rf /etc/3xui-onekey
rm -f /usr/local/sbin/onekey-status /usr/local/sbin/onekey-update /usr/local/sbin/onekey-uninstall

apt-get remove -y haproxy caddy >/dev/null 2>&1 || true
apt-get autoremove -y >/dev/null 2>&1 || true

echo "卸载完成。UFW 规则未自动删除，以免影响 SSH；如需修改请手工执行 ufw status numbered。"
