#!/usr/bin/env python3
"""Shared read-only metadata probe for independent Google macOS app PoCs."""

import json
import plistlib
from pathlib import Path
import re
import subprocess
import urllib.request


def numeric_version(value):
    if not re.fullmatch(r"\d+(?:\.\d+)*", value or ""):
        return None
    return tuple(int(piece) for piece in value.split("."))


def probe(name, bundle_id, cask):
    paths = [Path("/Applications") / name, Path.home() / "Applications" / name]
    app = next((path for path in paths if path.is_dir()), None)
    result = {"product": name, "installed": app is not None, "path": str(app) if app else None}
    if app:
        info = app / "Contents/Info.plist"
        try:
            with info.open("rb") as stream:
                metadata = plistlib.load(stream)
            result.update(bundle_id=metadata.get("CFBundleIdentifier"),
                          installed_version=metadata.get("CFBundleShortVersionString"),
                          build=metadata.get("CFBundleVersion"))
            result["identity_matches"] = result["bundle_id"] == bundle_id
            signed = subprocess.run(["codesign", "--verify", "--strict", str(app)],
                                    capture_output=True, text=True, timeout=10)
            result["signature_valid"] = signed.returncode == 0
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            result["metadata_error"] = str(error)
    try:
        with urllib.request.urlopen("https://formulae.brew.sh/api/cask/" + cask + ".json", timeout=10) as response:
            release = json.load(response)
        result["cask"] = cask
        result["cask_version"] = release.get("version")
        result["cask_auto_updates"] = release.get("auto_updates")
        installed = numeric_version(result.get("installed_version"))
        tracked = numeric_version(str(release.get("version", "")).split(",", 1)[0])
        if result.get("identity_matches") and installed and tracked:
            width = max(len(installed), len(tracked))
            left, right = installed + (0,) * (width - len(installed)), tracked + (0,) * (width - len(tracked))
            result["comparison"] = "candidate_newer" if right > left else "source_behind" if right < left else "same_version"
        else:
            result["comparison"] = "unverified"
    except (OSError, ValueError) as error:
        result["source_error"] = str(error)
    print(json.dumps(result, ensure_ascii=False, indent=2))
