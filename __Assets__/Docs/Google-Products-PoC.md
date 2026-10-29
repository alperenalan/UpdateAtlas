# Google apps and CLIs: local proof of concept (2026-10-30)

The five probes in `Apple/Proofs/` are separate read-only entry points. They inspect local
installation metadata. The app probes request current Homebrew Cask JSON, and the CLI probes
request the public npm or cask version. This chat's shell could not resolve external hosts, so
the probes reported `source_error`; the source versions below were checked through the linked
public endpoints. No probe installs or updates a product. The `agy` probe runs `agy --version`
only with `--execute-version`.

| Product | Local evidence | Source and Update Atlas behavior |
| --- | --- | --- |
| Gemini Mac app | `/Applications/Gemini.app`, `com.google.GeminiMacOS`, 1.135.1.1291 | [Cask `google-gemini`](https://formulae.brew.sh/api/cask/google-gemini.json) 1.135.1.1291. Bundled catalog revision 15 identifies it as an independent app. Google documents an in-app Check for Updates command; Update Atlas reads version state and does not trigger that command. |
| Antigravity App | `/Applications/Antigravity.app`, `com.google.antigravity`, 2.28.2 | [Cask `antigravity`](https://formulae.brew.sh/api/cask/antigravity.json) 2.28.2 as checked on 2026-10-30. Its existing catalog identity is retained. Update Atlas does not trigger its updater. |
| Antigravity IDE | Not found in `/Applications` or the user's Applications folder | [Cask `antigravity-ide`](https://formulae.brew.sh/api/cask/antigravity-ide.json) 2.6.0 identifies `Antigravity IDE.app` and `com.google.antigravity-ide`. A separate catalog rule will match it when installed. [Google says](https://antigravity.google/docs/getting-started) the IDE downloads updates and prompts Restart to Update. `agy-ide` is the IDE's alias, not the standalone `agy` installation. Actual local IDE update behavior remains untested. |
| Gemini CLI | No `gemini` command or global `@google/gemini-cli` package in the active npm root | When globally installed with npm, the existing npm package scanner represents `@google/gemini-cli` as an independent CLI row and reads npm's `latest` result. [Google's FAQ](https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/faq.md) gives the npm update command. Update Atlas does not execute it. Other installation methods require their own manager evidence. |
| Antigravity CLI (`agy`) | `~/.local/bin/agy` exists; `agy --version` returned 1.4.9 in the standalone PoC | [Cask `antigravity-cli`](https://formulae.brew.sh/api/cask/antigravity-cli.json) tracks 1.4.10. The standalone binary is not established as Homebrew owned. Its local updater status file has no version, and strict code-signature verification failed. The product scanner does not execute the binary, so it reports installed version Unknown and source pending. The 1.4.10 comparison is a PoC observation, not an Update Atlas update claim. |

The three app rules are distinct bundle IDs. Their cask providers only compare versions; the
application's updater keeps install ownership. If a cask reports a version older than an installed
Google app, Update Atlas now shows source pending instead of Up to Date. This also protects against
short cask publication delays. The remote production catalog remains revision 14; revision 15 is
bundled into the local Build 41 candidate only.

All three installed Google artifacts checked here (Gemini app, Antigravity app and `agy`) returned
`invalid signature` under `codesign --verify --strict`. Their bundle identifiers and versions were
read from local files, but the strict signature result needs investigation before treating those
installations as trusted for automated actions. This iteration adds no such action.

Further proof before a release: run these probes with network access, check an actual installed
Antigravity IDE, verify signatures outside this shell environment, and have the new status text
reviewed in all supported app languages. The local Release Build 41 app contains catalog revision
15 with 366 entries. Its offline CLI scan found Gemini 1.135.1.1291 and Antigravity 2.28.2 as
separate `supported`/`externalManager` rows with `notChecked` update state; it found standalone
Antigravity CLI as `needsCatalog`/`sourcePending` with installed version `Unknown`. The scan exit
was 5 because other environments were only partially inspected. No Antigravity IDE or Gemini CLI
row appeared. This does not substitute for a live updater click or installation test.
