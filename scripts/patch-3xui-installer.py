#!/usr/bin/env python3
"""Generate the pinned self-hosted GPL-3.0 installer from upstream v3.11.0."""
from __future__ import annotations

import argparse
import re
from pathlib import Path

TAG = "v3.11.0"
RELEASE_TAG = "mirror-3xui-v3.11.0"
BASE = "https://github.com/firewolf92/3x-ui-reality-onekey/releases/download/" + RELEASE_TAG

def patch(source: str) -> str:
    # No network call to the deleted upstream is permitted from the patched
    # installer. This should fail closed on unexpected upstream script changes.
    replacement = "resolve_latest_tag() { printf '%s\\n' '" + TAG + "'; }\n"
    source, n = re.subn(
        r"(?ms)^resolve_latest_tag\(\) \{\n.*?^\}\n",
        lambda _: replacement,
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
        raise ValueError("unmirrored upstream repository URL remains")
    return "# Derived from MHSanaei/3x-ui " + TAG + " (GPL-3.0); see LICENSE.\n" + source

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("output")
    a = ap.parse_args()
    Path(a.output).write_text(patch(Path(a.source).read_text(encoding="utf-8")), encoding="utf-8")

if __name__ == "__main__":
    main()
