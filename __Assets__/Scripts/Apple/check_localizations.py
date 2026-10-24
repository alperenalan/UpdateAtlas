#!/usr/bin/env python3
"""Check shipped UI string coverage without launching or building the macOS app."""
import json
import pathlib
import re
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "Apple/UpdateAtlas"
CATALOG = SOURCE / "Resources/Localizable.xcstrings"
LOCALES = ("tr", "ru", "de", "fr", "zh-Hans", "ja")


def placeholders(text):
    return Counter(re.findall(r"%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?[diuoxXfFeEgGaAcCsSp@]", text))


def main():
    data = json.loads(CATALOG.read_text())
    entries = data["strings"]
    errors = []
    if data.get("sourceLanguage") != "en":
        errors.append("Catalog source language must be English")

    unexpected = set().union(*(entry.get("localizations", {}) for entry in entries.values())) - set(LOCALES)
    if unexpected:
        errors.append(f"Unexpected locale resources: {sorted(unexpected)}")

    for key, entry in entries.items():
        for locale in LOCALES:
            unit = entry.get("localizations", {}).get(locale, {}).get("stringUnit", {})
            value = unit.get("value", "")
            if unit.get("state") != "translated" or not value.strip():
                errors.append(f"Missing {locale}: {key}")
            elif value != value.strip():
                errors.append(f"Leading or trailing whitespace {locale}: {key}")
            elif placeholders(value) != placeholders(key):
                errors.append(f"Placeholder mismatch {locale}: {key} -> {value}")

    # Source literals used as localized UI labels must have a catalog entry. Include
    # LocalizedStringKey arguments passed through view helpers: Xcode does not extract
    # them reliably, and omitting one left English text in Japanese onboarding.
    literal = re.compile(
        r'(?:String\(localized:|\blocalized\(|\b(?:Text|Button|Label|Toggle|Section|Picker|CommandMenu|Window|Link|ContentUnavailableView)\('
        r'|\.(?:help|accessibilityLabel|accessibilityValue|navigationTitle|searchable)\('
        r'|\.(?:messageText|informativeText|toolTip|placeholderString)\s*=|addButton\(withTitle:'
        r'|InspectorField\(\s*label:|\b(?:featureRow|preferenceToggle)\(\s*|\bdetail:|\bprogress\('
        r'|\bcase\s+(?:0|1|default):)'
        r'\s*"([^"\\]*(?:\\.[^"\\]*)*)"'
    )
    allow_untranslated = {"Update Atlas", "·"}
    view_argument = re.compile(r'\b(?:title|detail):\s*"([^"\\]*(?:\\.[^"\\]*)*)"')
    swift_sources = []
    for path in SOURCE.rglob("*.swift"):
        source = path.read_text()
        swift_sources.append(source)
        matches = list(literal.finditer(source))
        if "Views" in path.parts:
            matches.extend(view_argument.finditer(source))
        for match in matches:
            key = match.group(1)
            if key.strip() and "\\(" not in key and key not in entries and key not in allow_untranslated:
                errors.append(f"Uncataloged UI string {path.relative_to(ROOT)}: {key}")

        # Interpolated SwiftUI strings bypass the simple literal extraction above.
        # Pure counts/ratios are allowed; words outside interpolation need a key.
        for line_number, line in enumerate(source.splitlines(), start=1):
            for match in re.finditer(r'\b(?:Text|Button|Label)\(\s*"((?:[^"\\]|\\.)*)"', line):
                raw = match.group(1)
                if "\\(" not in raw:
                    continue
                static_part = re.sub(r"\\\([^)]*\)", "", raw)
                if re.search(r"[A-Za-z]", static_part) and "localized(" not in line:
                    errors.append(f"Interpolated UI copy needs a full localized key {path.relative_to(ROOT)}:{line_number}")

        # String(localized:) does not inherit SwiftUI's locale environment. On
        # macOS its locale argument alone also does not select an .lproj bundle.
        for line_number, line in enumerate(source.splitlines(), start=1):
            if "String(localized:" in line and (
                "bundle: AppL10n.bundle" not in line or "locale:" not in line
            ):
                errors.append(
                    f"Localized String ignores selected resources {path.relative_to(ROOT)}:{line_number}"
                )

    # Keep the catalog tied to text the app can actually display. Obsolete keys
    # inflate translation percentages and consume review time without covering UI.
    all_swift = "\n".join(swift_sources)
    for key in entries:
        if key not in all_swift and key.replace("\n", "\\n") not in all_swift:
            errors.append(f"Unused catalog key: {key}")

    language_settings = (SOURCE / "Models/LanguageSettings.swift").read_text()
    for locale in ("en",) + LOCALES:
        if f'code: "{locale}"' not in language_settings:
            errors.append(f"Selectable language missing: {locale}")
    if "extendedLanguageCodes" in language_settings:
        errors.append("Untranslated extended languages are still selectable")

    if errors:
        print("Localization validation failed:", file=sys.stderr)
        for error in errors[:100]:
            print(" -", error, file=sys.stderr)
        if len(errors) > 100:
            print(f" - ... {len(errors) - 100} more", file=sys.stderr)
        return 1
    print(f"Localization validation passed: {len(entries)} English keys and all {len(LOCALES)} translations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
