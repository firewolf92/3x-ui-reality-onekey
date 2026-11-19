#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Sourcing the installer does not run its guarded main() entry point.
# shellcheck disable=SC1091
. "$root/install.sh"
SITE_ROOT="$tmp/public-site"
create_site

[[ -d "$SITE_ROOT" ]]
[[ -s "$SITE_ROOT/index.html" ]]
[[ -f "$SITE_ROOT/robots.txt" ]]
[[ "$(stat -c '%a' "$SITE_ROOT")" == 755 ]]
[[ "$(stat -c '%a' "$SITE_ROOT/index.html")" == 644 ]]
[[ "$(stat -c '%a' "$SITE_ROOT/robots.txt")" == 644 ]]

# A non-root user (Caddy) must be able to read the public files.
[[ -r "$SITE_ROOT/index.html" ]]
[[ -r "$SITE_ROOT/robots.txt" ]]
echo "static site permissions test passed"
