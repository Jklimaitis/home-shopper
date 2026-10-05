#!/usr/bin/env python3
"""Generate the SQL that loads the preserved NFC-e receipts into the database.

Why this file exists
--------------------
The base `home_shopper` (container `postgres`) was populated in 2026-09 by a script
that lived only in the <internal> and was destroyed by the 24h
idle prune. That is the single point of failure this loader removes: the
loading path is now versioned, reviewable and reproducible.

Input  -- a directory of receipt JSON files, in the format preserved under
          `<evidence>/<private>`
          plus the recovered loader's serialisation:
          One file is either a single note object or a list of note objects.
          Note fields used: `access_key` (or the legacy `source_ref`),
          `issuer_cnpj` (formatted or not), `issuer_name`, `receipt_label`,
          `emission` (or the legacy `purchase_date`), `amount_paid`
          (or `amount_payable`), `items[]`.
          Item fields used: `line_no`, `description_raw`, `sale_unit`,
          `quantity`, `unit_price`, `line_total`.

Output -- SQL on stdout, applied with the same client the README documents:

          python3 scripts/load_receipts.py | docker compose exec -T db \\
              psql -U home_shopper -d home_shopper -v ON_ERROR_STOP=1

          Nothing is written to disk by default: the generated SQL carries real
          access keys, which are personal data, so it must not land in the
          repository (scripts/guard_dados_sensiveis.py would flag it).

The load is idempotent: re-running the same input inserts nothing new. Keyed
notes rely on the partial unique index `(user_id, access_key)`; keyless notes
(typed by hand, `access_key IS NULL`) have no such index, so they are guarded
on their natural key `(user_id, store_id, purchase_date, amount_paid)`. The
trusted layer is written directly, mirroring how `home_shopper` was built; the
staging tables belong to the Sprint 1 ingestion pipeline, not to this seed
loader.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import unicodedata
from decimal import Decimal
from pathlib import Path

DEFAULT_SOURCE_DIR = (
    "<evidence>/<private>"
)
DEFAULT_USER_ID = "00000000-0000-0000-0000-000000000001"
DEFAULT_USER_NAME = "Jonas Klimaitis"
DEFAULT_USER_EMAIL = "user@example.com"

# CNPJ (14 digits) -> display name. Taken from the recovered loader so the
# rebuilt base carries the same store names as `home_shopper`.
STORE_MAP = {
    "00000000000002": "Supermarket B",
    "00000000000001": "Supermarket A",
    "00000000000006": "Supermarket F",
    "00000000000003": "Supermarket C",
    "00000000000004": "Supermarket D",
    "00000000000007": "Supermarket G",
    "00000000000005": "Supermarket E",
}


def normalize_text(text: str) -> str:
    """Lowercase, strip accents, collapse whitespace -- `description_norm`."""
    text = unicodedata.normalize("NFD", str(text))
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", text.strip().lower())


def only_digits(value) -> str:
    return re.sub(r"\D", "", str(value or ""))


def infer_base_unit_and_factor(sale_unit: str) -> tuple[str, str]:
    """Smallest comparable unit and the factor of one sale unit in it."""
    su = (sale_unit or "").upper().strip()
    if su == "KG":
        return "G", "1000"
    if su in ("L", "LT"):
        return "ML", "1000"
    return "UN", "1"


def iso_date(note: dict) -> str | None:
    """`purchase_date` (YYYY-MM-DD) or `emission` (DD/MM/YYYY HH:MM:SS)."""
    raw = note.get("purchase_date") or note.get("emission")
    if not raw:
        return None
    raw = str(raw).strip()
    m = re.match(r"^(\d{2})/(\d{2})/(\d{4})", raw)
    if m:
        dd, mm, yyyy = m.groups()
        return f"{yyyy}-{mm}-{dd}"
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})", raw)
    if m:
        return m.group(0)
    return None


def access_key(note: dict) -> str | None:
    """44-digit NFC-e key. The legacy field was `source_ref`."""
    for field in ("access_key", "source_ref"):
        value = only_digits(note.get(field) or "")
        if len(value) == 44:
            return value
    return None


def amount_paid(note: dict) -> str | None:
    value = note.get("amount_paid")
    if value is None:
        value = note.get("amount_payable")
    if value is None:
        return None
    return str(Decimal(str(value)))


def sql_literal(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def load_notes(source_dir: Path) -> list[dict]:
    notes: list[dict] = []
    for path in sorted(glob.glob(os.path.join(str(source_dir), "**", "*.json"), recursive=True)):
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        for note in payload if isinstance(payload, list) else [payload]:
            note = dict(note)
            note["_file"] = os.path.basename(path)
            notes.append(note)
    return notes


def emit(notes: list[dict], args: argparse.Namespace) -> list[str]:
    out: list[str] = []
    if args.transaction:
        out.append("BEGIN;")

    out.append("-- Seed user")
    out.append(
        "INSERT INTO users (id, name, email)\n"
        f"VALUES ({sql_literal(args.user_id)}, {sql_literal(args.user_name)}, "
        f"{sql_literal(args.user_email)})\n"
        "ON CONFLICT (email) DO NOTHING;"
    )

    out.append("-- Stores")
    stores: dict[str, str] = {}
    for note in notes:
        cnpj = only_digits(note.get("issuer_cnpj"))
        if len(cnpj) != 14:
            raise ValueError(f"{note['_file']}: invalid issuer_cnpj {note.get('issuer_cnpj')!r}")
        name = STORE_MAP.get(cnpj) or str(note.get("issuer_name") or "Unknown").strip()
        stores[cnpj] = name
    for cnpj in sorted(stores):
        out.append(
            "INSERT INTO stores (name, cnpj)\n"
            f"VALUES ({sql_literal(stores[cnpj])}, {sql_literal(cnpj)})\n"
            "ON CONFLICT (cnpj) DO UPDATE SET name = EXCLUDED.name;"
        )

    notes_total = lines_total = skipped = 0
    per_store: dict[str, int] = {}
    for note in notes:
        cnpj = only_digits(note.get("issuer_cnpj"))
        key = access_key(note)
        date = iso_date(note)
        paid = amount_paid(note)
        items = note.get("items") or []
        if date is None or paid is None:
            raise ValueError(
                f"{note['_file']} / {note.get('receipt_label')}: missing date or amount_paid"
            )
        if not items:
            skipped += 1
            continue

        notes_total += 1
        lines_total += len(items)
        per_store[stores[cnpj]] = per_store.get(stores[cnpj], 0) + len(items)

        out.append(f"-- Note: {note.get('receipt_label') or note['_file']} ({len(items)} lines)")
        if key is not None:
            # Keyed note: the partial unique index on (user_id, access_key)
            # makes the insert idempotent.
            insert_note = (
                "    INSERT INTO purchase_notes (user_id, store_id, access_key, purchase_date, amount_paid)\n"
                f"    VALUES ({sql_literal(args.user_id)}, v_store_id, {sql_literal(key)}, "
                f"{sql_literal(date)}, {paid})\n"
                "    ON CONFLICT (user_id, access_key) WHERE access_key IS NOT NULL DO NOTHING\n"
                "    RETURNING id INTO v_note_id;\n\n"
            )
            skip_label = key
        else:
            # Keyless note (typed by hand): there is no unique index to lean on,
            # so guard on the natural key explicitly -- otherwise a re-run would
            # insert the same note again and the loader would not be idempotent.
            insert_note = (
                "    IF NOT EXISTS (\n"
                "        SELECT 1 FROM purchase_notes\n"
                f"         WHERE user_id = {sql_literal(args.user_id)}\n"
                "           AND store_id = v_store_id\n"
                f"           AND purchase_date = {sql_literal(date)}\n"
                f"           AND amount_paid = {paid}\n"
                "           AND access_key IS NULL\n"
                "    ) THEN\n"
                "        INSERT INTO purchase_notes (user_id, store_id, access_key, purchase_date, amount_paid)\n"
                f"        VALUES ({sql_literal(args.user_id)}, v_store_id, NULL, "
                f"{sql_literal(date)}, {paid})\n"
                "        RETURNING id INTO v_note_id;\n"
                "    END IF;\n\n"
            )
            skip_label = note.get("receipt_label")
        out.append(
            "DO $$\n"
            "DECLARE\n"
            "    v_note_id UUID;\n"
            "    v_product_id UUID;\n"
            "    v_presentation_id UUID;\n"
            "    v_store_id UUID;\n"
            "BEGIN\n"
            f"    SELECT id INTO v_store_id FROM stores WHERE cnpj = {sql_literal(cnpj)};\n\n"
            + insert_note
            + "    IF v_note_id IS NULL THEN\n"
            f"        RAISE NOTICE 'skip duplicate note: {skip_label}';\n"
            "    ELSE"
        )
        for item in items:
            desc_raw = str(item["description_raw"])
            desc_norm = normalize_text(desc_raw)
            # Store the sale unit exactly as printed (`pc`, `Un`, `Kg`...): the
            # schema check allows 1-4 letters of either case, and `home_shopper`
            # preserved the original casing. Only the base-unit inference is
            # case-insensitive.
            sale_unit_raw = str(item["sale_unit"]).strip()
            base_unit, factor_base = infer_base_unit_and_factor(sale_unit_raw)
            out.append(
                "        INSERT INTO products (name, base_unit)\n"
                f"        VALUES ({sql_literal(desc_norm)}, {sql_literal(base_unit)})\n"
                "        ON CONFLICT (name, brand) WHERE brand IS NULL DO NOTHING;\n\n"
                "        SELECT id INTO v_product_id FROM products\n"
                f"         WHERE name = {sql_literal(desc_norm)} AND brand IS NULL;\n\n"
                "        INSERT INTO presentations (product_id, sale_unit, factor_base,\n"
                "                                   description_raw, description_norm, store_id)\n"
                f"        VALUES (v_product_id, {sql_literal(sale_unit_raw)}, {factor_base},\n"
                f"                {sql_literal(desc_raw)}, {sql_literal(desc_norm)}, v_store_id)\n"
                "        ON CONFLICT (product_id, match_key, store_id) WHERE store_id IS NOT NULL\n"
                "        DO UPDATE SET id = presentations.id\n"
                "        RETURNING id INTO v_presentation_id;\n\n"
                "        INSERT INTO line_items (note_id, product_id, presentation_id, line_no,\n"
                "                                unit_price, quantity, line_total)\n"
                f"        VALUES (v_note_id, v_product_id, v_presentation_id, {int(item['line_no'])},\n"
                f"                {Decimal(str(item['unit_price']))}, {Decimal(str(item['quantity']))}, "
                f"{Decimal(str(item['line_total']))});"
            )
        out.append("    END IF;\nEND $$;")

    if args.transaction:
        out.append("COMMIT;")

    print(
        f"# files={len({n['_file'] for n in notes})} notes={notes_total} "
        f"lines={lines_total} empty_skipped={skipped}",
        file=sys.stderr,
    )
    for name in sorted(per_store):
        print(f"#   {name}: {per_store[name]} lines", file=sys.stderr)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate SQL that loads the preserved NFC-e receipts into the database."
    )
    parser.add_argument("--source-dir", default=DEFAULT_SOURCE_DIR,
                        help="directory holding the receipt JSON files")
    parser.add_argument("--user-id", default=DEFAULT_USER_ID)
    parser.add_argument("--user-name", default=DEFAULT_USER_NAME)
    parser.add_argument("--user-email", default=DEFAULT_USER_EMAIL)
    parser.add_argument("--no-transaction", dest="transaction", action="store_false",
                        help="emit bare statements (no BEGIN/COMMIT)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the summary only, emit no SQL")
    args = parser.parse_args()

    source_dir = Path(args.source_dir)
    if not source_dir.is_dir():
        print(f"error: source dir not found: {source_dir}", file=sys.stderr)
        return 2

    notes = load_notes(source_dir)
    if not notes:
        print(f"error: no receipt JSON found under {source_dir}", file=sys.stderr)
        return 2

    statements = emit(notes, args)
    if not args.dry_run:
        sys.stdout.write("\n\n".join(statements) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
