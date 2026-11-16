#!/bin/sh
# Back up private maintainer sources after the Jira/Confluence cutover.
# This never stages the public repository or publishes a build/site.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NOTES_GIT="$ROOT/.internal-notes.git"
REMOTE="https://github.com/alperenalan/UpdateAtlas-archive.git"
BRANCH="internal-notes"
notes() { git --git-dir="$NOTES_GIT" --work-tree="$ROOT" "$@"; }
[ "$(gh repo view alperenalan/UpdateAtlas-archive --json isPrivate --jq .isPrivate)" = true ] || {
  echo "Backup refused: destination is not verified private." >&2; exit 1;
}
[ -d "$NOTES_GIT" ] && [ -f "$ROOT/__Assets__/Archive/Management/migration-2026-11-16.json" ] || {
  echo "Backup refused: restore private Git metadata and archive first; see Confluence." >&2; exit 1;
}

[ "$(notes remote get-url origin)" = "$REMOTE" ] || {
  echo "Backup refused: unexpected private-notes remote." >&2; exit 1;
}
notes fetch -q origin "$BRANCH"
notes merge-base --is-ancestor "origin/$BRANCH" HEAD || {
  echo "Backup refused: remote has changes; reconcile without overwriting." >&2; exit 1;
}
for path in __Assets__/Archive/Management __Assets__/Archive/History __Assets__/Archive/QA \
            __Assets__/Docs/Publishing.md __Assets__/Docs/Self-Maintenance.md .doclinks-ignore; do
  if [ -e "$ROOT/$path" ]; then
    notes add -f -- "$path"
  elif notes ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    notes add -u -- "$path"
  fi
done
for path in PROJECT_PLAN.md PROJECT_DESIGN.md PROJECT_HANDOFF.md PROJECT_MARKET_RESEARCH.md \
            PROJECT_STRUCTURE_AND_FILES.md __Assets__/Docs/History __Assets__/Docs/plans \
            __Assets__/Docs/qa __Assets__/Docs/Backlog.md __Assets__/Docs/design-qa.md \
            __Assets__/Docs/design-qa-build15.md; do
  if notes ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    [ ! -e "$ROOT/$path" ] || {
      echo "Backup refused: obsolete management source is active: $path" >&2; exit 1;
    }
    notes add -u -- "$path"
  fi
done
if notes diff --cached | LC_ALL=C grep -qE 'BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|sk-[A-Za-z0-9]{24}|AKIA[0-9A-Z]{16}|xox[bp]-'; then
  echo "Backup refused: potential key material in staged notes." >&2; exit 1
fi
if ! notes diff --cached --quiet; then
  message="ATLAS-3: Preserve private originals after Jira and Confluence cutover"
  if [ "$#" -gt 0 ]; then message="$1"; fi
  notes commit -q -m "$message"
fi
notes push -q origin "HEAD:refs/heads/$BRANCH"
echo "Private maintainer backup pushed: $(notes rev-parse --short HEAD)"
