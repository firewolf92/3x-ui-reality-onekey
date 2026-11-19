#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Sourcing the installer is safe: it only calls main when executed directly.
# shellcheck disable=SC1091
. "$root/install.sh"

# Selection: never start official installer if the pinned upstream is absent.
probe_3xui_upstream() { return 1; }
probe_3xui_mirror() { return 0; }
ONEKEY_3XUI_SOURCE=auto
[[ "$(choose_3xui_source amd64)" == mirror ]]
ONEKEY_3XUI_SOURCE=mirror
[[ "$(choose_3xui_source amd64)" == mirror ]]
ONEKEY_3XUI_SOURCE=upstream
if (choose_3xui_source amd64) >/dev/null 2>&1; then
  echo 'FAIL: forced upstream accepted missing resources' >&2; exit 1
fi

probe_3xui_upstream() { return 0; }
probe_3xui_mirror() { return 1; }
ONEKEY_3XUI_SOURCE=auto
[[ "$(choose_3xui_source amd64)" == upstream ]]
ONEKEY_3XUI_SOURCE=mirror
if (choose_3xui_source amd64) >/dev/null 2>&1; then
  echo 'FAIL: forced mirror accepted missing resources' >&2; exit 1
fi

probe_3xui_upstream() { return 1; }
ONEKEY_3XUI_SOURCE=auto
if (choose_3xui_source amd64) >/dev/null 2>&1; then
  echo 'FAIL: both unavailable but installation continued' >&2; exit 1
fi
ONEKEY_3XUI_SOURCE=invalid
if (choose_3xui_source amd64) >/dev/null 2>&1; then
  echo 'FAIL: invalid source accepted' >&2; exit 1
fi

# Mirror installer must match a locally downloaded SHA256 manifest before execution.
cp "$root/install.sh" "$tmp/fixture.sh"
(cd "$tmp"; sha256sum fixture.sh | sed 's/fixture.sh$/install.sh/' > manifest.source)
curl() {
  local arg url='' out=''
  while (( $# )); do
    arg=$1; shift
    if [[ "$arg" == -o ]]; then
      out=$1; shift
    elif [[ "$arg" == https://* ]]; then
      url="$arg"
    fi
  done
  [[ -n "$out" ]] || return 2
  case "$url" in
    */manifest.sha256) cp "$tmp/manifest.source" "$out" ;;
    */install.sh) cp "$tmp/fixture.sh" "$out" ;;
    *) return 2 ;;
  esac
}
download_mirror_installer "$tmp/verified.sh" "$tmp/manifest.downloaded"
cmp "$tmp/verified.sh" "$tmp/fixture.sh"
printf '%064d  install.sh\n' 0 > "$tmp/manifest.source"
if (download_mirror_installer "$tmp/rejected.sh" "$tmp/bad.manifest") >/dev/null 2>&1; then
  echo 'FAIL: tampered mirror install.sh accepted' >&2; exit 1
fi

# Patch generator unit test: rewrites all pinned URLs, refuses unexpected layout.
python3 - "$root" "$tmp" <<'PY'
import importlib.util
import pathlib
import sys
root, tmp = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("vendor_patch", root / "scripts/patch-3xui-installer.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = """resolve_latest_tag() {
 echo old
}
https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/
https://raw.githubusercontent.com/MHSanaei/3x-ui/${ref}/${name}
https://raw.githubusercontent.com/MHSanaei/3x-ui/${script_ref}/x-ui.sh
"""
result = module.patch(source)
assert "mirror-3xui-v3.11.0" in result
assert "MHSanaei/3x-ui/releases/" not in result
assert "MHSanaei/3x-ui" not in result.splitlines()[-3:]
try:
    module.patch("unrecognised upstream layout")
except ValueError:
    pass
else:
    raise AssertionError("patcher must refuse unexpected upstream layouts")
PY
echo 'Pinned upstream/mirror selector, manifest verification and URL rewrite tests passed'
