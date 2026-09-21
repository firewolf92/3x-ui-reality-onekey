#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root 执行。" >&2; exit 1; }
STATE_FILE="/etc/3xui-onekey/config.env"
[[ -r "$STATE_FILE" ]] || { echo "未找到部署状态文件。" >&2; exit 1; }

backup_dir="/root/3xui-onekey-backups/$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$backup_dir"
if [[ -f /etc/x-ui/x-ui.db ]]; then
  cp -a /etc/x-ui/x-ui.db "$backup_dir/x-ui.db"
fi
cp -a /etc/caddy/Caddyfile "$backup_dir/Caddyfile" 2>/dev/null || true
cp -a /etc/haproxy/haproxy.cfg "$backup_dir/haproxy.cfg" 2>/dev/null || true
cp -a "$STATE_FILE" "$backup_dir/config.env"

echo "备份完成: $backup_dir"
echo "更新 3x-ui 官方稳定版..."
bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh)

curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/status.sh -o /usr/local/sbin/onekey-status
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/update.sh -o /usr/local/sbin/onekey-update
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/uninstall.sh -o /usr/local/sbin/onekey-uninstall
chmod 0755 /usr/local/sbin/onekey-status /usr/local/sbin/onekey-update /usr/local/sbin/onekey-uninstall

systemctl restart x-ui
systemctl restart caddy
systemctl restart haproxy
/usr/local/sbin/onekey-status
