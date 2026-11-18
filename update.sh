#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root 执行。" >&2; exit 1; }
[[ -r /etc/3xui-onekey/config.env ]] || { echo "未找到部署状态文件。" >&2; exit 1; }
[[ -x /usr/local/sbin/onekey-recovery ]] || {
  echo "缺少 onekey-recovery，已安全停止更新。" >&2
  echo "请先按照 README 的“已有 VPS 启用恢复保护”步骤安装恢复助手。" >&2
  exit 1
}

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT

# Pre-download and validate the official updater before changing any running service.
upstream="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh"
if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 90 "$upstream" -o "$workdir/upstream-update.sh"; then
  echo "无法下载官方更新脚本；现有服务未更改。" >&2
  exit 1
fi
[[ -s "$workdir/upstream-update.sh" ]] && bash -n "$workdir/upstream-update.sh" || {
  echo "下载的官方更新脚本无效；现有服务未更改。" >&2
  exit 1
}

# A complete, hash-checked recovery snapshot (including current Xray and x-ui binaries)
# is required; never continue an update with only an unverified database copy.
echo "正在创建更新前完整恢复快照..."
/usr/local/sbin/onekey-recovery create
echo "开始调用 3x-ui 官方更新脚本..."
if ! bash "$workdir/upstream-update.sh"; then
  echo "官方更新失败。请保留并核验上方输出的恢复快照，勿反复强行更新。" >&2
  exit 1
fi

# Self-refresh is optional after a successful upstream update: an outage of our
# GitHub repository must not turn a successful upstream update into a failure.
refresh_helper() {
  local name="$1" tmp
  tmp=$(mktemp "/usr/local/sbin/.onekey-${name}.XXXXXXXX")
  if curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
    "https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/${name}.sh" -o "$tmp" &&
    [[ -s "$tmp" ]] && bash -n "$tmp"; then
    chmod 0755 "$tmp"
    mv -f -- "$tmp" "/usr/local/sbin/onekey-$name"
  else
    rm -f -- "$tmp"
    echo "提示：无法刷新 onekey-$name；保留本机旧版本。" >&2
  fi
}

refresh_helper status
refresh_helper update
refresh_helper uninstall
refresh_helper recovery

systemctl restart x-ui
systemctl restart caddy
systemctl restart haproxy
/usr/local/sbin/onekey-status