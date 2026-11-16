#!/usr/bin/env python3
"""Read-only proof of Ollama's macOS app and CLI ownership."""

import json
from pathlib import Path
import plistlib


def inspect(app=Path("/Applications/Ollama.app"), command=Path("/usr/local/bin/ollama")):
    binary = app / "Contents/Resources/ollama"
    result = {"product": "Ollama CLI", "appPath": str(app), "cliPath": str(command),
              "installed": command.is_file(), "appOwned": False, "installedVersion": None,
              "updateStatus": "notChecked", "updateRun": False}
    if not result["installed"] or not binary.is_file() or command.resolve() != binary.resolve():
        return result
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            metadata = plistlib.load(stream)
    except (OSError, ValueError):
        return result
    if metadata.get("CFBundleIdentifier") != "com.electron.ollama":
        return result
    result["appOwned"] = True
    result["installedVersion"] = metadata.get("CFBundleShortVersionString")
    result["updateOwner"] = "Ollama app updater"
    return result


if __name__ == "__main__":
    print(json.dumps(inspect(), indent=2))
