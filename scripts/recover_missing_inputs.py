#!/usr/bin/env python3
"""Reconstruct the missing receipt inputs from a source database.

Why this file exists
--------------------
The canonical base (``home_shopper-db``, Compose) shipped empty, while the
ad-hoc base ``home_shopper`` (container ``postgres``) held the 15 loaded notes. Of
the 15 receipt JSON inputs the original loader consumed, only 11 survived
(the <internal> destroyed the rest). Decision D1=(A)+D2=(c) in
``docs/decisions/2026-10-05-canonical-database.md`` chose to rebuild the 4
missing inputs *from* ``home_shopper`` rather than keep hunting for the lost files.

This script is that reconstruction: it reads the notes already loaded in a
source database and serialises, in the format the versioned loader
(``scripts/load_receipts.py``) reads, only the notes that are **not already
covered** by the inputs on disk. Merged with the preserved inputs it yields
the complete input set, and the documented path (schema + loader) reproduces
all 15 notes / 573 lines.

Matching, so the reconstruction never duplicates a note that already has a
preserved input:
  * a note with a 44-digit ``access_key`` is covered when that key is present
    in any input JSON;
  * a note without a key is covered when an input JSON has the same
    ``(issuer_cnpj, purchase_date)`` pair.

Where the wording of a line is read from depends on the schema of the source
database, and the tool picks the right one at run time:

  * pre-005 schema (the ad-hoc base ``home_shopper``, the historical source):
    ``presentations`` still carried ``description_raw`` and ``sale_unit``
    verbatim. The item query reaches them through the row itself
    (``to_jsonb(pr)``), so it never *names* a column the current schema dropped.
  * form/mapping schema (``db/005_presentations_form_model.sql``, the canonical
    base): the wording lives in ``presentation_sources``, one row per
    (store, wording). The item query reads it from there, scoped to the store of
    the note. A form carrying more than one wording in the SAME store is a
    degraded case: the oldest mapping wins and the caller must review what came
    back -- the reconstruction is an approximation of the line wording, not a
    copy of it.

Usage (source = the ad-hoc base, inputs = the preserved audit dir)
------------------------------------------------------------------
    python3 scripts/recover_missing_inputs.py \\
        --have-dir  <evidence>/<private> \\
        --out-dir   <evidence>/<private> \\
        --source-container postgres --source-user home_shopper --source-db home_shopper

The output carries real access keys (personal data): ``--out-dir`` must be
outside the repository. Nothing is written by default -- pass ``--write``.

Exit codes: 0 ok, 2 input/source error.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from typing import Any

# The wording of a line lives in `presentations` on the pre-005 schema and in
# `presentation_sources` on the form/mapping schema. Two queries, chosen at run
# time by probing `to_regclass`; neither names a column that the schema it
# targets does not have.
ITEM_JSON_LEGACY = """
SELECT coalesce(json_agg(item ORDER BY item->>'line_no'), '[]'::json)
FROM (
    SELECT json_build_object(
               'line_no',       li.line_no,
               'description_raw', to_jsonb(pr)->>'description_raw',
               'sale_unit',     to_jsonb(pr)->>'sale_unit',
               'quantity',      trim_scale(li.quantity)::text,
               'unit_price',    trim_scale(li.unit_price)::text,
               'line_total',    trim_scale(li.line_total)::text
           ) AS item
    FROM line_items li
    JOIN presentations pr ON pr.id = li.presentation_id
    WHERE li.note_id = %(note_id)s
) t
"""

ITEM_JSON_FORM_MODEL = """
SELECT coalesce(json_agg(item ORDER BY item->>'line_no'), '[]'::json)
FROM (
    SELECT json_build_object(
               'line_no',       li.line_no,
               'description_raw', ps.description_raw,
               'sale_unit',     ps.sale_unit,
               'quantity',      trim_scale(li.quantity)::text,
               'unit_price',    trim_scale(li.unit_price)::text,
               'line_total',    trim_scale(li.line_total)::text
           ) AS item
    FROM line_items li
    JOIN purchase_notes pn ON pn.id = li.note_id
    LEFT JOIN LATERAL (
        SELECT s.description_raw, s.sale_unit
          FROM presentation_sources s
         WHERE s.presentation_id = li.presentation_id
           AND s.store_id = pn.store_id
         ORDER BY s.created_at, s.id
         LIMIT 1
    ) ps ON true
    WHERE li.note_id = %(note_id)s
) t
"""

NOTES_SQL = """
SELECT json_agg(n ORDER BY n->>'purchase_date')
FROM (
    SELECT json_build_object(
               'note_id',      pn.id,
               'access_key',   nullif(trim(pn.access_key), ''),
               'issuer_cnpj',  s.cnpj,
               'issuer_name',  s.name,
               'purchase_date', to_char(pn.purchase_date, 'YYYY-MM-DD'),
               'amount_paid',  pn.amount_paid::text,
               'lines',        (SELECT count(*) FROM line_items li WHERE li.note_id = pn.id)
           ) AS n
    FROM purchase_notes pn
    JOIN stores s ON s.id = pn.store_id
) t
"""


def only_digits(value) -> str:
    return re.sub(r"\D", "", str(value or ""))


def psql_json(container: str, user: str, db: str, sql: str) -> Any:
    """Run ``sql`` (returning one JSON value) with psql and parse the result."""
    cmd = [
        "docker", "exec", container,
        "psql", "-U", user, "-d", db, "-At", "--no-psqlrc", "-v", "ON_ERROR_STOP=1",
        "-c", " ".join(sql.split()),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"psql failed: {proc.stderr.strip()}")
    payload = proc.stdout.strip() or "null"
    return json.loads(payload)


def uses_form_model(container: str, user: str, db: str) -> bool:
    """True when the source database carries the form/mapping schema (db/005)."""
    return bool(psql_json(
        container, user, db,
        "SELECT to_json(to_regclass('public.presentation_sources') IS NOT NULL)"))


def covered_keys(have_dir: str) -> tuple[set[str], set[tuple[str, str]]]:
    """Access keys and (cnpj, date) pairs already present in the inputs."""
    keys: set[str] = set()
    keyless: set[tuple[str, str]] = set()
    for path in glob.glob(os.path.join(have_dir, "**", "*.json"), recursive=True):
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        for note in payload if isinstance(payload, list) else [payload]:
            key = only_digits(note.get("access_key") or note.get("source_ref"))
            cnpj = only_digits(note.get("issuer_cnpj"))
            date = note.get("purchase_date") or note.get("emission")
            if len(key) == 44:
                keys.add(key)
            elif cnpj and date:
                keyless.add((cnpj, str(date)))
    return keys, keyless


def slug(text: str) -> str:
    text = re.sub(r"[^a-z0-9]+", "_", str(text).lower()).strip("_")
    return text or "note"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Reconstruct the missing receipt inputs from a source database.")
    parser.add_argument("--have-dir", required=True,
                        help="directory holding the inputs already on disk")
    parser.add_argument("--out-dir", required=True,
                        help="directory to write the recovered inputs into")
    parser.add_argument("--source-container", default="postgres")
    parser.add_argument("--source-user", default="home_shopper")
    parser.add_argument("--source-db", default="home_shopper")
    parser.add_argument("--write", action="store_true",
                        help="actually write the files (default: print plan only)")
    args = parser.parse_args()

    if not os.path.isdir(args.have_dir):
        print(f"error: have-dir not found: {args.have_dir}", file=sys.stderr)
        return 2

    keys, keyless = covered_keys(args.have_dir)
    print(f"# inputs on disk: {len(keys)} keyed + {len(keyless)} keyless note(s)",
          file=sys.stderr)

    notes = psql_json(args.source_container, args.source_user, args.source_db, NOTES_SQL) or []
    if not notes:
        print("error: source database has no purchase_notes", file=sys.stderr)
        return 2

    missing = []
    for note in notes:
        key = only_digits(note.get("access_key"))
        cnpj = only_digits(note.get("issuer_cnpj"))
        pair = (cnpj, str(note.get("purchase_date")))
        if len(key) == 44:
            if key not in keys:
                missing.append(note)
        elif pair not in keyless:
            missing.append(note)

    print(f"# source notes: {len(notes)}; missing from inputs: {len(missing)}",
          file=sys.stderr)

    form_model = uses_form_model(args.source_container, args.source_user, args.source_db)
    item_sql = ITEM_JSON_FORM_MODEL if form_model else ITEM_JSON_LEGACY
    print(f"# source schema: {'form/mapping (db/005)' if form_model else 'legacy presentations'}",
          file=sys.stderr)

    if args.write and missing:
        os.makedirs(args.out_dir, exist_ok=True)

    total_lines = 0
    for note in missing:
        items = psql_json(args.source_container, args.source_user, args.source_db,
                          item_sql.replace("%(note_id)s", f"'{note['note_id']}'::uuid"))
        total_lines += len(items)
        payload = {
            "access_key": note.get("access_key"),
            "issuer_cnpj": note.get("issuer_cnpj"),
            "issuer_name": note.get("issuer_name"),
            "receipt_label": f"recovered_{note['purchase_date']}_{slug(note['issuer_name'])}",
            "purchase_date": note.get("purchase_date"),
            "amount_paid": note.get("amount_paid"),
            "items": items,
        }
        label = payload["receipt_label"]
        print(f"#   {note['purchase_date']} {note['issuer_name']}: {len(items)} lines",
              file=sys.stderr)
        if args.write:
            name = f"{slug(label)}.json"
            target = os.path.join(args.out_dir, name)
            with open(target, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            os.chmod(target, 0o600)
            print(f"#   wrote {target}", file=sys.stderr)

    print(f"# recovered notes: {len(missing)}; recovered lines: {total_lines}",
          file=sys.stderr)
    if not args.write:
        print("# dry run: nothing written (pass --write)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
