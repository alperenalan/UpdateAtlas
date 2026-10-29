#!/usr/bin/env python3
"""Read-only Gemini CLI npm installation and stable-tag PoC."""
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request

result = {"product": "gemini-cli", "command": shutil.which("gemini")}
npm = shutil.which("npm")
if npm:
    root = subprocess.run([npm, "root", "-g"], capture_output=True, text=True, timeout=5)
    if root.returncode == 0:
        package = Path(root.stdout.strip()) / "@google/gemini-cli/package.json"
        result["npm_package_present"] = package.is_file()
        if package.is_file():
            metadata = json.loads(package.read_text())
            result["installed_version"] = metadata.get("version")
try:
    with urllib.request.urlopen("https://registry.npmjs.org/-/package/@google/gemini-cli/dist-tags", timeout=10) as response:
        result["npm_dist_tags"] = json.load(response)
except (OSError, ValueError) as error:
    result["source_error"] = str(error)
print(json.dumps(result, ensure_ascii=False, indent=2))
