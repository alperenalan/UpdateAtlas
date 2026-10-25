# Changelog

All notable changes to Update Atlas are documented here. The project follows semantic versioning.

## Unreleased

## 0.1.0 — 2026-10-25

First public release: signed and notarized for Apple silicon Macs running macOS 14 or later,
with source published under GPL-3.0-only. Highlights since the private test builds:

- Version checks never call software up to date when its installed version cannot be read; "2.0" equals "2.0.0", prereleases sort below their release, and an npm `latest` tag older than an installed prerelease is not offered as an update.
- Scans read only the start of each app executable; the CLI ignores relative `PATH` entries.
- Clearer plurals and word order in seven languages, collapsible technical details in the inspector, a native accent-colour picker, a Help menu and keyboard shortcuts.
- Software catalog revision 14 (364 rules) is bundled and served from the product site; a site that lags behind the bundled catalog no longer produces a warning.
- Sparkle asks once whether to check for Update Atlas updates automatically.
- MCP integration was removed from the release; the read-only CLI and Agent Skill remain.

### Earlier private builds

### Added

- GOG/Epic/Heroic installed-game discovery, additional native manager folders and live CrossOver/Whisky bottle environments.
- Discovery Settings for selected/external folders and optional current-connection Docker inventory; shared CLI preferences, per-command overrides and local discovery facts.
- Separate Docker object kinds/state/image identity and counts, with explicit unavailable-source diagnostics and no inferred container updates.
- Cancellable scans with progress phases, partial-discovery diagnostics and inventoried/verified/unverified coverage counts in the GUI and CLI.

### Removed

- User-inventory JSON coverage reports, including email drafts, local preview/export/copy, CLI `report preview`, and the feedback email configuration. Catalog candidates are researched from public sources instead.

### Fixed

- Package subprocess deadlines and output limits; timed-out or cancelled commands and their children cannot hold the scan stdout open indefinitely.
- GUI/CLI prerelease preference parity and inaccurate automatic catalog-queue wording.
- Inspector owner/source actions now precede technical details; built-in catalog use no longer implies a required custom URL.

### Previously prepared

- Searchable native catalog Settings with a source summary and remote URL drafts applied explicitly.
- CLI update/kind/owner/descendant filters and canonical versus returned summary counts.

- Optional development support links, official sidebar button artwork and a persistent, dismissible support sheet shown once after three qualifying scans.
- Native AppKit inventory headers with drag resizing, double-click fitting, width persistence, visibility controls and horizontal scrolling; reorganized sidebar categories. Native configuration/persistence regression coverage is present; visual runtime checks remain separate.

- Native macOS application inventory and update-source classification.
- Status and update-source grouping.
- Nested Unity Editor discovery under Unity Hub.
- Versioned HTTPS remote catalog with validation, rollback protection, and cache fallback.
- A purpose-built application icon representing software inventory and update sources.
- Open-source repository documentation and contribution templates.
