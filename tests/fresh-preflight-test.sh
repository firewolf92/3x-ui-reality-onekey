#!/usr/bin/env bash
# Safe fixture tests: no packages, daemons, DNS or VPS files are changed.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
# shellcheck disable=SC1091
. "$root/install.sh"
trap 'rm -rf -- "$tmp"' EXIT

# Verify that a clean Ubuntu host can do the early DNS check without dig.
getent() {
  [[ "$1" == ahostsv4 && "$2" == example.com ]] || return 2
  printf '192.0.2.10 STREAM example.com\n192.0.2.10 DGRAM example.com\n'
}
PUBLIC_IPV4=192.0.2.10
preflight_dns example.com
if ( PUBLIC_IPV4=192.0.2.11; preflight_dns example.com ) >/dev/null 2>&1; then
  echo "FAIL: incorrect origin IP passed early DNS validation" >&2
  exit 1
fi

# Stub every side-effecting installer function to prove stage ordering.
declare -a calls=()
log() { :; }
require_root() { calls+=(root); }
load_os() { calls+=(os); }
prompt_values() {
  calls+=(prompt)
  SITE_DOMAIN=example.com
  PANEL_DOMAIN=panel.example.com
  ACME_EMAIL=ops@example.com
}
resolve_ssh_port() { calls+=(ssh); }
preflight_clean_host() { calls+=(clean); }
get_public_ipv4() { calls+=(ip); PUBLIC_IPV4=192.0.2.10; }
preflight_dns() { calls+=("early:$1"); }
mark_install_incomplete() { calls+=(marker); }
install_base_packages() { calls+=(apt); }
install_caddy() { calls+=(caddy); }
verify_dns() { calls+=("authoritative:$1"); }
install_3xui() { calls+=(xui); }
complete_install() { calls+=("finish:$1"); }

main --preflight
expected_preflight=$(printf '%s\n' root os prompt ssh clean ip early:example.com early:panel.example.com)
actual=$(printf '%s\n' "${calls[@]}")
[[ "$actual" == "$expected_preflight" ]] || { echo "FAIL: --preflight has side effects or skips checks: $actual" >&2; exit 1; }

calls=()
main
expected_full=$(printf '%s\n' root os prompt ssh clean ip early:example.com early:panel.example.com marker apt caddy authoritative:example.com authoritative:panel.example.com xui finish:0)
actual=$(printf '%s\n' "${calls[@]}")
[[ "$actual" == "$expected_full" ]] || { echo "FAIL: install order unexpected: $actual" >&2; exit 1; }

# A DNS failure must abort before writing any incomplete marker or invoking APT.
preflight_dns() { die "simulated DNS failure"; }
mark_install_incomplete() { touch "$tmp/incomplete"; }
install_base_packages() { touch "$tmp/apt"; }
if ( main ) >/dev/null 2>&1; then
  echo "FAIL: failed DNS preflight allowed installation" >&2
  exit 1
fi
[[ ! -e "$tmp/incomplete" && ! -e "$tmp/apt" ]] || { echo "FAIL: DNS preflight modified host" >&2; exit 1; }
echo "early DNS, read-only preflight and clean install ordering tests passed"
