# Remote Catalog

The public contract is `__Assets__/Contentgen/Catalog/catalog-v1.schema.json`. Any producer may publish it: a Google Sheet exporter, GitHub Pages build, or a static HTTPS file.

## Producer rules

- Increase `revision` monotonically for every published change.
- Treat the catalog as a complete snapshot. Keep existing `catalogID` and entry `id`
  values stable; add a new ID rather than renaming or reusing one. Existing IDs stay
  present in later revisions, including when their support status changes.
- A changed document at the bundled revision must be published with a higher
  revision. The same ID and revision must always describe the same rules.
- Generate ISO 8601 timestamps.
- Match by bundle identifier first; constrain by signing team whenever possible.
- Never use a localized display name as identity.
- Treat paths as fallback evidence only. For applications with broken or missing
  bundle identifiers, prefer signing team plus a stable `CFBundleExecutable`
  value (`executableNames`) over the visible `.app` filename.
- Use HTTPS for every URL.
- Publish data only. Never place commands, scripts, or secrets in the catalog.
- Keep the response under 2 MiB.
- When a rule has no bundle identifier, require a verified signing team plus a
  path suffix or executable name. An executable or path alone is too broad.
- Keep update mechanism and version provider separate. The mechanism describes
  who owns installation; the provider only returns a comparable latest version.
- Set optional `publisher` to a verified company or brand. This is a display label,
  never matching evidence or a persisted rule ID.

## Client behavior

The client uses conditional requests and validates every accepted document. It
stores JSON bytes, source URL and response validators in one atomic cache record,
with a lock for concurrent GUI/CLI writes. It rejects lower revisions, changed
content at the same revision and removal of existing rule IDs for the same catalog.
The former
split JSON/metadata cache is ignored on upgrade because an interrupted write
could have associated one source's rules with another URL; offline users then
fall back to the bundled catalog until a new fetch succeeds. On a refresh
failure, only a valid cache from the fixed official endpoint can be used.

`expiresAt` is advisory: an expired catalog remains usable offline and shows a
warning, including after a 304 or local cache read. A missing expiry never
implies that the upstream version sources are fresh.

The app checks the fixed official HTTPS catalog at launch
and before each full scan. While the app remains open, including with its window closed
and only the menu bar item visible, it also checks the catalog every six hours. This
catalog-only schedule does not require periodic inventory checks to be enabled. A failed
check is retried after 15 minutes. Sleep pauses the timer; an overdue check runs after
wake when the app is no longer scanning or installing. The timer stops when the app quits.
An accepted new catalog ID or revision triggers one inventory scan using the validated
catalog cache, without a second catalog request. That scan may still contact version
providers. Unchanged revisions do not start an inventory scan. Users cannot change or
disable the official catalog source. Turning off catalog matching only disables applying
its rules; background checks continue. The official URL is now
`https://updateatlas.alperenalan.com/api/update-atlas/catalog-v1.json`.
Older builds using the main-site URL require an HTTPS redirect to this URL.

On 2026-10-23 the live official
catalog is revision 12 while the bundled catalog is revision 13. Publishing a remote
revision of at least 13 is needed before the fixed source can provide new rules to this build.

Catalog matching can be disabled globally or per rule in Settings. Checks continue when matching is off; disabled rules remain visible in Settings but are removed from the effective catalog before classification. Their preferences are namespaced by catalog ID and rule ID.

Settings groups rules by `publisher` and sorts both groups and their application
rules A–Z using the user's locale. Older v1 catalogs without this optional field
remain valid and appear under Other Publishers; per-rule preferences survive.

Schema evolution uses a new `schemaVersion`. A client rejects versions it does not understand instead of guessing.

## Identity matching

Bundle identifiers, signing team identifiers, executable names, and fallback
paths are compared case-insensitively after Unicode normalization.

When a rule declares `bundleIdentifiers`, a matching bundle identifier is the
primary identity and `pathSuffixes` are not required. If the rule also declares
`teamIdentifiers`, the signing team must match to protect against bundle-ID
collisions.

Rules for software with missing or unusable bundle identifiers can omit
`bundleIdentifiers` and match with a signing team plus either
`executableNames` or `pathSuffixes`. Executable identity wins when the visible
application filename is localized.

## Publication gate

`stage_channel.py` validates the complete candidate against the public v1
schema and client constraints, checks the current site and bundled baselines,
and rejects changed content without a revision bump or removed rule IDs. Its
manifest records bytes, hash, rule count, additions and changes. Copy the
staged catalog **and** its staged catalog contract into `Web/` as one reviewed
change. CI and the product-site Pages build run the staged validator and check
the catalog and contract hashes before deployment. Compare the
deployed HTTPS bytes with the staged hash after Alperen approves publication.

## Version providers

An entry with `support: supported` must declare an ordered `providers` chain, a
legacy single `provider`, or a legacy HTTPS `feedURL`. Provider adapters are
compiled into the client; the catalog can select adapters and provide HTTPS
URLs, but cannot ship executable parsing logic. `providers` is ordered from the
preferred source to its fallbacks. The client stops at the first successful,
channel-compatible result and records when a fallback supplied the answer.

All URLs in the chain are validated. A primary endpoint failure therefore does
not make the item uncheckable, while an insecure fallback invalidates the whole
catalog document. Existing version-1 documents using `provider` remain valid.

GitHub monorepos may publish several products from one Releases collection. Use
`versionPrefix` to admit only the intended product tags. When a vendor's tag is
not its comparable product version, `versionRegex` extracts capture group 1 from
the release tag and name. `includePrerelease` is explicit because some vendors
mark production artifacts as GitHub prereleases even when their in-product
channel is stable.

For products whose source release precedes a macOS binary, use the reviewed
`platformDownloadPage` adapter with `targetPlatform` and a bounded
`versionRegex` containing one numeric version capture. The adapter searches
only the named platform heading on the official HTTPS download page; if that
section or capture disappears, the check fails rather than assuming the global
release is installable. qBittorrent's macOS DMG is the first bundled use.

Version 1 currently supports Sparkle appcasts, Chrome Version History, GitHub's
latest-release API, Electron YAML manifests, the VS Code update service,
the VS Code extension marketplace, Apple's App Store lookup service, reviewed
vendor JSON documents, platform-specific download pages, Blender's official download page, and Homebrew Cask
metadata. When every configured provider fails, the result is a retryable check
failure, never guessed from the app's own version string. An identity without a
provider is surfaced as source resolution pending and belongs in the catalog
coverage queue rather than a permanent "not checkable" state.

Manager-owned components may still have providers. For example, ComfyUI is
discovered from Comfy Desktop's local `installations.json`, compared with the
stable ComfyUI GitHub release, and kept linked to Comfy Desktop for installation.

The bundled revision 3 rules add ES-DE's official release document plus stable
GitHub releases for RetroArch, Jellyfin Server, and Open Design. RetroArch cores,
launcher-owned games, and similar children remain manager-owned records; the
application release provider is not reused as evidence for the child version.

## First verified rule: Google Chrome

The bundled catalog's first rule identifies the signed macOS Stable application with:

- bundle identifier `com.google.Chrome`;
- signing team `EQHXZ8M8AV`;
- path suffix `/Google Chrome.app` as diagnostic fallback evidence only.

The rule selects the built-in `googleUpdater` provider adapter. That adapter queries Google's public Version History API over HTTPS and chooses `mac_arm64` or `mac` for the current machine. The catalog remains data-only: it selects a reviewed provider and does not execute code or supply a shell command.

Stable endpoint shape:

```text
https://versionhistory.googleapis.com/v1/chrome/platforms/{mac|mac_arm64}/channels/stable/versions?order_by=version%20desc&page_size=1
```
