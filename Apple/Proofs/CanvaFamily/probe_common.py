#!/usr/bin/env python3
"""Read-only installation and release-source probe for Canva desktop products."""

import json
from pathlib import Path
import plistlib
import subprocess
import urllib.request
import xml.etree.ElementTree as ET


AFFINITY_FEED = "https://things.seriflabs.com/affinity-update-mac-retail-studiopro"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def fetch(url):
    with urllib.request.urlopen(url, timeout=12) as response:
        return response.read(2_000_001)


def probe(app_name, bundle_id, cask, affinity_feed=False):
    paths = [Path("/Applications") / app_name, Path.home() / "Applications" / app_name]
    app = next((path for path in paths if path.is_dir()), None)
    result = {"product": app_name, "installed": app is not None, "bundle_id_expected": bundle_id}
    if app:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        result.update(path=str(app), bundle_id=info.get("CFBundleIdentifier"),
                      installed_version=info.get("CFBundleShortVersionString"),
                      installed_build=info.get("CFBundleVersion"))
        result["identity_matches"] = result["bundle_id"] == bundle_id
        signature = subprocess.run(["codesign", "--verify", "--strict", str(app)],
                                   capture_output=True, timeout=12)
        result["signature_valid"] = signature.returncode == 0
    try:
        release = json.loads(fetch("https://formulae.brew.sh/api/cask/" + cask + ".json"))
        result.update(cask=cask, cask_version=release.get("version"),
                      cask_deprecated=release.get("deprecated"),
                      cask_auto_updates=release.get("auto_updates"))
    except (OSError, ValueError) as error:
        result["cask_error"] = str(error)
    if affinity_feed and app:
        preferences = Path.home() / "Library/Preferences/com.canva.affinity.plist"
        try:
            with preferences.open("rb") as stream:
                feed = plistlib.load(stream).get("SUFeedURL")
            result["reviewed_feed_matches"] = feed == AFFINITY_FEED
            if feed == AFFINITY_FEED:
                root = ET.fromstring(fetch(feed))
                enclosure = root.find(".//item/enclosure")
                if enclosure is not None:
                    build = enclosure.attrib.get(SPARKLE + "version")
                    result["feed_version"] = enclosure.attrib.get(SPARKLE + "shortVersionString")
                    result["feed_build"] = build
                    installed = result.get("installed_build")
                    if str(build).isdigit() and str(installed).isdigit():
                        result["feed_comparison"] = ("candidate_newer" if int(build) > int(installed)
                                                     else "source_behind" if int(build) < int(installed)
                                                     else "same_build")
        except (OSError, ValueError, ET.ParseError) as error:
            result["feed_error"] = str(error)
    print(json.dumps(result, ensure_ascii=False, indent=2))
