#!/usr/bin/env bash
set -Eeuo pipefail

REPO="firewolf92/3x-ui-reality-onekey"
REF="${ONEKEY_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

need_bootstrap_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] 缺少命令: $1" >&2; exit 1; }
}

need_bootstrap_cmd curl

for f in lib/common.sh lib/web.sh lib/xui.sh lib/firewall.sh; do
  mkdir -p "$TMP_DIR/$(dirname "$f")"
  curl -fsSL --retry 3 --connect-timeout 10 "${RAW_BASE}/${f}" -o "$TMP_DIR/$f"
done

# shellcheck disable=SC1091
source "$TMP_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$TMP_DIR/lib/web.sh"
# shellcheck disable=SC1091
source "$TMP_DIR/lib/xui.sh"
# shellcheck disable=SC1091
source "$TMP_DIR/lib/firewall.sh"

INSTALL_COMPLETE=0
on_install_exit() {
  local rc=$?
  trap - EXIT
  if [[ "$rc" -ne 0 && "${INSTALL_COMPLETE:-0}" != "1" ]]; then
    rollback_partial_install || true
  fi
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap on_install_exit EXIT

main() {
  require_root
  detect_os
  require_supported_os
  install_lock_acquire
  refuse_unmanaged_existing_install
  collect_inputs
  preflight_network
  preflight_existing_webstack
  preflight_ports
  install_base_packages
  install_xui
  load_xui_install_result
  lock_panel_to_loopback
  setup_site_http
  issue_certificates
  setup_tls_backend
  verify_tls_backend
  create_reality_inbound
  configure_firewall
  configure_fail2ban
  install_management_commands
  final_health_check
  write_state
  INSTALL_COMPLETE=1
  print_summary
}

main "$@"
