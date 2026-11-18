#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/archive/files"/{etc/3xui-onekey,etc/x-ui,etc/caddy,etc/haproxy,etc/systemd/system,usr/local/x-ui,usr/bin}
printf 'SITE_DOMAIN=example.test\n' > "$tmp/archive/files/etc/3xui-onekey/config.env"
printf 'sqlite-placeholder\n' > "$tmp/archive/files/etc/x-ui/x-ui.db"
printf 'test\n' > "$tmp/archive/files/etc/caddy/Caddyfile"
printf 'test\n' > "$tmp/archive/files/etc/haproxy/haproxy.cfg"
printf 'test\n' > "$tmp/archive/files/etc/systemd/system/x-ui.service"
printf 'binary\n' > "$tmp/archive/files/usr/local/x-ui/x-ui"
printf 'script\n' > "$tmp/archive/files/usr/bin/x-ui"
{
  printf 'schema=1\n'
  printf 'os_id=%s\n' "$(
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "$ID"
  )"
  printf 'arch=%s\n' "$(uname -m)"
} > "$tmp/archive/metadata.txt"
tar -czf "$tmp/archive/snapshot.tar.gz" -C "$tmp/archive/files" .
( cd "$tmp/archive"; sha256sum snapshot.tar.gz > snapshot.tar.gz.sha256 )

bash "$root/recovery.sh" verify "$tmp/archive"
bash "$root/recovery.sh" restore "$tmp/archive" >/dev/null
printf 'tamper' >> "$tmp/archive/snapshot.tar.gz"
if bash "$root/recovery.sh" verify "$tmp/archive" >/dev/null 2>&1; then
  echo "FAIL: tampered archive was accepted" >&2
  exit 1
fi

# A checksum-valid but incomplete archive must not be accepted either.
rm -f "$tmp/archive/files/usr/bin/x-ui"
tar -czf "$tmp/archive/snapshot.tar.gz" -C "$tmp/archive/files" .
( cd "$tmp/archive"; sha256sum snapshot.tar.gz > snapshot.tar.gz.sha256 )
if bash "$root/recovery.sh" verify "$tmp/archive" >/dev/null 2>&1; then
  echo "FAIL: incomplete archive was accepted" >&2
  exit 1
fi
echo "recovery validation tests passed"