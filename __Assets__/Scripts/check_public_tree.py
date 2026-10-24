#!/usr/bin/env python3
"""Reject obvious private material in the tracked tree before a public push.

This does not certify Git history, binary media rights, or privacy. Those require
separate review before the repository visibility is changed.
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PRIVATE_NAMES = re.compile(r"(^|/)(\.env(?:\..+)?|Secrets\.xcconfig|[^/]*\.p8|[^/]*\.mobileprovision|[^/]*\.keystore|[^/]*\.jks|[^/]*credentials[^/]*\.sh)$", re.I)
PRIVATE_FOLDERS = ("__Assets__/Design/", "__Assets__/Contentgen/Catalog/private/", ".temporary_files/", "__Builds__/", "__MACOSX/")
CONTENT_PATTERNS = {
    "private key block": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "GitHub token": re.compile(rb"(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    "AWS access key": re.compile(rb"AKIA[0-9A-Z]{16}"),
    "personal home path": re.compile(rb"/Users/" + rb"alperenalan/"),
}


def findings(root=ROOT):
    tracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).split(b"\0")
    problems = []
    for raw in tracked:
        if not raw:
            continue
        name = raw.decode("utf-8", "surrogateescape")
        if PRIVATE_NAMES.search(name) and not name.endswith(".example.sh") and name != ".env.example":
            problems.append((name, "private filename"))
        if name.startswith(PRIVATE_FOLDERS):
            problems.append((name, "private/scratch folder"))
        path = root / name
        if path.is_symlink():
            problems.append((name, "tracked symbolic link needs manual review"))
            continue
        if not path.is_file() or path.stat().st_size > 2_000_000:
            continue  # Binary and large files need a separate manual inspection.
        content = path.read_bytes()
        if b"\0" in content:
            continue
        for label, pattern in CONTENT_PATTERNS.items():
            if pattern.search(content):
                problems.append((name, label))
    return sorted(set(problems))


def history_findings(root=ROOT):
    """Inspect added/removed text in reachable Git commits without echoing content."""
    command = ["git", "-C", str(root), "log", "--all", "--no-ext-diff", "-p", "--format=COMMIT:%H"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    problems = set()
    commit = "unknown"
    path = "unknown"
    assert process.stdout is not None
    for line in process.stdout:
        if line.startswith(b"COMMIT:"):
            commit = line[7:].strip().decode("ascii", "replace")[:12]
        elif line.startswith(b"diff --git a/"):
            path = line[13:].split(b" b/", 1)[0].decode("utf-8", "replace")
        elif line[:1] in (b"+", b"-") and not line.startswith((b"+++", b"---")):
            for label, pattern in CONTENT_PATTERNS.items():
                if pattern.search(line[1:]):
                    problems.add((commit, path, label))
    if process.wait() != 0:
        raise subprocess.CalledProcessError(process.returncode, command)
    return sorted(problems)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="also scan reachable text diffs in Git history")
    args = parser.parse_args()
    try:
        problems = findings()
        history = history_findings() if args.history else []
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Public-tree check could not run: {type(error).__name__}", file=sys.stderr)
        return 1
    for name, label in problems:
        print(f"{name}: {label}", file=sys.stderr)  # Never print matched bytes.
    for commit, name, label in history[:30]:
        print(f"history {commit} {name}: {label}", file=sys.stderr)
    if len(history) > 30:
        print(f"... {len(history) - 30} more historical candidate exposures", file=sys.stderr)
    if problems or history:
        print(f"Public-source check found {len(problems)} current and {len(history)} historical candidate exposures", file=sys.stderr)
        return 1
    print("Public-source high-signal pattern check passed; binary/media and manual rights review remain required")
    return 0


if __name__ == "__main__":
    sys.exit(main())
