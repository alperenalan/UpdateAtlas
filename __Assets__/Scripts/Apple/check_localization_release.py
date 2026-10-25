#!/usr/bin/env python3
"""Fail closed on unreviewed translations and untested release localization.

This is a release gate, not a claim that a filled String Catalog is linguistically
correct. Reviews bind to the exact text, and native QA binds to the exact ZIP.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
REVIEWS = ROOT / "__Assets__/Docs/Localization/translation-reviews.tsv"
RUNTIME_QA = ROOT / "__Assets__/Docs/Localization/runtime-qa.tsv"
BASELINE = ROOT / "__Assets__/Docs/Localization/pre-review-baseline.json"
BASELINE_SHA256 = "d76289426080e2263bd0e8a0926878a556c04e23ab2043a4e48999078604421c"
DISMISSALS = ROOT / "__Assets__/Docs/Localization/review-dismissals.tsv"
REVIEW_FIELDS = ["item", "field", "hash", "source_hash", "reader", "date", "verdict", "note"]
SECOND_READERS = {"openai", "anthropic"}
APP_LOCALES = ("en", "tr", "ru", "de", "fr", "zh-Hans", "ja")
# Native QA on the exact archive covers the languages the maintainer reads; the other five
# locales rely on the two-family translation reads above (decided 2026-10-25).
QA_LOCALES = ("en", "tr")
QA_SURFACES = ("main", "onboarding", "settings", "menu-dialogs", "notifications",
               "cli", "dates-plurals", "layout-accessibility")


def digest(data):
    return hashlib.sha256(data).hexdigest()[:16]


def rows(path, fields):
    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source, delimiter="\t")
        if reader.fieldnames != fields:
            raise ValueError(f"Unexpected columns in {path.relative_to(ROOT)}")
        return list(reader)


def translations(scope):
    if scope == "app":
        catalog = json.loads((ROOT / "Apple/UpdateAtlas/Resources/Localizable.xcstrings").read_text())
        result = {}
        for key, entry in catalog["strings"].items():
            for locale, unit in entry["localizations"].items():
                result[(f"app:{key}", locale)] = (key, unit["stringUnit"]["value"])
                # Each plural form is its own reviewed line.
                for form, variant in unit.get("variations", {}).get("plural", {}).items():
                    result[(f"app:{key}#{form}", locale)] = (key, variant["stringUnit"]["value"])
        return result
    lines = (ROOT / "Web/site_copy.psv").read_text(encoding="utf-8").splitlines()
    languages = lines[0].split("|")[1:]
    result = {}
    for line in lines[1:]:
        if not line.strip():
            continue
        key, *values = line.split("|")
        if len(values) != len(languages):
            raise ValueError(f"Malformed site copy: {key}")
        result.update({(f"site:{key}", locale): (values[0], value)
                       for locale, value in zip(languages, values)})
    return result


def review_errors(scope, changed_only=False):
    source = translations(scope)
    records = rows(REVIEWS, REVIEW_FIELDS)
    dismissals = rows(DISMISSALS, ["item", "field", "hash", "source_hash", "reader", "reason", "decided_by", "date"])
    dismissed = {(r["item"], r["field"], r["hash"], r["source_hash"], r["reader"])
                 for r in dismissals if r["reason"].strip() and r["decided_by"].strip() and r["date"].strip()}
    if changed_only and hashlib.sha256(BASELINE.read_bytes()).hexdigest() != BASELINE_SHA256:
        raise ValueError("Pre-review baseline changed; review the new text instead")
    baseline = json.loads(BASELINE.read_text(encoding="utf-8")) if changed_only else {}
    indexed = {}
    for record in records:
        if (record["verdict"] not in ("ok", "fix", "flag") or ":" not in record["reader"]
                or not record["date"] or (record["verdict"] != "ok" and not record["note"])):
            raise ValueError("Invalid translation review record")
        indexed.setdefault((record["item"], record["field"], record["hash"], record["source_hash"]), []).append(record)
    pending = []
    checked = 0
    for (item, locale), (english, value) in source.items():
        source_hash = digest(english.encode("utf-8"))
        text_hash = digest(value.encode("utf-8"))
        if changed_only and baseline.get(scope, {}).get(item, {}).get(locale) == [source_hash, text_hash]:
            continue
        checked += 1
        if not value.strip():
            pending.append((item, locale, "empty"))
            continue
        current = indexed.get((item, locale, text_hash, source_hash), [])
        families = {r["reader"].split(":", 1)[0] for r in current
                    if r["verdict"] == "ok" or
                    (item, locale, text_hash, source_hash, r["reader"]) in dismissed}
        objections = [r for r in current if r["verdict"] != "ok" and
                      (item, locale, text_hash, source_hash, r["reader"]) not in dismissed]
        # Two independent model families must clear every line; Google is always one of them.
        if "google" not in families or not families & SECOND_READERS or objections:
            missing = ",".join(sorted(({"google"} - families) | ({"openai"} if not families & SECOND_READERS else set())))
            pending.append((item, locale, "open objection" if objections else f"missing {missing}"))
    return checked, pending


def cli_errors():
    # The CLI and its generated Agent Skill are developer tooling and stay English by design
    # (decided 2026-10-25). These findings are reported as notes and do not block a release.
    source = (ROOT / "Apple/UpdateAtlas/CLI/UpdateAtlasCLI.swift").read_text()
    progress = (ROOT / "Apple/UpdateAtlas/Services/CLIScanProgress.swift").read_text()
    issues = []
    if re.search(r'write\(\s*"""\s*\n\s*Update Atlas CLI', source):
        issues.append("CLI help remains English-only")
    if re.search(r'progress\.(?:update|finish)\(\s*"[A-Z]', source) or '"Starting scan…"' in progress:
        issues.append("CLI progress remains English-only")
    if re.search(r'fail\("[a-z_]+",\s*"[A-Z]', source):
        issues.append("CLI human-readable errors remain English-only")
    if 'write("Confirmation hash' in source or 'write("Could not encode JSON.' in source:
        issues.append("Other CLI status messages remain English-only")
    guide = (ROOT / "Apple/UpdateAtlas/Models/AIIntegrationGuide.swift").read_text()
    if "# Update Atlas — AI Agent Skill & CLI Guide" in guide:
        issues.append("Generated CLI skill guide remains English-only")
    return issues


def qa_errors(archive):
    archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    records = rows(RUNTIME_QA, ["archive_sha256", "locale", "surface", "reader", "date", "verdict", "note"])
    latest = {}
    for record in records:
        if record["archive_sha256"] == archive_hash:
            latest[(record["locale"], record["surface"])] = record
    passed = {key for key, record in latest.items()
              if record["verdict"] == "pass" and record["reader"] and record["date"]}
    return [(locale, surface) for locale in QA_LOCALES for surface in QA_SURFACES
            if (locale, surface) not in passed]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=("app", "site", "changed"), required=True)
    parser.add_argument("--archive", type=Path, help="exact signed app ZIP for native QA")
    args = parser.parse_args()
    if args.scope == "app" and args.archive is None:
        parser.error("app release check needs --archive")
    if args.scope != "app" and args.archive is not None:
        parser.error("only app release check uses an app archive")
    try:
        if args.scope == "changed":
            app_total, app_pending = review_errors("app", changed_only=True)
            site_total, site_pending = review_errors("site", changed_only=True)
            total, pending = app_total + site_total, app_pending + site_pending
        else:
            total, pending = review_errors(args.scope)
        cli = cli_errors() if args.scope == "app" else []
        qa = qa_errors(args.archive) if args.archive is not None else []
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        parser.exit(1, f"Localization release check unavailable: {error}\n")
    print(f"{args.scope}: {total - len(pending)}/{total} translations have two current-text readers")
    for item, locale, reason in pending[:12]:
        print(f"  {item} [{locale}]: {reason}")
    if len(pending) > 12:
        print(f"  ... {len(pending) - 12} more translation reviews pending")
    for issue in cli:
        print(f"  note (English by design, not blocking): {issue}")
    if qa:
        print(f"  {len(qa)} native QA surfaces pending for this exact archive; first: {qa[0]}")
    return 1 if pending or qa else 0


if __name__ == "__main__":
    sys.exit(main())
