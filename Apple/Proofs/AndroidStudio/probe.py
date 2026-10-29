#!/usr/bin/env python3
"""Read-only Android Studio plugin and SDK proof of concept for macOS."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import urllib.parse
import urllib.request
import zipfile


MAX_XML = 1_048_576
MAX_PACKAGES = 2_000
UPDATE_LINE = re.compile(r"^\s*(\S+)\s+(\S+)\s+->\s+(\S+)\s+(.+?)\s*$")
INSTALLED_LINE = re.compile(r"^\s*(\S+)\s+(\d[\w.+-]*)\s+(.+?)\s*$")


def xml_file(path):
    if not path.is_file() or path.stat().st_size > MAX_XML:
        return None
    return ET.fromstring(path.read_bytes())


def child_text(element, name):
    return next((child.text.strip() for child in element if child.tag.rsplit("}", 1)[-1] == name and child.text), None)


def plugin_metadata(folder, source):
    xml = folder / "META-INF" / "plugin.xml"
    try:
        root = xml_file(xml)
        if root is None:
            for jar in sorted((folder / "lib").glob("*.jar"))[:24]:
                with zipfile.ZipFile(jar) as archive:
                    try:
                        item = archive.getinfo("META-INF/plugin.xml")
                    except KeyError:
                        continue
                    if item.file_size > MAX_XML:
                        continue
                    root = ET.fromstring(archive.read(item))
                    break
    except (OSError, ValueError, zipfile.BadZipFile, ET.ParseError):
        root = None
    if root is None:
        return {"folder": folder.name, "source": source, "id": None, "name": folder.name, "version": None, "metadata": "unavailable"}
    return {
        "folder": folder.name,
        "source": source,
        "id": child_text(root, "id") or child_text(root, "name"),
        "name": child_text(root, "name") or folder.name,
        "version": child_text(root, "version"),
        "metadata": "plugin.xml",
    }


def sdk_location(home, data_name, override):
    if override:
        return Path(override).expanduser()
    config = home / "Library/Application Support/Google" / data_name / "options/android.sdk.path.xml"
    try:
        root = xml_file(config)
        for option in root.iter():
            if option.attrib.get("name") == "androidSdkAbsolutePath":
                value = option.attrib.get("value", "")
                if value.startswith("$USER_HOME$/"):
                    return home / value[len("$USER_HOME$/"):]
                if value.startswith("/"):
                    return Path(value)
    except (OSError, ET.ParseError, AttributeError):
        pass
    return Path(os.environ.get("ANDROID_HOME", home / "Library/Android/sdk"))


def sdk_packages(root):
    if not root.is_dir():
        return []
    rows = []
    for xml in sorted(root.rglob("package.xml"))[:MAX_PACKAGES]:
        try:
            document = xml_file(xml)
            package = next((node for node in document if node.tag.rsplit("}", 1)[-1] == "localPackage"), None)
            if package is None or not package.attrib.get("path"):
                continue
            revision = next((node for node in package if node.tag.rsplit("}", 1)[-1] == "revision"), None)
            pieces = {node.tag.rsplit("}", 1)[-1]: node.text for node in revision} if revision is not None else {}
            version = ".".join(str(pieces[key]) for key in ("major", "minor", "micro") if pieces.get(key) is not None)
            rows.append({"id": package.attrib["path"].replace(";", "/"), "version": version or None,
                         "path": str(xml.parent), "status": "unchecked"})
        except (OSError, ET.ParseError, TypeError):
            continue
    return rows


def installed_updates(cli, sdk):
    if not cli.is_file():
        return {}, "Android CLI not found; update status was not checked"
    try:
        result = subprocess.run([str(cli), "sdk", "list", f"--sdk={sdk}"], capture_output=True, text=True,
                                timeout=50, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {}, f"Android CLI failed: {exc}"
    if result.returncode:
        return {}, f"Android CLI exited {result.returncode}: {result.stderr.strip()[:300]}"
    updates = {}
    installed = set()
    in_installed = False
    for line in result.stdout.splitlines():
        if line.strip() == "Installed packages:":
            in_installed = True
            continue
        if line.strip().endswith("packages:"):
            in_installed = False
        if not in_installed:
            continue
        match = UPDATE_LINE.match(line)
        if match:
            installed.add(match.group(1))
            updates[match.group(1)] = {"installed": match.group(2), "available": match.group(3)}
        else:
            match = INSTALLED_LINE.match(line)
            if match:
                installed.add(match.group(1))
    if not installed:
        return {}, "Android CLI returned no parseable installed packages"
    return {"updates": updates, "installed": installed}, None


def plugin_updates(plugins, build):
    errors = []
    for plugin in plugins:
        if plugin["source"] == "bundled":
            plugin["status"] = "bundledWithIDE"
            continue
        plugin["status"] = "unchecked"
        ident = plugin["id"]
        if not ident or not re.fullmatch(r"[A-Za-z0-9._-]{1,160}", ident):
            continue
        query = urllib.parse.urlencode({"build": f"AI-{build.removeprefix('AI-')}", "pluginXMLId": ident})
        request = urllib.request.Request("https://plugins.jetbrains.com/api/search/updates?" + query,
                                         headers={"Accept": "application/json", "User-Agent": "UpdateAtlas-AndroidStudio-PoC"})
        try:
            with urllib.request.urlopen(request, timeout=12) as response:
                data = response.read(65537)
            if len(data) > 65536:
                raise ValueError("Marketplace response too large")
            matches = json.loads(data)
            if not isinstance(matches, list) or not all(isinstance(item, dict) for item in matches):
                raise ValueError("Marketplace response is not a plugin update list")
            versions = [item["version"] for item in matches if item.get("pluginXmlId") == ident
                        and item.get("channel", "") in ("", "stable") and isinstance(item.get("version"), str)]
            if not versions:
                plugin["status"] = "noCompatibleMarketplaceVersion"
                continue
            latest = versions[0]
            plugin["compatibleVersion"] = latest
            if latest == plugin["version"]:
                plugin["status"] = "noUpdateReported"
            elif (plugin["version"] and re.fullmatch(r"\d+(?:\.\d+)*", latest)
                  and re.fullmatch(r"\d+(?:\.\d+)*", plugin["version"])):
                available = tuple(map(int, latest.split(".")))
                installed = tuple(map(int, plugin["version"].split(".")))
                plugin["status"] = "updateAvailable" if available > installed else "noUpdateReported"
            else:
                plugin["status"] = "compatibleVersionDiffers"
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            errors.append(f"{ident}: {type(exc).__name__}")
    return errors


def inspect(studio, home, sdk_override=None, check=False):
    info_path = studio / "Contents/Resources/product-info.json"
    info = json.loads(info_path.read_text())
    data_name = info["dataDirectoryName"]
    if not re.fullmatch(r"AndroidStudio\d{4}\.\d+\.\d+", data_name):
        raise ValueError("Unexpected Android Studio settings directory name")
    user_root = home / "Library/Application Support/Google" / data_name / "plugins"
    bundled_root = studio / "Contents/plugins"
    plugins = []
    for source, root in (("user", user_root), ("bundled", bundled_root)):
        if root.is_dir():
            plugins.extend(plugin_metadata(item, source) for item in sorted(root.iterdir()) if item.is_dir())
    sdk = sdk_location(home, data_name, sdk_override)
    packages = sdk_packages(sdk)
    error = None
    plugin_errors = []
    if check:
        cli = studio / "Contents/plugins/android/resources/android-cli/bin/android"
        sdk_check, error = installed_updates(cli, sdk)
        if error is None:
            for package in packages:
                found = sdk_check["updates"].get(package["id"])
                package["status"] = ("updateAvailable" if found else "noUpdateReported"
                                     if package["id"] in sdk_check["installed"] else "unchecked")
                if found:
                    package["availableVersion"] = found["available"]
        plugin_errors = plugin_updates(plugins, info.get("buildNumber") or info["version"])
    else:
        for plugin in plugins:
            plugin["status"] = "bundledWithIDE" if plugin["source"] == "bundled" else "unchecked"
    return {
        "studio": {"path": str(studio), "version": data_name.removeprefix("AndroidStudio"),
                   "build": info.get("buildNumber") or info.get("version"), "settings": str(user_root.parent)},
        "plugins": plugins,
        "pluginCheckErrors": plugin_errors,
        "sdk": {"path": str(sdk), "packages": packages, "checkError": error},
        "capabilities": {"sdkList": True, "sdkPerPackageUpdateDocumented": (studio / "Contents/plugins/android/resources/android-cli/bin/android").is_file(),
                         "pluginUpdateCommandVerified": False, "pluginUpdateInIDE": True, "updatesPerformed": False},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--studio", type=Path, default=Path("/Applications/Android Studio.app"))
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--check", action="store_true", help="Use Android CLI to check installed SDK packages")
    args = parser.parse_args()
    try:
        snapshot = inspect(args.studio, Path.home(), args.sdk, args.check)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        parser.exit(2, f"Android Studio probe failed: {exc}\n")
    json.dump(snapshot, sys.stdout, indent=2, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
