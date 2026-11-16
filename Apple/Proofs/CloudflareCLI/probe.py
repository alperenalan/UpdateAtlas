#!/usr/bin/env python3
"""Read-only proof of Cloudflare cf's global npm ownership."""

import json
from pathlib import Path


def inspect(home=Path.home()):
    root = home / ".local/lib/node_modules/cf"
    command = home / ".local/bin/cf"
    result = {"product": "Cloudflare CLI (cf)", "packagePath": str(root),
              "cliPath": str(command), "installed": False, "installedVersion": None,
              "updateStatus": "notChecked", "updateRun": False}
    manifest = root / "package.json"
    if not manifest.is_file() or not command.is_file() or command.resolve() != (root / "bin/cf").resolve():
        return result
    try:
        metadata = json.loads(manifest.read_text())
    except (OSError, ValueError):
        return result
    if metadata.get("name") != "cf" or metadata.get("bin", {}).get("cf") != "./bin/cf":
        return result
    result["installed"] = True
    result["installedVersion"] = metadata.get("version")
    result["updateOwner"] = "npm"
    result["documentedUpdateCommand"] = "npm install --global cf@latest"
    return result


if __name__ == "__main__":
    print(json.dumps(inspect(), indent=2))
