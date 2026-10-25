#!/usr/bin/env python3
"""Prepare a signed Stable appcast locally. Never uploads or publishes a binary."""
import argparse
import base64
import email.utils
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlparse
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# The existing Ed25519 key keeps its historical Keychain account name. This is
# only a local key label; it is not the application's CFBundleIdentifier.
ACCOUNT = "dev.alperenalan.updateatlas"
BUNDLE_ID = "com.alperenalan.updateatlas"
PUBLIC_KEY = "1ckmV/xO043m/akIVdWxFXoODdka+37cN4KOv/THLMo="
TEAM = "N2FL7NN5HP"


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if result.returncode:
        # Never echo signing/keychain tool output or opaque subprocess input.
        raise ValueError(f"{Path(args[0]).name} validation failed")
    return result.stdout.strip()


def sparkle_tools_from_xcode():
    settings = run("/usr/bin/xcodebuild", "-showBuildSettings", "-project",
                   str(ROOT / "Apple/UpdateAtlas.xcodeproj"), "-scheme", "UpdateAtlas")
    build_dir = next((line.split(" = ", 1)[1] for line in settings.splitlines()
                      if line.strip().startswith("BUILD_DIR = ")), None)
    if not build_dir:
        raise ValueError("Could not locate Xcode DerivedData")
    derived_data = Path(build_dir).parents[1]
    return derived_data / "SourcePackages/artifacts/sparkle/Sparkle/bin"


def validate_zip(archive):
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if len(entries) > 25000 or sum(e.file_size for e in entries) > 2 * 1024**3:
            raise ValueError("Archive exceeds release size limits")
        for entry in entries:
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or ".." in name.parts or "\\" in entry.filename:
                raise ValueError("Unsafe archive path")
            if not name.parts or name.parts[0] not in ("Update Atlas.app", "__MACOSX"):
                raise ValueError("Archive must contain only Update Atlas.app and Apple ZIP metadata")
            if stat.S_ISLNK(entry.external_attr >> 16):
                if entry.file_size > 4096:
                    raise ValueError("Oversized symbolic link")
                target = bundle.read(entry).decode("utf-8")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(entry.filename), target))
                if target.startswith("/") or not resolved.startswith("Update Atlas.app/"):
                    raise ValueError("Symbolic link escapes application")


def validate_download_url(download_url, archive_name):
    parsed_url = urlparse(download_url)
    if parsed_url.scheme != "https" or parsed_url.hostname != "github.com" or parsed_url.username or parsed_url.password or parsed_url.port or parsed_url.query or parsed_url.fragment:
        raise ValueError("Use a credential-free HTTPS archive URL on GitHub Releases")
    if Path(parsed_url.path).name != archive_name or not archive_name.endswith(".zip"):
        raise ValueError("Download URL filename must match the exact archive")
    if ".." in parsed_url.path or not re.fullmatch(r"/alperenalan/UpdateAtlas/releases/download/[A-Za-z0-9][A-Za-z0-9._-]{0,79}/[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.zip", parsed_url.path):
        raise ValueError("Archive must belong to the UpdateAtlas GitHub Releases repository")


def validate_bundle_metadata(metadata):
    if metadata.get("CFBundleIdentifier") != BUNDLE_ID or metadata.get("SUPublicEDKey") != PUBLIC_KEY:
        raise ValueError("Unexpected application identity or Sparkle key")
    if metadata.get("SUFeedURL") != "https://updateatlas.alperenalan.com/appcast.xml":
        raise ValueError("Release must use the production appcast")
    for flag in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
        if metadata.get(flag) is not True:
            raise ValueError("Release must require signed feeds and validation before extraction")


def prepare(archive, existing_feed, download_url, output, tools):
    validate_download_url(download_url, archive.name)
    if not output.resolve().is_relative_to(ROOT / ".temporary_files"):
        raise ValueError("Preparation output belongs in project .temporary_files")
    validate_zip(archive)
    # A full catalog alone is insufficient: require two text readers and native QA
    # of this exact distributable before feed staging.
    result = subprocess.run([sys.executable, str(ROOT / "__Assets__/Scripts/Apple/check_localization_release.py"),
                             "--scope", "app", "--archive", str(archive)],
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ValueError("Localization release gate is open; run check_localization_release.py for details")
    scratch = ROOT / ".temporary_files/appcast-validation"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as extraction:
        run("/usr/bin/ditto", "-x", "-k", str(archive), extraction)
        app = Path(extraction) / "Update Atlas.app"
        metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        validate_bundle_metadata(metadata)
        build = str(metadata.get("CFBundleVersion", ""))
        if not build.isdecimal():
            raise ValueError("Release needs a numeric increasing bundle version")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
        signature = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, timeout=30).stderr
        if f"TeamIdentifier={TEAM}" not in signature or "Authority=Developer ID Application:" not in signature:
            raise ValueError("Release requires the owner's Developer ID signature")
        run("/usr/bin/xcrun", "stapler", "validate", str(app))
        run("/usr/sbin/spctl", "--assess", "--type", "execute", str(app))
        if run("/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/Update Atlas")) != "arm64":
            raise ValueError("Unexpected release architecture")
        version = str(metadata.get("CFBundleShortVersionString", ""))
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
            raise ValueError("Stable feed does not accept prerelease marketing versions")
        minimum_os = str(metadata.get("LSMinimumSystemVersion", "14.0"))
    # Do not silently replace an existing channel or accept broken current metadata.
    tree = ET.parse(existing_feed)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("Missing appcast channel")
    prior_versions = [int(node.text) for node in channel.findall(f"item/{{{SPARKLE}}}version")]
    if prior_versions and int(build) <= max(prior_versions):
        raise ValueError("Build version must increase; downgrades are prohibited")
    if run(str(tools / "generate_keys"), "--account", ACCOUNT, "-p") != PUBLIC_KEY:
        raise ValueError("Signing key does not match the application's verification key")
    run(str(tools / "sign_update"), "--account", ACCOUNT, "--verify", str(existing_feed))
    ed_signature = run(str(tools / "sign_update"), "--account", ACCOUNT, "-p", str(archive))
    if len(base64.b64decode(ed_signature, validate=True)) != 64:
        raise ValueError("Invalid archive signature")
    ET.register_namespace("sparkle", SPARKLE)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Update Atlas {version} (Build {build})"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = minimum_os
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, "enclosure", {"url": download_url, "length": str(archive.stat().st_size),
        "type": "application/octet-stream", f"{{{SPARKLE}}}edSignature": ed_signature})
    channel.insert(0, item)
    # The empty pre-release feed said no public release existed; a feed with items must not.
    description = channel.find("description")
    if description is not None:
        description.text = "Signed and notarized Update Atlas releases for macOS."
    output.mkdir(parents=True, exist_ok=False)
    feed = output / "appcast.xml"
    tree.write(feed, encoding="utf-8", xml_declaration=True)
    run(str(tools / "sign_update"), "--account", ACCOUNT, str(feed))
    run(str(tools / "sign_update"), "--account", ACCOUNT, "--verify", str(feed))
    shutil.copyfile(archive, output / archive.name)
    print(f"Prepared Build {build}; nothing was uploaded. Review {output} before publication.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--existing-feed", type=Path, required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tools", type=Path, help="Sparkle tools directory; defaults to Xcode's resolved DerivedData")
    args = parser.parse_args()
    try:
        prepare(args.archive, args.existing_feed, args.download_url, args.output,
                args.tools or sparkle_tools_from_xcode())
    except (ValueError, OSError, subprocess.SubprocessError, ET.ParseError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Release preparation refused: {error}\n")
