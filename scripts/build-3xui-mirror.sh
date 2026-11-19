#!/usr/bin/env bash
# Mirrors fixed GPL-3.0 release v3.11.0 into this repository's own GitHub release.
# Run in trusted CI; contains no VPS secrets.
set -Eeuo pipefail
IFS=$'\n\t'
tag=v3.11.0
upstream="https://github.com/MHSanaei/3x-ui/releases/download/${tag}"
raw="https://raw.githubusercontent.com/MHSanaei/3x-ui/${tag}"
dist="${1:-dist/vendor-3xui}"
mkdir -p "$dist"

download() {
  local url="$1" path="$2"
  curl -fLSs --retry 5 --retry-delay 3 --connect-timeout 20 --max-time 900 -o "$path" "$url"
  [[ -s "$path" ]] || { echo "Empty download: $url" >&2; exit 1; }
}
for arch in amd64 arm64; do
  name="x-ui-linux-${arch}.tar.gz"
  download "$upstream/$name" "$dist/$name"
  download "$upstream/$name.sha256" "$dist/$name.sha256"
  expected=$(awk 'NR==1 {print $1}' "$dist/$name.sha256")
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || { echo "Invalid upstream SHA256 for $name" >&2; exit 1; }
  actual=$(sha256sum "$dist/$name" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || { echo "Upstream checksum mismatch for $name" >&2; exit 1; }
  tar -tzf "$dist/$name" | grep -E '(^|/)x-ui$' >/dev/null ||
    { echo "Missing x-ui executable in $name" >&2; exit 1; }
  echo "Checksum OK: $name"
done

for name in install.sh x-ui.sh x-ui.rc x-ui.service.debian x-ui.service.arch x-ui.service.rhel LICENSE; do
  download "$raw/$name" "$dist/$name"
done
download "https://codeload.github.com/MHSanaei/3x-ui/tar.gz/refs/tags/${tag}" "$dist/3x-ui-source-${tag}.tar.gz"
tar -tzf "$dist/3x-ui-source-${tag}.tar.gz" | grep -E '^3x-ui-[^/]+/LICENSE$' >/dev/null ||
  { echo 'Source archive did not include expected license' >&2; exit 1; }

mv "$dist/install.sh" "$dist/install-upstream.sh"
python3 scripts/patch-3xui-installer.py "$dist/install-upstream.sh" "$dist/install.sh"
bash -n "$dist/install.sh"
if grep -E 'github.com/MHSanaei/3x-ui|raw.githubusercontent.com/MHSanaei/3x-ui' "$dist/install.sh"; then
  echo "Patched installer still includes upstream download URLs" >&2
  exit 1
fi
(
  cd "$dist"
  sha256sum install.sh install-upstream.sh x-ui.sh x-ui.rc x-ui.service.debian x-ui.service.arch x-ui.service.rhel LICENSE \
    x-ui-linux-amd64.tar.gz x-ui-linux-arm64.tar.gz 3x-ui-source-${tag}.tar.gz |
    LC_ALL=C sort -k2 > manifest.sha256
  sha256sum -c manifest.sha256
)
printf 'Mirror bundle ready: %s\n' "$dist"
