# Update Atlas — technical notes

Detailed behaviour notes for contributors. The overview is the root [README](../../README.md).

## What works

- Scans `/Applications` and `~/Applications`; macOS system application folders are optional. Settings > Discovery can add up to 16 application/game-library folders, including mounted external disks. Traversal is bounded, nested app contents and child symlinks are skipped, and canonical locations deduplicate.
- Reads GOG Galaxy's installed table, GOG game manifests, Epic `.item` manifests and Heroic Epic/GOG installed records. A live payload is required; owned/download-only records and removed games do not become installations. Native bundle versions remain separate from store manifest versions.
- Finds Setapp applications, legacy JetBrains Toolbox IDE roots and Adobe applications nested in reviewed application folders. Current Toolbox apps in `~/Applications` are already scanned normally; an IDE's bundle ID alone never proves Toolbox ownership. Custom manager install folders can be added explicitly.
- Lists live CrossOver/Whisky bottle environments, including external Whisky paths registered in `BottleVM.plist`. It does not crawl arbitrary Windows programs or execute Wine.
- Offers off-by-default Docker discovery through the current Docker CLI connection: context, Compose project/service, running/stopped containers, immutable image identity/platform and volume names. No daemon auto-start, pulls, guest execution, registry queries or collection of environment/mount/credential data. Only the two Compose identity keys are projected from labels, never the full label map. Containers and images are distinct local objects and do not inflate application counts. Offline/permission/malformed-result failures remain visible diagnostics.
- Discovers Unity Editor installations nested under Unity Hub.
- Discovers games in Steam's default and configured library folders from live installation manifests, plus common GOG library folders; App Store and standalone games are recognized from their bundle category. A newer Steam `TargetBuildID` is shown as a client-owned update, while a missing target remains manager-owned rather than falsely current.
- Matches Homebrew Cask applications against the exact app targets reported by Homebrew.
- Inventories requested Homebrew formulae, global top-level npm packages, top-level Python/pip packages, persistent pipx and uv tools, and Cargo-installed binaries. Multiple known npm and Python environments stay distinct.
- Finds eight reviewed standalone CLI footprints (Cua Driver, Antigravity CLI, Claude Code, uv, Bun, Deno, rustup and mise) at their documented default paths. Broken launchers appear as installation remnants, not installed tools. These checks never execute the discovered binaries; except for a Claude native versioned link, installed versions and update availability remain unresolved until a verified source is added.
- Detects App Store receipts, Sparkle, Squirrel/Electron, Google Updater, external managers, and system-owned apps.
- Separates Hermes Desktop from a live, source-installed Hermes Agent. A main-branch Agent checkout is checked by Git commit against the official repository; placeholder desktop versions are never compared with Agent releases. Packaged desktop update availability remains source-pending until a verified desktop feed is available.
- Checks Homebrew, global npm, top-level pip, public Sparkle appcasts, and official Chrome channel versions. pipx, uv tool and Cargo inventory is shown as source-pending until a verified latest-version provider is available.
- Reads Android Studio's complete release version from its own bundle and checks Google's official stable release page first. Homebrew is only a guarded fallback; its extra package revision cannot trigger a false IDE update.
- Checks qBittorrent against the macOS DMG section of its official download page, not its newer cross-platform source tag.
- Tracks provider coverage separately from update availability, including installed/latest versions, source, and check time.
- Supports ordered, validated provider chains and automatically falls back when a preferred release source is temporarily unavailable.
- Normalizes Stable, LTS, RC, Beta, Alpha, Canary, Nightly, and vendor-defined release channels; Stable installs do not receive prerelease suggestions without explicit opt-in.
- Shows release-channel badges in the inventory and inspector, and carries channel metadata through Sparkle, GitHub, manager, and catalog checks.
- Suppresses false updates when the provider returns the same installed and latest version.
- Uses an AppKit table for native column headers, drag resizing, double-click width fitting, sort indicators, column visibility controls, row selection and Up/Down keyboard navigation. Column widths persist; narrow windows scroll horizontally instead of redistributing widths.
- Places update status and software first in the sidebar, with collapsible game/client and package-manager categories. A compact support link uses the shared support URL.
- Groups the inventory by provider support, update status, or update source.
- Splits the sidebar into All in One, regular Applications, Command-line Tools, Games, Package Managers and discovered Containers; All in One includes every scanned source.
- Keeps Update Status separate from mechanism coverage, with Update Available and Up to Date available directly in the sidebar. Update Available is the default launch view and can be changed in Settings.
- Lives in the macOS menu bar by default when the main window is closed, preserving existing saved preferences. The menu lists confirmed app/game/package updates with local application icons (kind symbols for non-app items); choosing one reopens its detail. The badge and menu bar presence remain configurable. Quit explicitly exits the app.
- Update Status views span the complete inventory, including games, game clients and manager-owned packages. Update Available and its count use the same confirmed results as the menu bar.
- The Applications category and mechanism coverage retain their regular-app scope; separate game and package-manager categories remain available.
- Shows the evidence and confidence behind every classification.
- Excludes applications managed by macOS by default; the standard tabbed Settings window can opt them in.
- Uses a seven-language String Catalog while preserving vendor names and technical identifiers, plus native Liquid Glass controls on macOS 26 with a macOS 14 material fallback.
- Introduces its read-only and network-check behavior on first launch, then lets users choose the initial view and scan defaults.
- Labels the active catalog source and distinguishes empty searches from genuinely confirmed no-update results.
- Checks the fixed official HTTPS catalog at launch, before online checks, and every six hours while running, including menu-bar-only operation. Conditional requests, integrity validation and a bundled fallback protect offline use; no inventory is uploaded.
- Ships a first verified catalog rule for signed Google Chrome Stable installations and resolves versions through Google's public Version History API.
- Presents the fixed catalog source, revision and active-rule counts in native grouped Settings, with searchable publisher/app rules.
- Lets users disable catalog matching globally or toggle individual rules; official catalog checks continue, while disabled rules do not participate in classification.
- Ships one purpose-built Finder and Dock icon representing an inventoried software package.

## Run

```sh
cd Apple
xcodegen generate
open UpdateAtlas.xcodeproj
```

The project targets macOS 14 or newer on Apple silicon (`arm64`). Intel-only and universal Update Atlas binaries are intentionally out of scope, while Intel applications and package-manager environments installed on an Apple silicon Mac remain valid inventory inputs. The app sandbox is intentionally disabled because the app needs read access to application bundles outside its container.

The app bundles a read-only `update-atlas` command-line tool. Choose **Update Atlas → Install Command Line Tool…** to review the destination, command examples and PATH guidance, then press **Install** to link it into `~/.local/bin` (no administrator access or shell profile changes). The top-right close button or Escape dismisses the explanation without installing; existing files or other tools are never overwritten. Add that directory to your shell's `PATH` if needed. `update-atlas scan` prints a path-free JSON inventory without refreshing the app catalog or checking app version sources; `update-atlas check` additionally refreshes configured sources and checks versions. **`scan` is not guaranteed offline:** package-manager inventory invokes tools such as `npm outdated` and `pip list --outdated`, which may contact their configured registries. Use `scan --offline` or `check --offline` for local-only discovery without launching package managers or fetching sources. Homebrew/npm local receipts are included; other package environments and Docker are explicitly skipped. Offline checks never claim a verified latest version. Use `--include-system` to include macOS apps and `--include-paths` only when local paths and provider details are needed. The response has `schemaVersion: 1`, opaque IDs, and a `checkPerformed` flag. The CLI never installs third-party updates. The optional additive `updateAction` identifies a GUI action: `sparkleConfirmation`, `homebrewConfirmation`, `microsoftAutoUpdateConfirmation`, or `appStorePage`. Manager availability and target eligibility use the same policy in GUI/CLI; identity/ownership/running-app checks are repeated when requested. The CLI exposes no installation command.

Output filters can be combined: `--updates-only`, `--kind KIND`, and either `--manager OPAQUE_ID` (owner plus descendants) or `--children-of OPAQUE_ID` (descendants only). Obtain IDs from an unfiltered inventory. Unknown owner IDs fail with exit code 2; an existing owner with no matching children returns an empty `items` array successfully. Filtering occurs after scanning/checking, so it does not limit network access or scan scope.

```sh
update-atlas check --updates-only
update-atlas scan --kind package
update-atlas check --children-of OPAQUE_ID --updates-only
```

`scan` and `check` now show live progress immediately on **stderr when it is a terminal**:
a moving status line with elapsed seconds, the current package-environment/discovery stage,
and completed/total items during source checking. Long commands keep the indicator moving;
the completion line includes inventory/returned counts and any partial-scan warning count.
JSON still arrives as one schema-v1 document on stdout after completion. Redirecting stdout
to a file or `jq` keeps progress visible if stderr remains attached to the terminal. When stderr
is redirected, automatic progress is silent. Use `--progress` to force newline-based progress
in logs (with a heartbeat every five seconds), or `--no-progress` to disable it everywhere.
`TERM=dumb` gets plain lines instead of terminal escape sequences. Progress contains no local
paths and does not change scanning, filters, deadlines, JSON fields or exit codes.

```sh
update-atlas scan > inventory.json         # progress remains visible on the terminal
update-atlas check --progress > results.json 2> progress.log
update-atlas scan --no-progress | jq '.summary'
```

The current source resolves the executable's symlink before locating the containing app's
catalog and version metadata. Shell installation through `~/.local/bin/update-atlas`, relative
link chains and renamed app bundles use the actual app resources. Commands validate the usable
local catalog before starting package discovery; an absent/invalid catalog still exits with code
3 with a schema-v1 JSON error envelope. No catalog is adopted from the caller's current directory. Older Build
28 helpers have a symlink lookup bug; until a new build is installed, invoke the helper directly:

```sh
"/Applications/Update Atlas.app/Contents/MacOS/Helpers/update-atlas" scan
```

Schema-v1 output adds a `summary` object: `inventoryItemCount`, `availableUpdateCount`, `sourcePendingCount` and `checkFailedCount` describe the full inventory; `returnedItemCount` and `returnedUpdateCount` describe the filtered output. Existing item fields and opaque-ID hashing are unchanged. Counts represent inventory items, including managed children, rather than a count of top-level apps. New consumers should tolerate additive JSON fields. The additive `coverage` object counts full-inventory items, verified current/newer versions, unverified items, failed checks and manager-owned items; `scanDiagnostics` exposes path-free discovery failures. Partial scans retain their JSON but exit with code 5. Expected offline skips and source-pending versions alone are not failures. Invalid CLI arguments return a JSON error and code 2. `--fail-on-updates` returns code 10 for otherwise complete results containing confirmed updates; cancellation returns 130. See the [CLI contract](../../__Assets__/Docs/CLI-Contract.md) for precedence and all commands.

The CLI supports a real offline mode, allowlisted shared settings, folder preferences and catalog matching/rule management. The official catalog source is fixed. Watch mode remains deferred; background checks belong to the running GUI app. `scan` and `check` return JSON to the local caller; the CLI has no catalog-coverage report command or submission action. New discovery, classification, version checks and status fields must be supported and regression-tested in both GUI and CLI before an iteration is considered complete; visual-only features do not need a terminal equivalent.

The first release includes the read-only CLI and an optional Agent Skill. Onboarding explains the link and PATH, then its Install CLI button installs directly; the app menu and Settings offer a separate explanation window. Copy `SKILL.md` from onboarding or Settings, or print it with `update-atlas skill`. The skill instructs an AI coding assistant to use local CLI commands; MCP integration is deferred.

For direct distribution, use an Xcode archive and Developer ID export with [`Apple/exportOptions.plist`](../../Apple/exportOptions.plist), then notarize the exported app, staple its ticket, and create the ZIP. A plain `xcodebuild build` can leave Sparkle helpers ad-hoc signed and is not a distribution artifact. Verified ZIPs and DMGs are published as this repository's versioned GitHub Releases assets. The app's stable client-facing signed feed and catalog URLs live on `updateatlas.alperenalan.com`; publication copies are staged and checked against those URLs.

Scans remain read-only and run at launch, on request or on an explicitly enabled 1/6/12/24-hour schedule (default interval 6 hours). The schedule only runs while Update Atlas is running, including with its main window closed in the menu bar. It pauses during sleep, performs at most one overdue check after wake, avoids overlapping scans/install sessions and stops on Quit. Eligible standalone Stable Sparkle apps have an explicit GUI update action: their embedded HTTPS feed/EdDSA key and valid installed code signature are required, the app must be closed first, and Sparkle asks before downloading/installing. Homebrew-owned Stable items and supported Microsoft AutoUpdate apps additionally have explicit manager confirmation flows described below. App Store apps open their identity-matched product page. No real third-party installation has been verified yet. Firmware, full game-client breadth and CLI watch remain later scope. Scans share a time budget, report progress in the GUI and preserve the previous GUI inventory on cancellation; package subprocesses also enforce per-command deadlines and output limits.

## User-confirmed manager updates

The inspector offers **Update with Homebrew…** only for a verified, outdated Stable
Homebrew formula/cask owned by `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`. It confirms
one selected package plus required dependencies, re-reads its installed record, version and
actual target, and refuses pinned formulae, prereleases and casks without a SHA-256 checksum.
Named `brew upgrade --formula/--cask` commands run directly without a shell, force/adopt/zap
or sudo; casks use `--no-quit` and `--require-sha`. Auto-refresh, global cleanup, unrelated
dependent upgrades and analytics are disabled for this operation. Required dependencies and
Homebrew's own installer scripts may still run; macOS authorization remains the manager's job.
The app never closes the target forcibly. [Homebrew command reference](https://docs.brew.sh/Manpage).

**Check and Update with Microsoft AutoUpdate…** is available when the standard MAU `msupdate`
executable exists, for catalog-recognized, Microsoft-signed Word, Excel, PowerPoint, Outlook,
OneNote and OneDrive in their standard `/Applications` locations. Both target and MAU signatures
are rechecked. The confirmation explains MAU's existing configured channel; it is not altered.
A single compiled application ID is passed with `--install --apps ID --wait 600`, without
`--terminate`. MAU owns availability, downloads, authorization and installation. Its daemon can
keep an installation pending after returning; unchanged local versions are never reported as
successful installation. Teams and Edge have no adapter here. [Microsoft msupdate reference](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/update-office-for-mac-using-msupdate).

Manager work runs off the main actor, streams bounded output to the inspector, prevents
concurrent scans/installers and keeps output available after completion. Quit is held until
an active manager command finishes, including when the menu bar is disabled. Commands have
bounded waits/output; timeout or failure explicitly warns that installation may be incomplete
or still pending in the manager. List rows have a prominent Update button for confirmed, eligible
Sparkle/Homebrew/MAU targets; App Store remains a page-opening action. After a cycle returns,
only that installation is reread and checked against its source. A Homebrew refresh reads only
the selected token; other rows, dependencies, full-scan date and periodic scheduling stay intact.
An unreadable or replaced target becomes Check Failed; cancellation preserves prior results.
Only a changed installed version
(and no remaining outdated flag for Homebrew) is labeled verified. No unattended installation,
pip, pipx, uv, npm or Cargo update execution is included. Actual signed-app installs and native
authorization/UI behavior still need a separately authorized build and disposable-target test.

**Open App Store Page** opens the matching product link in the native App Store, with a web
fallback if the store app is unavailable. A fresh Apple lookup resolves missing links; bundle ID
must match and the returned link must be an HTTPS `apps.apple.com` product URL. Lookup failures
do not open a guessed or unrelated page. Updates remain App Store-owned.

## Update notifications

General Settings offers native macOS local notifications, independent of scheduled checks. They
default on for new or previously unset preferences, while an explicit off choice remains off.
When enabled, the app requests macOS permission before the first launch scan; scans never request it. Denied
permission offers a macOS Settings link; sound is off by default. Each clean completed scan emits
at most one digest for newly confirmed versions across apps, games, package managers and children.
Accepted version fingerprints and opaque item IDs persist on this Mac, so relaunches/repeated scans
or a source rollback do not reannounce a version. Failed delivery retains eligibility for a later
scan. Partial/cancelled scans do not notify. A single-item notification opens the item's detail;
a digest opens the update list. Scheduled scans do not count toward the support reminder.

No APNs backend or launch daemon is introduced; an optional macOS login item can start the app. CLI checks remain one-shot and do not
schedule or notify; they already expose the same update facts used for notification decisions.
Native macOS permission/banner and end-to-end sleep/window behavior still need signed-app testing;
service fixtures and a real AppKit timer are verified without changing the user's notification permission.

## Remote catalog contract

The app reads a single HTTPS JSON document matching [`__Assets__/Contentgen/Catalog/catalog-v1.schema.json`](../../__Assets__/Contentgen/Catalog/catalog-v1.schema.json) from the fixed official URL `https://updateatlas.alperenalan.com/api/update-atlas/catalog-v1.json`. The catalog lives in `Web/site/api/update-atlas/catalog-v1.json` and is served as a static file.

The catalog is data-only: it cannot contain shell commands or executable install recipes. Entries match bundle identifier first and may additionally constrain signing team and path suffix. A monotonically increasing `revision` prevents a previously cached catalog from being silently replaced by an older revision.

To publish a complete new snapshot, stage and validate it with [`stage_channel.py`](../../__Assets__/Scripts/Apple/stage_channel.py), copy the staged catalog and hash contract into `Web/`, and run the catalog-gated site build. After publishing, compare the live HTTPS bytes with the staged hash. Keep the v1 URL available to installed clients if a later schema or host changes.

Bundled rules work offline. At launch, before online checks and every six hours while the app process runs, the client:

1. requests the fixed official HTTPS URL without using an HTTP cache;
2. uses `ETag` and `Last-Modified` for conditional requests;
3. limits the response to 2 MiB;
4. decodes and validates schema version, URLs, unique IDs, generation time, and revision;
5. atomically caches the accepted document with its source and HTTP validators;
6. falls back to the last validated cache, then the bundled bootstrap catalog.

Future catalog-based install flows must resolve candidates against `RemoteCatalogService.freshSnapshotBeforeUpdate()`. Current Sparkle updates use embedded bundle configuration, and current Homebrew/MAU commands are compiled into the app and revalidate local ownership immediately before installation; catalogs cannot provide install recipes.

Catalog entries may use the legacy singular `provider` field or an ordered `providers` array. The client tries the array in order, accepts the first successful channel-compatible result, and reports a retryable failure only when every configured source fails. Software identities without a source remain pending.

GitHub-backed monorepos can filter product-specific tag prefixes and extract a comparable semantic version from release names, avoiding stale `releases/latest` pointers and unrelated product tags. A `platformDownloadPage` provider can instead scope a version capture to one OS heading on an official download page; the bundled qBittorrent rule uses it so a Windows/Linux/source release cannot trigger a Mac update.

See [`__Assets__/Docs/catalog.md`](../../__Assets__/Docs/catalog.md) for producer guidance and [`__Assets__/Contentgen/Catalog/example.catalog.json`](../../__Assets__/Contentgen/Catalog/example.catalog.json) for a minimal payload.

The local [catalog editor](../../Web/catalog-editor/README.md) provides searchable table and rule forms. It saves validated drafts outside Git and exports a complete JSON candidate for the existing staging and publication gates; it does not publish.

## Project shape

- `ApplicationScanner`: local app and nested-manager discovery, enriched with package-manager provenance.
- `PackageInventoryScanner`: bounded, direct-process adapters and parsers for Homebrew, npm, Python/pip, pipx, uv tool, and Cargo inventory.
- `DirectInstallScanner`: reviewed default-path checks for standalone CLIs (including Starship's documented direct-install locations), with broken-link and package-manager deduplication.
- `UpdateDetectionEngine`: deterministic classification with provenance-first precedence.
- `RemoteCatalogService`: transport, validation, rollback protection, and caching.
- `AppInventoryViewModel`: presentation state, grouping, filtering, and scan orchestration.
- `__Assets__/Contentgen/Catalog/`: public schema and an example producer output.
- `Web/catalog-editor/`: local browser editor for preparing validated catalog candidates.

## Repository

- `Apple/UpdateAtlas/`: application source, editable `.icon` documents, and bundled bootstrap data.
- `Apple/UpdateAtlas/Assets.xcassets/AppIcon.appiconset/`: generated icon sizes; its tracked 1024 px PNG is byte-identical to the local high-resolution source in `__Assets__/Design/AppIcons/`.
- `Apple/UpdateAtlasTests/`: catalog transport, detection, version-provider, inventory presentation, and preference tests.
- `__Assets__/Contentgen/Catalog/`: public remote-catalog contract and sample data.
- `__Assets__/Docs/`: architecture, catalog, branding, design QA notes, and the changelog.
- `.github/`: CI, issue forms, pull-request guidance, and the contributing and security notes.

## License

Copyright (C) 2026 Alperen Alan. Original application and CLI code, catalog data, site source, documentation and artwork in this repository are licensed under [GNU GPL version 3 only](../../LICENSE) (`GPL-3.0-only`). Distributed modified versions must meet its source and notice obligations. The license does not make an unofficial build an official Update Atlas release. Sparkle retains its own license and [third-party notices](../../THIRD_PARTY_NOTICES.md).


## Additional discovery in the CLI

`scan` and `check` use the same saved Discovery preferences as the GUI. Add `--folder /absolute/path`
(repeatable) for command-only roots; `--docker` or `--no-docker` overrides the saved Docker choice
without persisting it. Folder and Docker flags also work with the existing output filters. `--kind`
accepts `wineBottle`, `containerContext`, `composeProject`, `container`, `containerImage` and
`containerVolume` in addition to existing kinds. `discovery` is an optional additive schema-v1
object containing the source, role, platform/state and relevant store/image/service facts; paths
still require `--include-paths`. Docker objects and Wine bottles use `releaseChannel: notApplicable`
instead of a guessed software release channel. Parent IDs remain opaque and support `--manager`/`--children-of`.
A missing Docker CLI or unreadable Galaxy database is a diagnostic, never evidence of an empty
successful source. Docker image tags have no version comparison or update/install action.
