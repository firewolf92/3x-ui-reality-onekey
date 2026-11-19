#!/usr/bin/env python3
"""Create a version-locked, self-hosted copy of the upstream 3x-ui installer.

The unmodified upstream source archive is mirrored separately under GPL-3.0.
No upstream repository URL is permitted in the patched installer's fetch path.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

TAG = "v3.11.0"
RELEASE_TAG = "mirror-3xui-v3.11.0"
BASE = "https://github.com/firewolf92/3x-ui-reality-onekey/releases/download/" + RELEASE_TAG

def patch(source: str) -> str:
    original = source
    # Called by OneKey with an explicit tag; also make accidental no-arg use
    # deterministic, rather than asking the deleted upstream for "latest".
    source, n = re.subn(
        r"(?ms)^resolve_latest_tag\(\) \{\n.*?^\}\n",
        "resolve_latest_tag() { printf '%s\\n' '" + TAG + "'; }\n",
        source,
        count=1,
    )
    if n != 1:
        raise ValueError("upstream resolve_latest_tag layout changed")
    needles = {
        "https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/": BASE + "/",
        "https://raw.githubusercontent.com/MHSanaei/3x-ui/${ref}/${name}": BASE + "/${name}",
        "https://raw.githubusercontent.com/MHSanaei/3x-ui/${script_ref}/": BASE + "/",
    }
    for old, new in needles.items():
        if old not in source:
            raise ValueError("missing expected upstream install.sh URL: " + old)
        source = source.replace(old, new)
    if "MHSanaei/3x-ui" in source:
        raise ValueError("unexpected additional upstream URL; update mirror patch safely")
    if source == original:
        raise ValueError("no patch applied")
    return "# Derived from MHSanaei/3x-ui " + TAG + " (GPL-3.0); see LICENSE.\n" + source

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("output")
    a = ap.parse_args()
    out = patch(Path(a.source).read_text(encoding="utf-8"))
    Path(a.output).write_text(out, encoding="utf-8")

if __name__ == "__main__":
    main()
