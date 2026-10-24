#!/usr/bin/env python3
"""Prepare exact-text review batches and import only complete, explicit reader replies."""
import argparse
import csv
from datetime import date
import json
from pathlib import Path

import check_localization_release as gate


def batch_path(scope, locale, offset, batch_id=None):
    folder = gate.ROOT / ".temporary_files/content-review"
    folder.mkdir(parents=True, exist_ok=True)
    if batch_id is not None and (not batch_id.isalnum() or len(batch_id) > 24):
        raise ValueError("batch id must be short and alphanumeric")
    return folder / f"{scope}-{locale}-{batch_id or f'{offset:04d}'}"


def choose(scope, locale, offset, limit, pending_only, previously_reviewed, selected_pairs=None):
    pending = ({(item, field) for item, field, _ in gate.review_errors(scope)[1]}
               if pending_only else None)
    prior = ({(row["item"], row["field"]) for row in gate.rows(gate.REVIEWS, gate.REVIEW_FIELDS)}
             if previously_reviewed else None)
    selected = sorted((item, field, english, target)
                      for (item, field), (english, target) in gate.translations(scope).items()
                      if (field == locale or locale == "all") and (selected_pairs is None or (item, field) in selected_pairs)
                      and (pending is None or (item, field) in pending)
                      and (prior is None or (item, field) in prior))
    return [{"id": index, "item": item, "field": field, "source": english,
             "target": target, "hash": gate.digest(target.encode()),
             "source_hash": gate.digest(english.encode())}
            for index, (item, field, english, target) in enumerate(selected[offset:offset + limit])]


def export(args):
    selected_pairs = None
    if args.items_file:
        entries = json.loads(Path(args.items_file).read_text(encoding="utf-8"))
        selected_pairs = {(entry["item"], entry["field"]) for entry in entries}
        if not selected_pairs or len(selected_pairs) != len(entries):
            raise ValueError("Selection must contain distinct item/field pairs")
    items = choose(args.scope, args.locale, args.offset, args.limit,
                   args.pending_only, args.previously_reviewed, selected_pairs)
    if selected_pairs is not None and {(item["item"], item["field"]) for item in items} != selected_pairs:
        raise ValueError("Selection includes unavailable or filtered item/field pairs")
    if not items:
        raise ValueError("No items in this batch")
    base = batch_path(args.scope, args.locale, args.offset, args.batch_id)
    (base.with_suffix(".json")).write_text(json.dumps(items, ensure_ascii=False, indent=2) + "\n")
    brief = Path(args.brief).read_text(encoding="utf-8")
    prompt = ("You are an independent language and content reviewer. Do not use tools or read project files. "
              "Read EVERY target against its English source and context. Judge meaning, naturalness, "
              "grammar, typography and the full categories below. Do not wave through a wrong line. "
              "Return ONLY one JSON object with a reviews array. Each input id must occur exactly once. "
              "Each review has id (integer), verdict (ok, fix or flag), note (empty for ok; for fix "
              "start with the category and give the entire corrected target; for flag explain the issue). "
              "Include an integer BATCH property inside the JSON object equal to the item count. "
              "Never claim to have reviewed an omitted item.\n\n"
              + brief + "\n\nINPUT ITEMS:\n" + json.dumps(items, ensure_ascii=False, indent=2))
    (base.with_suffix(".prompt.md")).write_text(prompt, encoding="utf-8")
    print(f"{len(items)} items: {base.with_suffix('.prompt.md')}")


def ingest(args):
    base = batch_path(args.scope, args.locale, args.offset, args.batch_id)
    items = json.loads(base.with_suffix(".json").read_text(encoding="utf-8"))
    raw = Path(args.reply).read_text(encoding="utf-8").strip()
    if raw.startswith("```json") and raw.endswith("```"):
        raw = raw[7:-3].strip()
    reply = json.loads(raw)
    reviews = reply["reviews"]
    if reply.get("BATCH", reply.get("batch_count")) != len(items) or len(reviews) != len(items):
        raise ValueError("Reader reply missing items or BATCH count")
    by_id = {}
    for review in reviews:
        identifier = review["id"]
        if identifier in by_id or identifier not in range(len(items)):
            raise ValueError("Duplicate or unexpected id in reader reply")
        if review["verdict"] not in ("ok", "fix", "flag"):
            raise ValueError("Invalid verdict")
        if review["verdict"] != "ok" and not review["note"].strip():
            raise ValueError("Objection without note")
        by_id[identifier] = review
    current = gate.translations(args.scope)
    retained = []
    for item in items:
        key = (item["item"], item["field"])
        if key not in current and args.skip_removed:
            continue
        english, target = current[key]
        if gate.digest(english.encode()) != item["source_hash"] or gate.digest(target.encode()) != item["hash"]:
            raise ValueError(f"Text changed since export: {item['item']}")
        retained.append(item)
    with gate.REVIEWS.open("a", newline="", encoding="utf-8") as output:
        writer = csv.writer(output, delimiter="\t", lineterminator="\n")
        for item in retained:
            review = by_id[item["id"]]
            writer.writerow([item["item"], item["field"], item["hash"], item["source_hash"],
                             args.reader, date.today().isoformat(), review["verdict"],
                             review["note"].replace("\t", " ").replace("\n", " ")])
    print(f"Recorded {len(retained)} explicit {args.reader} verdicts; {len(items) - len(retained)} removed items skipped")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("export", "ingest"))
    parser.add_argument("--scope", choices=("app", "site"), required=True)
    parser.add_argument("--locale", required=True)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--batch-id", help="unique name for a correction pass")
    parser.add_argument("--limit", type=int, default=40)
    parser.add_argument("--pending-only", action="store_true", help="export current text needing reader approval")
    parser.add_argument("--previously-reviewed", action="store_true", help="limit correction pass to earlier reviewed items")
    parser.add_argument("--brief", help="reviewer instructions for export")
    parser.add_argument("--items-file", help="JSON array of exact item/field pairs for export")
    parser.add_argument("--skip-removed", action="store_true", help="ingest reviewed current items after source keys were deleted")
    parser.add_argument("--reply", help="raw JSON reply for ingest")
    parser.add_argument("--reader", help="family:name for ingest")
    args = parser.parse_args()
    if args.action == "export":
        if not args.brief:
            parser.error("export requires --brief")
        export(args)
    else:
        if not args.reply or not args.reader or args.reader.split(":", 1)[0] not in ("openai", "google", "anthropic"):
            parser.error("ingest requires --reply and --reader openai:name, anthropic:name or google:name")
        ingest(args)


if __name__ == "__main__":
    main()
