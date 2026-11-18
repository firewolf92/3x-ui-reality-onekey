#!/usr/bin/env bash
# Recover only the interrupted OneKey Caddy phase. Never recreate a Reality inbound.
set -Eeuo pipefail
umask 077
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=install.sh
. "$SCRIPT_DIR/install.sh"

verify_caddy_stage() {
  [[ -f "$INSTALL_MARKER" && ! -L "$INSTALL_MARKER" ]] ||
    die "未发现 OneKey 未完成安装标记；禁止恢复。"
  [[ ! -e "$STATE_FILE" && ! -e "$CLIENT_FILE" ]] ||
    die "OneKey 正式状态已存在；禁止重新配置。"
  [[ -f "$SITE_ROOT/index.html" && ! -L "$SITE_ROOT" ]] ||
    die "缺少之前生成的网站；不符合 Caddy 中断阶段。"
  grep -Fq 'ASTER SYSTEMS' "$SITE_ROOT/index.html" ||
    die "网站文件与 OneKey 默认模板不一致；禁止覆盖。"
  [[ -f /etc/caddy/Caddyfile && ! -L /etc/caddy/Caddyfile ]] ||
    die "缺少上次生成的 Caddyfile。"
  grep -Fq "http://${SITE_DOMAIN} {" /etc/caddy/Caddyfile ||
    die "旧 Caddyfile 的网站域名不匹配；禁止覆盖。"
  grep -Fq "http://${PANEL_DOMAIN} {" /etc/caddy/Caddyfile ||
    die "旧 Caddyfile 的面板域名不匹配；禁止覆盖。"
  [[ ! -e /usr/local/sbin/onekey-status ]] ||
    die "OneKey 已经安装管理脚本；不是此阶段。"
  ! systemctl is-active --quiet caddy ||
    die "Caddy 正在运行；请先人工检查现有服务。"
  ! systemctl is-active --quiet haproxy ||
    die "HAProxy 正在运行；拒绝覆盖既有服务。"
  [[ -s /etc/x-ui/x-ui.db && -x /usr/local/x-ui/x-ui ]] ||
    die "3x-ui 数据库或程序缺失。"
  systemctl is-active --quiet x-ui || die "x-ui 未运行。"
  ss -ltnH | awk '{print $4}' | grep -Fq ':2443' ||
    die "未检测到已创建的 Reality 2443 监听端口。"
}

load_saved_panel_credentials() {
  local file=/etc/x-ui/install-result.env
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] ||
    die "无法读取官方安装凭据文件。"
  [[ $(stat -c %u "$file") == 0 ]] ||
    die "安装凭据并非 root 所有，拒绝加载。"
  # Official 3x-ui emits a root-owned, shell-escaped file with printf %q.
  # shellcheck disable=SC1091
  . "$file"
  [[ "${XUI_DB_TYPE:-sqlite}" == sqlite ]] || die "仅支持 SQLite。"
  [[ -n "${XUI_USERNAME:-}" && -n "${XUI_PASSWORD:-}" ]] ||
    die "缺少官方面板凭据。"
  [[ "${XUI_PANEL_PORT:-}" =~ ^[1-9][0-9]{0,4}$ ]] ||
    die "面板端口不合法。"
  (( XUI_PANEL_PORT <= 65535 )) || die "面板端口超出范围。"
  [[ -n "${XUI_WEB_BASE_PATH:-}" ]] || die "缺少面板访问路径。"
  PANEL_BASE="/${XUI_WEB_BASE_PATH#/}"
  PANEL_BASE="${PANEL_BASE%/}/"
  [[ "$PANEL_BASE" =~ ^/[A-Za-z0-9_-]{8,64}/$ ]] ||
    die "官方面板路径格式不符。"
  PANEL_USER="$XUI_USERNAME"
  PANEL_PASSWORD="$XUI_PASSWORD"
  PANEL_PORT="$XUI_PANEL_PORT"
}

parse_existing_reality() {
  local response="$1" extracted
  # Confirm exactly one inbound on 2443, created by the OneKey script.
  # Never print credentials or Reality private/public keys to stdout.
  extracted=$(jq -ce --arg sni "$REALITY_SNI" --argjson port "$XRAY_INTERNAL_PORT_DEFAULT" '
    if .success == true and (.obj | type) == "array" then
      [.obj[] | select(.port == $port)] as $all
      | if ($all | length) != 1 then empty
        else $all[0] as $ib
        | ($ib.settings | fromjson) as $clients
        | ($ib.streamSettings | fromjson) as $stream
        | {
            uuid: $clients.clients[0].id,
            flow: $clients.clients[0].flow,
            sid: $stream.realitySettings.shortIds[0],
            pub: $stream.realitySettings.settings.publicKey,
            sni: $stream.realitySettings.serverNames[0],
            target: $stream.realitySettings.target,
            network: $stream.network,
            security: $stream.security,
            remark: $ib.remark,
            listen: $ib.listen,
            protocol: $ib.protocol,
            enabled: $ib.enable
          }
        | select(
            .remark == "onekey-reality-443" and
            .listen == "127.0.0.1" and
            .protocol == "vless" and .enabled == true and
            .flow == "xtls-rprx-vision" and
            .network == "tcp" and .security == "reality" and
            .sni == $sni and .target == ($sni + ":443") and
            (.uuid | type == "string") and
            (.sid | type == "string") and
            (.pub | type == "string")
          )
        end
    else empty end
  ' <<< "$response") || die "现有 2443 入站与 OneKey 配置不一致；拒绝恢复。"
  UUID=$(jq -er '.uuid' <<< "$extracted")
  SHORT_ID=$(jq -er '.sid' <<< "$extracted")
  REALITY_PUBLIC_KEY=$(jq -er '.pub' <<< "$extracted")
  [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "现有 UUID 格式无效。"
  [[ "$SHORT_ID" =~ ^[0-9a-fA-F]{16}$ ]] || die "现有 Short ID 格式无效。"
  [[ "$REALITY_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] ||
    die "原 Reality 公钥缺失；没有尝试重置或创建新的密钥。"
  XRAY_INTERNAL_PORT="$XRAY_INTERNAL_PORT_DEFAULT"
}

inspect_existing_reality() {
  local response
  response=$(curl -fsS --max-time 10 -b "$COOKIE_FILE" \
    "$PANEL_LOCAL/panel/api/inbounds/list") ||
    die "无法查询面板入站，已停止。"
  parse_existing_reality "$response"
}

create_pre_resume_backup() {
  local folder
  folder="/root/3xui-onekey-backups/pre-caddy-resume-$(date -u +%Y%m%d-%H%M%S)-${BASHPID}"
  install -d -m 0700 "$folder"
  cp -a -- /etc/caddy/Caddyfile "$folder/Caddyfile.before"
  if [[ -f /etc/haproxy/haproxy.cfg ]]; then
    cp -a -- /etc/haproxy/haproxy.cfg "$folder/haproxy.cfg.before"
  fi
  python3 - /etc/x-ui/x-ui.db "$folder/x-ui.db.before" <<'PY'
import sqlite3
import sys

src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
try:
    src.backup(dst)
    result = dst.execute("PRAGMA integrity_check").fetchone()
    if not result or result[0] != "ok":
        raise RuntimeError("SQLite backup failed integrity check")
finally:
    src.close()
    dst.close()
PY
  chmod 0600 "$folder/x-ui.db.before"
  log "当前 Caddy/HAProxy 配置及 3x-ui 数据库已保存在 root 私有目录。"
}

main() {
  require_root
  local mode="${1:---check}" candidate answer
  [[ $# -le 1 && ( "$mode" == "--check" || "$mode" == "--apply" ) ]] ||
    die "用法：bash resume-caddy.sh [--check|--apply]"
  load_os
  prompt_values
  resolve_ssh_port
  verify_caddy_stage
  load_saved_panel_credentials
  get_public_ipv4
  verify_dns "$SITE_DOMAIN"
  verify_dns "$PANEL_DOMAIN"
  wait_panel
  panel_login
  inspect_existing_reality

  CADDY_TLS_PORT="$CADDY_TLS_PORT_DEFAULT"
  candidate=$(mktemp /tmp/onekey-caddy-preflight.XXXXXXXX)
  render_caddyfile "$candidate"
  if ! caddy validate --config "$candidate" --adapter caddyfile; then
    rm -f -- "$candidate"
    die "修复后的 Caddyfile 未通过语法验证。"
  fi
  rm -f -- "$candidate"
  log "只读检查通过：原有 x-ui、Reality 入站、网站及新 Caddyfile 均符合预期。"
  if [[ "$mode" == "--check" ]]; then
    log "目前没有修改任何部署配置。需正式续装时再添加 --apply。"
    return 0
  fi
  [[ -t 0 ]] || die "正式续装必须在交互式终端运行。"
  read -r -p '确认继续配置 Caddy、HAProxy、UFW 并保存状态，请输入 RESUME：' answer
  [[ "$answer" == RESUME ]] || die "已取消；服务器配置未更改。"
  create_pre_resume_backup

  # No 3x-ui installation, no inbound creation, no key rotation.
  configure_caddy
  configure_haproxy
  configure_firewall
  save_state
  install_helpers
  health_check
  rm -f -- "$INSTALL_MARKER"
  if ! /usr/local/sbin/onekey-recovery create; then
    printf '[!] 完整快照失败，请检查数据库与磁盘空间后手动执行 onekey-recovery create。\n' >&2
  fi
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi