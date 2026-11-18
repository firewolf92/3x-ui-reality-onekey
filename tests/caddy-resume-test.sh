#!/usr/bin/env bash
# No VPS services are started; Caddy parser runs on a temporary config.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# shellcheck disable=SC1091
. "$root/resume-caddy.sh"

SITE_DOMAIN=example.org
PANEL_DOMAIN=panel.example.org
ACME_EMAIL=tests@example.org
REALITY_SNI=www.microsoft.com
PANEL_PORT=26784
CADDY_TLS_PORT=8443
SITE_ROOT="$tmp/site"
mkdir -p "$SITE_ROOT"
render_caddyfile "$tmp/Caddyfile"
grep -Fxq 'http://example.org {' "$tmp/Caddyfile"
grep -Fxq 'http://panel.example.org {' "$tmp/Caddyfile"
caddy validate --config "$tmp/Caddyfile" --adapter caddyfile
caddy adapt --config "$tmp/Caddyfile" --adapter caddyfile >/dev/null

# Actual 3x-ui /panel/api/inbounds/list carries JSON-encoded settings fields.
settings='{"clients":[{"id":"123e4567-e89b-12d3-a456-426614174000","flow":"xtls-rprx-vision"}]}'
stream='{"network":"tcp","security":"reality","realitySettings":{"target":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["0123456789abcdef"],"settings":{"publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}}'
fixture=$(jq -n --arg settings "$settings" --arg stream "$stream" '
  {success:true,obj:[{
    port:2443,remark:"onekey-reality-443",listen:"127.0.0.1",
    protocol:"vless",enable:true,settings:$settings,streamSettings:$stream
  }]}')
parse_existing_reality "$fixture"
[[ "$UUID" == "123e4567-e89b-12d3-a456-426614174000" ]]
[[ "$SHORT_ID" == "0123456789abcdef" ]]
[[ "$REALITY_PUBLIC_KEY" == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ]]

# 3x-ui can return JSON objects directly rather than JSON-encoded strings.
# Both encodings, including mixed encoding, must recover the SAME original keys.
object_fixture=$(jq '.obj[0].settings |= fromjson | .obj[0].streamSettings |= fromjson' <<< "$fixture")
parse_existing_reality "$object_fixture"
[[ "$UUID" == "123e4567-e89b-12d3-a456-426614174000" ]]
[[ "$SHORT_ID" == "0123456789abcdef" ]]
[[ "$REALITY_PUBLIC_KEY" == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ]]

mixed_fixture=$(jq '.obj[0].settings |= fromjson' <<< "$fixture")
parse_existing_reality "$mixed_fixture"
mixed_fixture=$(jq '.obj[0].streamSettings |= fromjson' <<< "$fixture")
parse_existing_reality "$mixed_fixture"

# Reject invalid types, malformed JSON and incomplete nodes rather than inventing keys.
bad_type=$(jq '.obj[0].settings = 123' <<< "$fixture")
if (parse_existing_reality "$bad_type" >/dev/null 2>&1); then
  echo "FAIL: accepted number-valued settings" >&2
  exit 1
fi
bad_json=$(jq '.obj[0].settings = "{unparseable"' <<< "$fixture")
if (parse_existing_reality "$bad_json" >/dev/null 2>&1); then
  echo "FAIL: accepted malformed settings" >&2
  exit 1
fi
missing_key=$(jq '.obj[0].streamSettings |= (fromjson | del(.realitySettings.settings.publicKey) | tojson)' <<< "$fixture")
if (parse_existing_reality "$missing_key" >/dev/null 2>&1); then
  echo "FAIL: accepted missing Reality public key" >&2
  exit 1
fi

wrong=$(jq '.obj[0].remark = "some-other-node"' <<< "$fixture")
if (parse_existing_reality "$wrong" >/dev/null 2>&1); then
  echo "FAIL: accepted an unrelated 2443 inbound" >&2
  exit 1
fi
duplicate=$(jq '.obj += [.obj[0]]' <<< "$fixture")
if (parse_existing_reality "$duplicate" >/dev/null 2>&1); then
  echo "FAIL: accepted duplicate 2443 inbounds" >&2
  exit 1
fi
wrong_sni=$(jq --arg v "wrong.example.org" '
  .obj[0].streamSettings |= (fromjson | .realitySettings.serverNames[0] = $v | tojson)
' <<< "$fixture")
if (parse_existing_reality "$wrong_sni" >/dev/null 2>&1); then
  echo "FAIL: accepted a mismatched Reality SNI" >&2
  exit 1
fi
echo "Caddyfile syntax and existing Reality read-only recovery tests passed"
