# CLI contract — schema 1

The bundled `update-atlas` helper resolves its containing app through symlinks. Installed Build
28 predates this contract; new source requires a separately authorized signed app replacement.
The CLI never installs software. Help/version are text; operational commands emit one JSON
object on stdout. Progress, confirmation hashes and human errors use stderr. Fields are additive;
ignore unknown fields. Breaking changes require a new schemaVersion.

The first release exposes `scan`, `check`, `settings`, `catalog` and `skill`. The `skill`
command prints an Agent Skill guide for using the read-only CLI. MCP remains deferred;
the Release CLI does not expose its server command.

## Inventory

`scan` discovers inventory; package tools may contact registries. `check` additionally refreshes
the fixed official catalog and checks release sources. `--offline` on either command reads local app,
manager and game metadata plus Homebrew receipts and global npm package manifests. It does
not launch configurable package tools, check release sources or refresh catalogs. Other package
environments and Docker emit `offlineSkipped`; coverage is deliberately narrower. No local
receipt proves the latest version. `check --offline` reports `checkPerformed: false`.

Options: `--include-system`, `--include-paths`, `--updates-only`, `--kind KIND`,
`--manager OPAQUE_ID`, `--children-of OPAQUE_ID`, repeatable `--folder ABSOLUTE_PATH`,
`--docker`/`--no-docker`, `--offline`, `--fail-on-updates`, `--progress`/`--no-progress`.
Filters apply after discovery/checking; they do not restrict network scope. Owner IDs must exist.
Paths require explicit inclusion; settings folder inspection intentionally returns saved paths.

Success/partial inventory has `schemaVersion: 1`, `ok: true`, `networkPolicy`, `isPartial`,
`checkPerformed`, `catalogSourceCode` (`bundled`, `cache`, `remote`), catalog metadata,
`items`, canonical/returned `summary`, `coverage` and path-free `scanDiagnostics`.
`isPartial` covers failed discovery/checks, catalog fallback warnings and interrupted scans;
expected offline omissions alone do not mark partial. Source-pending alone is not an error.
JSON is emitted after completion; dynamic progress remains on stderr, not streamed JSON.

## Settings and catalog

```sh
update-atlas settings list
update-atlas settings get menu-bar
update-atlas settings set check-interval-hours 6
update-atlas settings reset notifications
update-atlas settings folders add /absolute/existing/directory
update-atlas settings folders remove /absolute/directory
update-atlas catalog show
update-atlas catalog refresh
update-atlas catalog matching true
update-atlas catalog disable ENTRY_ID
update-atlas catalog enable ENTRY_ID
```

Settings allowlist: `include-system`, `allow-prerelease`, `docker`, `menu-bar`,
`background-checks`, `notifications`, `notification-sound` accept only `true`/`false`;
`check-interval-hours` accepts 1, 6, 12 or 24. Reset removes only that saved preference.
Folders are canonical absolute directories, deduplicated and capped at 16; unrelated settings
and persisted identifiers are preserved. A running GUI may require reopening or its next scan
to observe externally changed preferences. CLI enabling notifications does not grant native
permission or start a background process; enable permission in the GUI.

`catalog show` uses local bundle/cache only. The official catalog source is fixed to
`https://updateatlas.alperenalan.com/api/update-atlas/catalog-v1.json` and cannot be changed by the CLI.
Refresh is explicit network work; failures expose fallback JSON with `ok: false` and code 4.
Individual rules use stable catalogID::entryID
keys; unknown IDs fail before mutation. Catalog JSON returns source, endpoint, matchingEnabled,
disabledRuleKeys, warning and the full catalog. Settings JSON returns schemaVersion, ok, settings.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Complete command; pending/unverified versions may remain |
| 2 | Invalid arguments, values, owner or rule ID |
| 3 | Missing/invalid local catalog or local configuration/encoding failure |
| 4 | Requested remote catalog operation unavailable |
| 5 | Valid inventory with real discovery/check failures or catalog fallback warning |
| 10 | Confirmed updates in otherwise complete inventory, only with `--fail-on-updates` |
| 130 | SIGINT cancellation; inventory preserves available partial results |

Precedence for inventory: cancellation, partial, updates flag, success. An HTTP request already
in flight may finish or time out before cancellation returns. Operational failures have
`{schemaVersion:1,ok:false,error:{code,message,exitCode}}`; automation should use code/exitCode,
not localized messages. Partial inventory is useful JSON, not a failure envelope. Always inspect
the process status; piping to another command requires shell pipefail to preserve it.

Regression fixtures cover preference upgrades, folder deduplication, local receipts, error
encoding and exit precedence in `Apple/UpdateAtlasTests/CLIContractTests.swift`.
