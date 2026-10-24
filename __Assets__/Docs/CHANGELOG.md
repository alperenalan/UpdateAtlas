# Changelog

All notable changes to Update Atlas will be documented here. The project follows semantic versioning once its first public release is published.

## Unreleased

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
