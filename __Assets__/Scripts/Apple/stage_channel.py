#!/usr/bin/env python3
"""Stage the signed feed and catalog for the static product site; never publish."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[3]
SCRATCH = ROOT / ".temporary_files"
VALIDATOR = ROOT / "__Assets__/Scripts/validate_channels.mjs"
BUNDLED = ROOT / "Apple/UpdateAtlas/Resources/BootstrapCatalog.json"
SITE_CONTRACT = {
    Path("Scripts/validate_channels.mjs"): ROOT / "__Assets__/Scripts/validate_channels.mjs",
    Path("Scripts/validate_site_catalog.mjs"): ROOT / "__Assets__/Scripts/validate_site_catalog.mjs",
    Path("Contentgen/Catalog/catalog-v1.schema.json"):
        ROOT / "__Assets__/Contentgen/Catalog/catalog-v1.schema.json",
    Path("Contentgen/Catalog/BootstrapCatalog.json"): BUNDLED,
}
FEED_RELATIVE = Path("appcast.xml")
CATALOG_RELATIVE = Path("api/update-atlas/catalog-v1.json")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate(feed, catalog):
    result = subprocess.run(
        ["node", str(VALIDATOR), str(feed), str(catalog)],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if result.returncode:
        raise ValueError(f"Signed channel validation failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def validate_site_contract(script):
    result = subprocess.run(["node", str(script)], capture_output=True, text=True,
                            timeout=30, check=False)
    if result.returncode:
        raise ValueError(f"Product-site catalog gate failed: {result.stderr.strip()}")


def item_versions(feed):
    channel = ET.fromstring(feed).find("channel")
    if channel is None:
        raise ValueError("Missing appcast channel")
    return {
        item.findtext(f"{{{SPARKLE}}}version"): ET.tostring(item, encoding="utf-8")
        for item in channel.findall("item")
    }


def check_continuity(candidate_feed, current_feed, candidate_catalog, current_catalog, bundled_catalog):
    candidate_items = item_versions(candidate_feed)
    for build, item in item_versions(current_feed).items():
        if build not in candidate_items or candidate_items[build] != item:
            raise ValueError(f"Current appcast item Build {build} was removed or changed")
    candidate = json.loads(candidate_catalog)
    current = json.loads(current_catalog)
    bundled = json.loads(bundled_catalog)
    if candidate["revision"] < current["revision"]:
        raise ValueError("Catalog revision is older than site catalog")
    # A feed-only release can retain the published catalog even when a newer
    # bundled revision exists. A catalog change must still catch up with it.
    if candidate_catalog != current_catalog and candidate["revision"] < bundled["revision"]:
        raise ValueError("Catalog revision is older than bundled catalog")
    if candidate["revision"] == current["revision"] and candidate_catalog != current_catalog:
        raise ValueError("Catalog content changed without a revision increase")
    if candidate_catalog != current_catalog and candidate["catalogID"] == bundled["catalogID"] and \
            candidate["revision"] == bundled["revision"] and candidate != bundled:
        raise ValueError("Catalog differs from bundled rules without a revision increase")
    if candidate_catalog != current_catalog:
        candidate_ids = {entry["id"] for entry in candidate["entries"]}
        for baseline_name, baseline in (("published", current), ("bundled", bundled)):
            removed = {entry["id"] for entry in baseline["entries"]} - candidate_ids
            if removed:
                raise ValueError(f"Catalog removed {baseline_name} rule IDs: {', '.join(sorted(removed)[:5])}")
    old_rules = {entry["id"]: entry for entry in current["entries"]}
    new_rules = {entry["id"]: entry for entry in candidate["entries"]}
    return {"builds": sorted((int(build) for build in candidate_items), reverse=True),
            "catalog_revision": candidate["revision"], "catalog_rules": len(candidate["entries"]),
            "catalog_added": len(new_rules.keys() - old_rules.keys()),
            "catalog_changed": sum(new_rules[key] != old_rules[key] for key in new_rules.keys() & old_rules.keys())}


def stage(feed_path, catalog_path, current_feed_path, current_catalog_path, output):
    scratch = SCRATCH.resolve()
    output = output.resolve()
    if (not output.is_relative_to(scratch) or output == scratch or output.exists() or
            (output.parent != scratch and not output.parent.is_dir())):
        raise ValueError("Use a new output directory under project .temporary_files")
    feed = feed_path.read_bytes()
    catalog = catalog_path.read_bytes()
    current_feed = current_feed_path.read_bytes()
    current_catalog = current_catalog_path.read_bytes()
    # Validate both candidate and deployed source; never use an invalid baseline.
    validate(feed_path, catalog_path)
    validate(current_feed_path, current_catalog_path)
    facts = check_continuity(feed, current_feed, catalog, current_catalog, BUNDLED.read_bytes())
    destinations = {
        "product_site": Path("product-site/Web/site") / FEED_RELATIVE,
        "product_catalog": Path("product-site/Web/site") / CATALOG_RELATIVE,
    }
    manifest = {
        "appcast": {"sha256": digest(feed), "bytes": len(feed),
                    "differs_from_baseline": feed != current_feed, "builds": facts["builds"]},
        "catalog": {"sha256": digest(catalog), "bytes": len(catalog),
                    "differs_from_baseline": catalog != current_catalog,
                    "revision": facts["catalog_revision"], "rules": facts["catalog_rules"],
                    "added_rules": facts["catalog_added"], "changed_rules": facts["catalog_changed"]},
        "catalog_contract": {str(destination): {"sha256": digest(source.read_bytes()),
                                                 "bytes": source.stat().st_size}
                             for destination, source in SITE_CONTRACT.items()},
        "destinations": {name: str(path) for name, path in destinations.items()},
    }
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="channel-stage-", dir=scratch) as temporary:
        staged = Path(temporary)
        for name, data in (("product_site", feed), ("product_catalog", catalog)):
            target = staged / destinations[name]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (staged / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        contract = staged / "product-site/Web/catalog-contract"
        for destination, source in SITE_CONTRACT.items():
            target = contract / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        (contract / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        verify(staged)
        # mkdir is exclusive; no existing candidate can be replaced. A manifest
        # appears only after both complete trees are in place.
        output.mkdir(exist_ok=False)
        for name in ("product-site", "manifest.json"):
            (staged / name).rename(output / name)
    return manifest


def verify(output):
    manifest = json.loads((output / "manifest.json").read_text())
    feed_path = output / manifest["destinations"]["product_site"]
    catalog_path = output / manifest["destinations"]["product_catalog"]
    for path, kind in ((feed_path, "appcast"), (catalog_path, "catalog")):
        data = path.read_bytes()
        if digest(data) != manifest[kind]["sha256"] or len(data) != manifest[kind]["bytes"]:
            raise ValueError(f"Staged {kind} differs from manifest")
    for relative, expected in manifest["catalog_contract"].items():
        data = (output / "product-site/Web/catalog-contract" / relative).read_bytes()
        if digest(data) != expected["sha256"] or len(data) != expected["bytes"]:
            raise ValueError(f"Staged catalog contract {relative} differs from manifest")
    validate(feed_path, catalog_path)
    validate_site_contract(output / "product-site/Web/catalog-contract/Scripts/validate_site_catalog.mjs")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", type=Path, required=True, help="Signed candidate appcast")
    parser.add_argument("--catalog", type=Path, required=True, help="Candidate catalog")
    parser.add_argument("--current-feed", type=Path, required=True, help="Current site source appcast")
    parser.add_argument("--current-catalog", type=Path, required=True, help="Current site source catalog")
    parser.add_argument("--output", type=Path, required=True, help="New .temporary_files staging directory")
    args = parser.parse_args()
    try:
        result = stage(args.feed, args.catalog, args.current_feed, args.current_catalog, args.output)
        print(json.dumps(result, sort_keys=True))
        print("Local files only. Review the manifest, then publish the site resources after approval.")
    except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Channel staging refused: {error}\n")
