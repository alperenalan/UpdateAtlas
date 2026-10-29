#!/usr/bin/env python3
"""Standalone agy PoC: metadata only unless --execute-version is explicit."""
import json
from pathlib import Path
import subprocess
import sys
import urllib.request

path = Path.home() / ".local/bin/agy"
result = {"product": "agy", "installed": path.is_file(), "path": str(path) if path.is_file() else None}
if path.is_file():
    verified = subprocess.run(["codesign", "--verify", "--strict", str(path)],
                              capture_output=True, text=True, timeout=10)
    result["signature_valid"] = verified.returncode == 0
    if "--execute-version" in sys.argv:
        version = subprocess.run([str(path), "--version"], capture_output=True, text=True, timeout=10)
        result["command_version"] = version.stdout.strip() if version.returncode == 0 else None
        result["command_exit"] = version.returncode
    status = Path.home() / ".gemini/antigravity-cli/updater/update_status.json"
    if status.is_file():
        receipt = json.loads(status.read_text())
        result["updater_status"] = {key: receipt.get(key) for key in ("success", "message")}
try:
    with urllib.request.urlopen("https://formulae.brew.sh/api/cask/antigravity-cli.json", timeout=10) as response:
        result["cask_version"] = json.load(response).get("version")
except (OSError, ValueError) as error:
    result["source_error"] = str(error)
result["automatic_update_claim"] = "unverified: standalone installation has no trusted version receipt"
print(json.dumps(result, ensure_ascii=False, indent=2))
