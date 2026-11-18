#!/usr/bin/env bash
# 3x-ui OneKey recovery snapshots. Never uploads private configuration.
set -Eeuo pipefail
umask 077

BACKUP_ROOT="/root/3xui-onekey-backups"
SNAPSHOT_NAME="snapshot.tar.gz"

fail() { printf '[x] %s\n' "$*" >&2; exit 1; }
say() { printf '[+] %s\n' "$*"; }
need_root() { [[ "$(id -u)" == 0 ]] || fail "请使用 root 运行。"; }
os_id() {
  (
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "$ID"
  )
}
os_version() {
  (
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${VERSION_ID:-unknown}"
  )
}

usage() {
  cat <<'HELP'
用法:
  onekey-recovery create
  onekey-recovery verify /path/to/recovery-directory
  onekey-recovery restore /path/to/recovery-directory [--new-ip IPv4] [--apply]
  onekey-recovery rollback /path/to/recovery-directory [--apply]

create  只读备份当前 3x-ui、Xray、配置、SQLite 数据库及代理配置。
verify  验证快照完整性；不修改系统。
restore 默认仅预检；加 --apply 后才会在全新、未部署 3x-ui 的服务器恢复。
rollback 默认仅预检；加 --apply 后才能恢复原服务器上的 3x-ui。
恢复要求相同的系统发行版、版本与 CPU 架构，并预装 Caddy/HAProxy。
HELP
}

# All paths are fixed; no user-controlled path is added to a tar archive.
snapshot_paths=(
  etc/3xui-onekey
  etc/x-ui
  etc/default/x-ui
  etc/caddy/Caddyfile
  etc/haproxy/haproxy.cfg
  etc/systemd/system/x-ui.service
  etc/systemd/system/x-ui.service.d
  usr/local/x-ui
  usr/bin/x-ui
  usr/local/sbin/onekey-status
  usr/local/sbin/onekey-update
  usr/local/sbin/onekey-uninstall
  usr/local/sbin/onekey-recovery
  var/www/onekey-site
)

require_source() {
  [[ -s /etc/3xui-onekey/config.env ]] || fail "缺少 OneKey 部署配置。"
  [[ -s /etc/x-ui/x-ui.db ]] || fail "缺少 SQLite 数据库。PostgreSQL 不支持此恢复格式。"
  [[ -x /usr/local/x-ui/x-ui ]] || fail "缺少已安装的 3x-ui 可执行程序。"
  [[ -r /etc/systemd/system/x-ui.service ]] || fail "缺少 x-ui.service。"
  [[ -r /usr/local/sbin/onekey-recovery ]] || fail "缺少已安装的恢复助手；无法创建自包含快照。"
  [[ -r /etc/caddy/Caddyfile && -r /etc/haproxy/haproxy.cfg ]] || fail "缺少反向代理配置。"
  command -v python3 >/dev/null || fail "一致性备份需要 python3。"
  if [[ -f /etc/default/x-ui ]] && grep -Eq '^XUI_DB_TYPE=postgres' /etc/default/x-ui; then
    fail "检测到 PostgreSQL；请单独使用 pg_dump 备份，本工具不会生成不完整快照。"
  fi
}

create_snapshot() {
  need_root
  require_source
  mkdir -p -- "$BACKUP_ROOT"
  chmod 0700 -- "$BACKUP_ROOT"
  local pending final rel
  pending=$(mktemp -d "$BACKUP_ROOT/.pending.XXXXXXXX")
  trap 'rm -rf -- "$pending"' EXIT
  mkdir -p "$pending/files"
  for rel in "${snapshot_paths[@]}"; do
    if [[ -e "/$rel" || -L "/$rel" ]]; then
      mkdir -p "$pending/files/$(dirname "$rel")"
      cp -a -- "/$rel" "$pending/files/$rel"
    fi
  done
  # Replace the potentially inconsistent live copy with SQLite's online backup API.
  rm -f -- "$pending/files/etc/x-ui/x-ui.db" \
    "$pending/files/etc/x-ui/x-ui.db-wal" "$pending/files/etc/x-ui/x-ui.db-shm"
  python3 - /etc/x-ui/x-ui.db "$pending/files/etc/x-ui/x-ui.db" <<'PY'
import sqlite3
import sys

source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=30)
destination = sqlite3.connect(sys.argv[2], timeout=30)
try:
    source.backup(destination)
    result = destination.execute("PRAGMA integrity_check").fetchone()
    if result is None or result[0] != "ok":
        raise RuntimeError("SQLite backup integrity check failed")
finally:
    destination.close()
    source.close()
PY
  chmod 0600 "$pending/files/etc/x-ui/x-ui.db"
  {
    printf 'schema=1\n'
    printf 'os_id=%s\n' "$(os_id)"
    printf 'os_version=%s\n' "$(os_version)"
    printf 'arch=%s\n' "$(uname -m)"
    printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$pending/metadata.txt"
  cp -a -- /usr/local/sbin/onekey-recovery "$pending/recovery.sh"
  chmod 0700 "$pending/recovery.sh"
  tar -czf "$pending/$SNAPSHOT_NAME" -C "$pending/files" .
  ( cd "$pending"; sha256sum "$SNAPSHOT_NAME" recovery.sh metadata.txt > "$SNAPSHOT_NAME.sha256" )
  rm -rf -- "$pending/files"
  final="$BACKUP_ROOT/recovery-$(date -u +%Y%m%d-%H%M%S)-$$"
  mv -- "$pending" "$final"
  trap - EXIT
  say "快照已保存：$final"
  say "请将整个目录复制到另一台受信任的设备；其中包含密码与 Reality 密钥。"
}

verify_snapshot() {
  local dir="$1" name
  [[ -d "$dir" && ! -L "$dir" ]] || fail "快照目录不存在或是符号链接。"
  [[ -f "$dir/metadata.txt" && -f "$dir/recovery.sh" && -f "$dir/$SNAPSHOT_NAME" && -f "$dir/$SNAPSHOT_NAME.sha256" ]] || fail "快照文件不完整。"
  grep -Fxq 'schema=1' "$dir/metadata.txt" || fail "不支持的快照格式。"
  [[ $(wc -l < "$dir/$SNAPSHOT_NAME.sha256") -eq 3 ]] || fail "校验清单必须包含 3 个文件。"
  local manifest_names required
  manifest_names=$(awk '{print $2}' "$dir/$SNAPSHOT_NAME.sha256")
  for required in "$SNAPSHOT_NAME" recovery.sh metadata.txt; do
    grep -Fxq "$required" <<< "$manifest_names" || fail "校验清单缺少：$required"
  done
  ( cd "$dir"; sha256sum -c --status "$SNAPSHOT_NAME.sha256" ) || fail "SHA256 验证失败；禁止恢复。"
  local names
  names=$(tar -tzf "$dir/$SNAPSHOT_NAME") || fail "快照压缩包损坏。"
  # Reject absolute paths, traversal paths, and unexpected top-level names.
  awk '
    $0 == "./" { next }
    $0 !~ /^\.\// || $0 ~ /\/\.\.($|\/)/ || $0 ~ /\/\.($|\/)/ { exit 1 }
    $0 !~ /^\.\/(etc|usr|var)(\/|$)/ { exit 1 }
  ' <<< "$names" || fail "快照含有不安全的文件路径。"
  for name in \
    ./etc/3xui-onekey/config.env \
    ./etc/x-ui/x-ui.db \
    ./etc/caddy/Caddyfile \
    ./etc/haproxy/haproxy.cfg \
    ./etc/systemd/system/x-ui.service \
    ./usr/local/x-ui/x-ui \
    ./usr/bin/x-ui; do
    grep -Fxq "$name" <<< "$names" || fail "快照缺少文件：$name"
  done
  say "SHA256 和必需文件检查通过：$dir"
}

check_snapshot_host() {
  local dir="$1" saved_os saved_version saved_arch
  saved_os=$(sed -n 's/^os_id=//p' "$dir/metadata.txt")
  saved_version=$(sed -n 's/^os_version=//p' "$dir/metadata.txt")
  saved_arch=$(sed -n 's/^arch=//p' "$dir/metadata.txt")
  [[ -n "$saved_version" ]] || fail "旧快照没有系统版本信息；禁止自动恢复，需人工核对。"
  [[ "$saved_os" == "$(os_id)" && "$saved_version" == "$(os_version)" && "$saved_arch" == "$(uname -m)" ]] ||
    fail "OS 发行版、版本或 CPU 架构不匹配；拒绝恢复。"
}

restore_snapshot() {
  local dir="$1" new_ip="$2" apply="$3" tmp rel answer old_ip
  verify_snapshot "$dir"
  check_snapshot_host "$dir"
  if [[ -n "$new_ip" ]]; then
    [[ "$new_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "--new-ip 需要 IPv4 地址。"
    IFS=. read -r a b c d <<< "$new_ip"
    for part in "$a" "$b" "$c" "$d"; do
      [[ "$part" =~ ^[0-9]+$ ]] || fail "无效 IPv4 地址。"
      if (( 10#$part > 255 )); then fail "无效 IPv4 地址。"; fi
    done
  fi
  say "恢复预检完成。此操作将恢复原有面板账户、节点密钥和站点配置。"
  [[ "$apply" == 1 ]] || { say "仅预检，未修改系统。请核对文档后添加 --apply。"; return 0; }
  need_root
  [[ ! -e /usr/local/x-ui && ! -e /etc/x-ui && ! -e /etc/3xui-onekey ]] ||
    fail "检测到现有 3x-ui 数据；为避免覆盖，拒绝执行。"
  for svc in x-ui caddy haproxy; do
    ! systemctl is-active --quiet "$svc" || fail "$svc 正在运行，拒绝覆盖服务配置。"
  done
  if ! command -v caddy >/dev/null || ! command -v haproxy >/dev/null; then
    fail "需先通过系统软件源安装 Caddy 和 HAProxy。"
  fi
  [[ -t 0 ]] || fail "恢复需要在交互式终端确认。"
  printf '输入 RESTORE 确认在当前干净 VPS 上写入备份文件：'
  read -r answer
  [[ "$answer" == RESTORE ]] || fail "已取消恢复。"
  mkdir -p -- "$BACKUP_ROOT"
  chmod 0700 -- "$BACKUP_ROOT"
  tmp=$(mktemp -d "$BACKUP_ROOT/.restore.XXXXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT
  tar -xzf "$dir/$SNAPSHOT_NAME" -C "$tmp" --no-same-owner
  [[ -f "$tmp/etc/x-ui/x-ui.db" && -x "$tmp/usr/local/x-ui/x-ui" ]] ||
    fail "解包后缺少关键文件；未修改现有系统。"
  for rel in "${snapshot_paths[@]}"; do
    [[ -e "$tmp/$rel" || -L "$tmp/$rel" ]] || continue
    mkdir -p "/$(dirname "$rel")"
    cp -a -- "$tmp/$rel" "/$(dirname "$rel")/"
  done
  if [[ -n "$new_ip" ]]; then
    old_ip=$(sed -n 's/^PUBLIC_IPV4=//p' /etc/3xui-onekey/config.env)
    [[ "$old_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
      fail "原有 PUBLIC_IPV4 不合法；请人工处理。"
    sed -i "s/^PUBLIC_IPV4=.*/PUBLIC_IPV4=$new_ip/" /etc/3xui-onekey/config.env
    if [[ -f /etc/3xui-onekey/client-link.txt ]]; then
      sed -i "s/@$old_ip:443/@$new_ip:443/g" /etc/3xui-onekey/client-link.txt
    fi
  fi
  systemctl daemon-reload
  systemctl enable --now x-ui caddy haproxy
  say "恢复命令已执行。请检查 onekey-status、DNS、ACME 证书、UFW 和客户端连接。"
  say "恢复工具不会自动更改防火墙或公网 DNS，避免 SSH 锁定。"
  rm -rf -- "$tmp"
  trap - EXIT
}

main() {
  local action="${1:-}" dir="${2:-}" new_ip="" apply=0
  case "$action" in
    create) [[ $# == 1 ]] || fail "create 不接受参数。"; create_snapshot ;;
    verify) [[ $# == 2 ]] || fail "用法：onekey-recovery verify 目录"; verify_snapshot "$dir" ;;
    restore)
      [[ -n "$dir" ]] || fail "用法：onekey-recovery restore 目录 [--new-ip IPv4] [--apply]"
      shift 2
      while (( $# > 0 )); do
        case "$1" in
          --apply) apply=1; shift ;;
          --new-ip) (( $# >= 2 )) || fail "缺少 --new-ip 参数"; new_ip="$2"; shift 2 ;;
          *) fail "未知参数：$1" ;;
        esac
      done
      restore_snapshot "$dir" "$new_ip" "$apply"
      ;;
    *) usage; [[ -z "$action" || "$action" == "--help" ]] || exit 2 ;;
  esac
}
main "$@"