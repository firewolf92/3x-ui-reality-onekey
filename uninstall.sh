#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root 执行。" >&2; exit 1; }
STATE_FILE="/etc/3xui-onekey/config.env"
if [[ -r "$STATE_FILE" ]]; then
  [[ -x /usr/local/sbin/onekey-recovery ]] || {
    echo "缺少恢复助手；为防止数据无法恢复，拒绝卸载。" >&2
    exit 1
  }
  echo "卸载前强制创建包含 3x-ui/Xray/数据库的完整快照..."
  /usr/local/sbin/onekey-recovery create || {
    echo "完整备份失败，卸载已取消，现有服务未更改。" >&2
    exit 1
  }
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
# 保留 onekey-recovery 和 /root/3xui-onekey-backups，便于灾难恢复。

apt-get remove -y haproxy caddy >/dev/null 2>&1 || true
apt-get autoremove -y >/dev/null 2>&1 || true

echo "卸载完成。UFW 规则未自动删除，以免影响 SSH；如需修改请手工执行 ufw status numbered。"
