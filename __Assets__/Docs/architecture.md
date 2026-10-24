# Architecture

Update Atlas separates local facts from remote knowledge.

1. `PackageInventoryScanner` queries installed package managers with fixed argument lists and parses their structured output.
2. `ApplicationScanner` discovers application bundles, nested managers, and immutable local evidence; exact Homebrew Cask targets enrich matching apps. Manager state adapters can also emit non-bundle children such as a ComfyUI core installation or a VS Code extension. `DirectInstallScanner` then checks a reviewed allowlist of publisher-documented default CLI paths without executing those files or fetching installer scripts.
3. `RemoteCatalogService` retrieves and validates a data-only catalog.
4. `UpdateDetectionEngine` applies deterministic precedence rules to local evidence and catalog matches. Mechanism ownership and latest-version providers remain separate.
5. `AppInventoryViewModel` exposes stable presentation state to SwiftUI.
6. Views present the classification, evidence, confidence, package-manager ownership, and manager relationships.

The primary library scopes are mutually exclusive except for the aggregate view: `Applications` contains `.app` bundles without package-manager provenance, `Command-line Tools` contains standalone CLI findings without package-manager provenance, `Package Managers` contains every item with verified manager provenance (including GUI apps installed as Homebrew casks), and `All in One` is their complete union including macOS system applications.

Standalone CLI detection is deliberately conservative: a regular executable must be present at a reviewed default path. Starship's documented `~/.local/bin/starship` and `/usr/local/bin/starship` locations are checked; a Homebrew Cellar target or Cargo binary link is not claimed as a direct installation. Package-manager-owned targets are suppressed, and a broken symlink is exposed as an installation remnant rather than an installed product. A path alone does not authenticate the installer or prove a version; the Claude native versioned-link layout is the one currently parsed version. The documented route is described as a publisher CLI installer, not universally as a self-updater. Until a verified version provider exists, mechanism coverage is `Needs Catalog` and the update check remains source-pending rather than falsely current.

Package commands are launched directly with POSIX spawn; no shell command or remote recipe is evaluated. Homebrew formula inventory is limited to `installed_on_request`, npm uses global depth zero, and pip uses `--not-required`. Known nvm/mise/asdf/pyenv/Conda roots and active Python environments are examined with bounded directory listing and manager commands; npm roots and Python prefixes are deduplicated before inventory. Each package identity includes its manager and executable path so separate Node/Python environments do not collide. pipx JSON and uv's persistent-tool listing require a live virtual-environment interpreter; Cargo's installed-crate listing requires a live executable in its install root. These three sources establish owner and installed version, not a current upstream version: their update status remains source-pending rather than falsely Up to Date. Ephemeral uvx environments are excluded. Docker and other environment types are planned, not yet scanned.

Hermes Desktop and Hermes Agent are independent update targets. A source Agent is inventoried only when its launcher and target executable are live and its Git checkout exposes a validated commit ID; a main-branch checkout uses GitHub's public commit-compare API to distinguish identical, ahead, and divergent histories. Non-main or detached checkouts remain source-pending. The desktop bundle's `0.0.0`/`0.0.1` bootstrap version is never compared with Agent release names. Packaged desktop builds have a known Squirrel.Mac mechanism but no verified public desktop feed, so their availability stays pending. No Git command or discovered Hermes executable is run during discovery.

Android Studio's `CFBundleShortVersionString` can omit the third component of its release name (for example, `2026.2` versus `2026.2.1`). The scanner reads the complete version from the app-bundled `product-info.json` directory selector and requires that it agree with the bundle's short version. The official English stable-release page is the primary version source. Homebrew Cask is a fallback only: its fourth numeric component denotes a package/patch revision not safely comparable with the IDE's three-part release family. A same-family patch, missing bundle metadata, preview channel or lagging cask yields source-pending instead of a false update claim.

The fixed official catalog is refreshed at launch, before each full scan, and through `freshSnapshotBeforeUpdate()` before any future installation decision. An app-owned timer independently checks its HTTPS URL every six hours while the process is open, including menu-bar-only operation; accepted new revisions cause one inventory scan using the cached catalog. Catalog cache metadata is bound to the source URL so an app update that moves hosts cannot inherit another publisher's rules.

Scans and the CLI detect ownership and update state without installing. Eligible Sparkle, scoped Homebrew and Microsoft AutoUpdate targets have separate explicit GUI confirmation and verification flows; general-purpose installers remain deferred.

Update Atlas itself is built only for Apple silicon (`arm64`) and keeps macOS 14 as its deployment target. Inventory detection remains architecture-neutral: Intel applications and `/usr/local` package-manager environments on an Apple silicon Mac are still eligible for scanning. Dedicated evidence for an Intel command-line provider that cannot run because Rosetta is unavailable is tracked as follow-up work in the project plan.

## Localization

User-facing app copy is sourced from `Localizable.xcstrings` for English, Turkish, Russian, German, French, Simplified Chinese and Japanese. SwiftUI views receive the selected locale; model titles, AppKit alerts and menu strings use `String(localized:)` with both the selected locale and its explicit `.lproj` bundle. A source-language resource directory lets an app launched in another language switch back to English immediately. The static catalog check also examines localized view-helper arguments and rejects computed strings without a selected bundle/locale. Application names, bundle identifiers, package identifiers, vendor-provided channel names and machine-readable CLI/MCP protocol fields remain untouched. Detection and catalog matching depend on technical identity, never translated display names.

## Release channels

Every inventory item has a normalized release channel: Stable, LTS, RC, Beta, Alpha, Canary, Nightly, or a vendor-defined custom channel. Detection prefers explicit catalog/updater metadata, then bundle identity and version suffixes. Version providers return their candidate channel alongside the version, and compatibility is checked before version comparison is shown to the user.

Stable installations accept Stable candidates only by default. A Settings opt-in can also admit prerelease candidates, while LTS and prerelease installations remain pinned to their own channel. Sparkle feeds, GitHub releases, catalog providers, and known manager adapters all pass through the same policy. Compact badges expose the detected and candidate channels in the list and inspector.

## Native presentation

Navigation identity, inspector identity, scanning state, and primary actions use the macOS Liquid Glass APIs on macOS 26 and later. Availability-gated view modifiers preserve the macOS 14 deployment target with native material and bordered-button fallbacks. Dense inventory rows remain visually quiet so glass expresses hierarchy rather than decorating every surface.

## Managed components

An installed product and the content it manages are separate inventory records. The child keeps the manager bundle identifier, but it may have its own version provider. This allows Update Atlas to report an outdated VS Code extension or ComfyUI core even while the parent application itself is current. The manager remains responsible for installation.

VS Code extensions are read from the local extension registry and checked against the Marketplace for the installed stable/pre-release channel, target platform, and VS Code engine compatibility. JetBrains plugins use the same parent-child model, but their provider must additionally bind the plugin XML ID to the IDE product code and full build number. Game launchers and emulator frontends follow this model as well; no child is marked current unless the owning manager exposes a reliable local pending/current state.

App Store ownership is detected from either a native macOS receipt or an iOS-on-macOS wrapper. Wrapped bundles are read through `WrappedBundle/Info.plist`, and their item ID/storefront are read from `Wrapper/iTunesMetadata.plist` before the Apple lookup provider is selected.

## Scan reliability and shared result policy

Discovery and checking share a monotonic deadline/cancellation token. Package commands run with argv (no shell recipes), a separate process group, bounded nonblocking output and TERM/KILL cleanup. Failed starts, timeout, non-accepted exit status and malformed response produce path-free source diagnostics instead of an implied empty inventory. GUI cancellation/overall timeout preserves previous results and timestamps; completed partial scans expose their issues and do not advance the support reminder counter. Update-source checks have bounded concurrency and deadline cancellation.

GUI and CLI derive coverage from canonical actual result statuses: only current/newer version evidence counts verified; manager-owned, pending, failed and unchecked items remain unverified. CLI includes coverage and discovery diagnostics independently of output filters. Prerelease policy is snapshotted for each check; CLI explicitly supplies the GUI preference suite value.

The app and CLI do not generate catalog-coverage reports from a user's inventory. CLI `scan` and `check` remain local JSON interfaces for users' own automation; they have no submission path.

## Periodic checks and native local notifications

The app-owned ViewModel owns a BackgroundCheckService independently of SwiftUI window tasks.
It uses a common-mode AppKit timer with tolerance and a persisted last-attempt timestamp. Defaults
are opt-in/off and six hours; available intervals are 1/6/12/24 hours. Successful manual/launch
scans reset the anchor. Scheduled failures still wait an interval rather than spinning. Workspace
sleep pauses the timer and cancels only the scheduled task; wake performs at most one overdue
check, retrying a sleep-interrupted scan. Onboarding, scan and direct-installer guards prevent
unrequested/concurrent work. Clock rollback/corrupt interval values recover to a valid schedule.

The official catalog has its own app-owned six-hour timer, independent of opt-in inventory
checks. Launch and full scans refresh the fixed `alperenalan.com` HTTPS source; users cannot
change or disable its URL. Catalog matching controls rule application, not catalog checks.
No launch agent, login item or wake assertion is created.

Completed-scan sequence numbers gate side effects; cancellation/partial-scan warnings never emit
new-update notifications. Scheduled scans skip the existing tip-counter path. Notification delivery
is opt-in and authorization is queried without prompting during scans. An explicit Settings action
alone requests permission. The main-actor service serializes/coalesces delivery across overlapping
scans, uses generation guards after awaits and ignores late results when disabled. Version/channel
fingerprints are recorded only after native request acceptance, with failed sends retryable. IDs and
fingerprints are hashed and local to UserDefaults; native userInfo includes at most one opaque ID.
One notification aggregates the newly confirmed items; digest clicks open expanded update results,
and a single-item click opens its inspector. Cold-launch clicks buffer until the window/scan exists.
Native banners and optional sound remain subject to the user's macOS notification settings.

CLI discovery/check data is unchanged; it already exposes the confirmed availability/latest version,
release channel and opaque identity used here. UI-owned scheduling/authorization does not add CLI
watch mode or remote reporting. No push notification entitlement or backend is required.


### CLI bundle resources and installed links

`BundledAppResources` resolves the executable URL's symbolic links before locating its containing
`Contents/MacOS[/Helpers]` app bundle. The CLI uses this same resolver for version metadata, and
RemoteCatalogService uses it for BootstrapCatalog. It does not search the cwd or
adopt an adjacent arbitrary catalog. GUI resource lookup remains supported. A local catalog
snapshot is validated before CLI package discovery starts; revision zero remains a code-3 error,
not an empty successful inventory. The CLI scan/check JSON schema does not change.

## Explicit manager actions

`ManagerUpdatePolicy` is shared with the CLI and supplies only compiled action codes/commands.
The catalog contains no executable recipe. `DirectUpdateService` serializes native confirmation,
App Store routing and off-main-actor manager work. `ManagerUpdateExecutor` accepts injected
command/identity/version readers for hermetic tests; production uses the bounded POSIX runner.
Homebrew preflight re-reads exact installed metadata and target ownership, checks Stable/pin/SHA,
and restricts mutation to one explicit operand plus necessary dependencies. MAU uses compiled
Office/OneDrive IDs and verifies both Microsoft-signed bundles in standard locations. Its
configured channel remains unchanged and is disclosed in confirmation. No forced termination,
sudo, pip/uv update executor or background installation is added. Command completion is distinct
from a verified installed version; results trigger a one-item refresh through
`ApplicationRefreshService`. It reads the fresh bundle metadata and, for Homebrew, only the
selected token’s receipt. The view model classifies/checks that single candidate and replaces
its stable-ID row, preserving unrelated results, hierarchy, full-scan time and scheduling. App Store responses must match
the item's bundle identity and provide a validated product link before native routing.

## Additional local discovery

`LocalDiscoveryProvider` emits bundle locations, installed manager candidates and diagnostics;
`ApplicationScanner` retains native bundle metadata/identities, attaches actual parent IDs,
protects existing Homebrew provenance and reconciles canonical paths before classification.
Custom roots have depth/entry limits, cancellation checks and no child-symlink traversal.
Galaxy uses a compiled read-only `InstalledBaseProducts` query; GOG/Epic/Heroic records require
live local payload. Store manifest versions remain separate from native bundle versions.
Setapp and legacy Toolbox roots establish ownership; Adobe folder discovery establishes bundle
presence while the normal classifier decides ownership. Wine bottles require metadata and a
live `drive_c`; arbitrary guest-program enumeration/launching is not part of this adapter.

`DockerDiscoveryProvider` is off by default. It pins commands to the current named context
unless the CLI has an effective `DOCKER_HOST` override, which contributes only a hash to identity.
Bounded read-only `ls` and projected `inspect` templates return image config digest/platform,
container state and exactly the Compose project/service identity keys, plus volume names.
No full label map, environment, mount paths, credentials, image history or registry request is
collected. Images are shared context children; containers reference their immutable image ID,
so a shared image is not duplicated per container. Removed images can remain container
references without a synthetic installed image. A query race/denial/unavailable daemon yields
an explicit source diagnostic. Docker objects have no latest-version provider, release-channel
claim or install action and are excluded from application counts.

`DiscoveryConfiguration` is snapshotted before detached scans; CLI uses the app preference
suite and adds command-only folder/Docker overrides. `DiscoveryFacts` is an additive optional
schema-v1 DTO shared by inspector and CLI, excluding paths and launch arguments.

Source-format references: [Legendary Epic manifest model](https://github.com/derrod/legendary/blob/master/legendary/models/egl.py),
[Heroic GOG install records](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/blob/main/src/backend/storeManagers/gog/games.ts),
[GOG installed-table reader](https://github.com/Shin-Aska/DosboxStagingReplacerForGOGGalaxy/blob/HEAD/services/gog/GogGalaxyService.cpp),
[Whisky bottle registry](https://github.com/Whisky-App/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/Whisky/BottleData.swift),
[JetBrains installation locations](https://blog.jetbrains.com/toolbox-app/2023/08/toolbox-app-2-0-overhauls-installations-and-updates/),
[Docker formatting](https://docs.docker.com/engine/cli/formatting/) and
[Docker container listing](https://docs.docker.com/reference/cli/docker/container/ls/).
