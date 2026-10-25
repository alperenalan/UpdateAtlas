# Localization release gate

The shipped app offers English, Turkish, Russian, German, French, Simplified Chinese and
Japanese. `Localizable.xcstrings` is the app UI catalog; `Web/site_copy.psv` is the
separate product-site source. Counts measure filled entries, not linguistic quality or
complete runtime coverage. Vendor names, product IDs, CLI flags, JSON field names, error
codes and MCP tool names remain stable technical identifiers. The CLI's human-readable help,
progress and errors and the generated Agent Skill stay English by design (developer tooling,
decided 2026-10-25); the gate reports them as notes, not blockers.

## Every text change

1. Add app-owned text to the String Catalog in all six translations, or site text to all
   seven columns in `site_copy.psv`. Use a full message with placeholders rather than
   assembling English fragments. Keep persisted and protocol identifiers unchanged.
2. Run `python3 __Assets__/Scripts/Apple/check_localizations.py` and
   `python3 Web/generate_site.py --check`. The first check catches missing catalog
   translations, leading or trailing spaces, obsolete keys, placeholder differences
   and many uncataloged SwiftUI literals. Its
   source scan is not a substitute for a runtime inventory.
3. Read each changed translation against English for meaning, naturalness, grammar,
   typography, technical terminology and context (C21–C25; C18 for loaded drift).
   Record **every** read, including `ok`, in `translation-reviews.tsv`: item is
   `app:<English catalog key>` or `site:<copy key>`; field is the locale; `hash` and
   `source_hash` are the first 16 SHA-256 hex characters of the exact UTF-8 target
   and English source respectively; reader is `family:model`, such as
   `google:gemini-4-argon-high`, `anthropic:claude-opus-5.5` or `openai:codex`; date is
   ISO date; verdict is `ok`, `fix` or `flag`. A line clears with an `ok` from Google and
   from a second family (Anthropic or OpenAI). Plural forms are separate lines
   (`app:<key>#one`, `#few`, …).
   A corrected target or changed English source needs both reads again. An open
   objection blocks clearance. Never invent or complete another reader's verdict.
   Use the content review categories and record unresolved market/meaning choices
   for the maintainer. Keep Gemini's raw reply in `.temporary_files/content-review/`.
   `review_translation_batch.py export --scope site --locale tr --offset 0 --limit 40
   --brief PATH_TO_CONTENT_CATEGORIES` prepares an exact-text prompt and manifest;
   run its prompt through `agy` in plan/sandbox mode, inspect the JSON reply, then
   `review_translation_batch.py ingest` with `--reply` and `--reader`. The second
   reader reads the same batch and imports only its own verdicts. The importer rejects omitted
   rows and text that changed after export.
   CI runs `check_localization_release.py --scope changed` against
   `pre-review-baseline.json` for every new or changed source/target pair. The
   baseline is a one-time snapshot of the unreviewed pre-gate repository state,
   **not** approval of that content. Its SHA-256 is pinned in the checker. Do not
   refresh it to clear a failed check.
   The full app/site release gates still require both reads on every current pair.
4. Inspect English and Turkish (`QA_LOCALES`, the languages the maintainer reads) with the
   exact signed ZIP: main window, onboarding, Settings, menu/dialogs, notifications, CLI,
   dates/plurals, and layout/accessibility. Check language switching, clipping, dynamic text
   and VoiceOver labels. The other five languages rely on the two-family translation reads.
   `runtime-qa.tsv` records one `pass` per language/surface tied to the full SHA-256 of that
   ZIP, naming who observed it. A failed or unrun surface has no `pass` row.

Before preparing an appcast, run:

```sh
python3 __Assets__/Scripts/Apple/check_localization_release.py --scope app --archive PATH_TO_SIGNED_ZIP
```

`prepare_appcast.py` runs that same gate. Before pushing site changes, run
`python3 Web/generate_site.py --check` and
`python3 __Assets__/Scripts/Apple/check_localization_release.py --scope site`.
The Git-connected `updateatlas-git` Pages project runs both checks and the
tracked-source scan as its build command, and deploys `main` to production automatically
when a push touches `Web/` (watch path `Web/*`; Pages matches `*` recursively). Pushes outside
`Web/` appear in the dashboard as skipped deployments, which is the filter working, not a stuck
queue. Preview deployments are off.

**Current state (2026-10-24):** current source has 776 referenced String Catalog keys with six
filled translations and 63 site copy rows in seven languages. All 441 site cells have
current-text reads from both required families; the site text gate passes. The app
catalog has 1,084/4,656 current-text clearances. A signed Build35 QA ZIP was opened in
seven languages; this was an existing-user main-window inspection, so no clean-user,
all-surface archive-bound native QA pass is recorded. Bundled CLI
human copy and the generated skill guide are English-only. The app localization
release check therefore still fails.
