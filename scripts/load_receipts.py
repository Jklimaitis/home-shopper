#!/usr/bin/env python3
"""Generate the SQL that loads the preserved NFC-e receipts into the database.

Why this file exists
--------------------
The base `home_shopper` (container `postgres`) was populated in 2026-09 by a script
that lived only in the <internal> and was destroyed by the 24h
idle prune. That is the single point of failure this loader removes: the
loading path is now versioned, reviewable and reproducible.

The loader writes the FORM / MAPPING model introduced by
`db/005_presentations_form_model.sql` (internal task, decisions J1-J4):

  * `presentations` is the commercial FORM -- product, factor, recognised sale
    unit, content, container, multipack. It is created or reused by
    `uk_presentations_form` and the conversion factor lives ONLY here.
  * `presentation_sources` is the per-store MAPPING -- the wording and the sale
    unit exactly as the store printed them. It is created or reused by
    `uk_presentation_sources_store_key` = `(store_id, match_key)`.
  * the GTIN lives in `presentation_identifiers` (J2). The loader validates the
    `observed_code` (format, GTIN length, GS1 check digit) and writes only what
    passes -- see "The observed GTIN" below.

Writing to the old model (a `presentations` row carrying `sale_unit`,
`description_raw`, `description_norm`, `store_id` and `ON CONFLICT
(product_id, match_key, store_id)`) is what this rewrite removes: those columns
and that key do not exist any more, so a new load would simply break.

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
          The preserved inputs also carry `observed_code` (the item's barcode as
          printed). It is read and validated -- see "The observed GTIN".

Output -- SQL on stdout, applied with the same client the README documents:

          python3 scripts/load_receipts.py | docker compose exec -T db \\
              psql -U home_shopper -d home_shopper -v ON_ERROR_STOP=1

          Nothing is written to disk by default: the generated SQL carries real
          access keys, which are personal data, so it must not land in the
          repository (scripts/guard_dados_sensiveis.py would flag it).

What the loader writes, per line item
-------------------------------------
1. the PRODUCT (`name` = the derived search text, `brand` NULL). Created if
   absent; `ON CONFLICT ... DO NOTHING` keeps the `base_unit` of the first load.
2. the FORM in `presentations`, created or reused by `uk_presentations_form`.
   `content_kind` / `content_quantity` / `content_unit` stay `UNKNOWN` / NULL:
   the loader does not interpret content (segment 1, decision 1) and Open Food
   Facts may only pre-fill them later, where a valid GTIN exists and a human
   reviews.
3. the MAPPING in `presentation_sources`: `sale_unit` verbatim, `description_raw`
   verbatim, `description_search` the ONE derived search representation
   (Ponto C). Created or reused by `(store_id, match_key)`.
4. the CHARGE in `line_items`.
5. the GTIN, when the line carries a VALID `observed_code`, in
   `presentation_identifiers` -- one row per distinct GTIN (see "The observed
   GTIN").

Sale unit
---------
The raw label is preserved verbatim on the MAPPING. `sale_unit_recognized` is
derived on the FORM from the controlled vocabulary of the enum, case-folded
(ADR-0001 rule 11: `UN`/`un` and `KG`/`kg` are the same unit; case does not
change the unit). A label outside the vocabulary (`BJ`, `Gf`, `Am`, ...) is not
guessed -- it stays NULL and goes to the review funnel.

Multipack (segment 1, decision 4 -- conservative)
-------------------------------------------------
`NxM` is a pack ONLY when the second factor carries a consumption unit
(`2x500g`, `6x1l`); then `multipack_quantity` = N, and `container_type` is
filled only when the description itself states a container word. `c/N` (`C/12`)
and `Nun` (`12UN`) are pack hints the loader cannot confirm: both are left NULL
and go to review. Nothing is inferred by default.

The observed GTIN (J2)
----------------------
`observed_code` is the barcode the receipt prints for the line. It is noisy
(short fragments, emitter store codes), so the loader writes a GTIN ONLY when
the code is a real one:

  * the format the CHECK approves, `^[0-9]{8,14}$`;
  * a length a GTIN actually has -- 8, 12, 13 or 14. A code of 9/10/11 digits
    is not a GTIN no matter which digits it holds;
  * the GS1 mod-10 check digit is correct.

Anything else is rejected -- never padded, completed or guessed -- and the raw
value stays in the private source for audit. Every rejection is counted in the
loader summary by reason: short/malformed, invalid length, wrong check digit.

A valid GTIN is written to `presentation_identifiers`, tied to the form the
line derives. The association is resolved AFTER every form is created, by the
same tuple the line used, so the section loads both on a fresh base and on one
already loaded (where the note insert is skipped). One row per distinct GTIN
(`uk_presentation_identifiers_gtin`); a code observed on several lines yields
one row and the surplus is reported as duplicates. The table has no
`reviewed`/provenance column -- the link is mechanical by construction -- so
the provenance (note label, line number) is carried in the generated SQL
comments rather than in a column that does not exist.

What the loader deliberately does NOT write
-------------------------------------------
* `match_source` / `reviewed` on the mapping. The link the loader derives is
  mechanical, not confirmed by a human: `reviewed` keeps its FALSE default and
  `match_source` stays NULL, exactly as the migration left them.
* the staging layer. The trusted layer is written directly, mirroring how
  `home_shopper` was built; the `staging_*` tables belong to the Sprint 1 ingestion
  pipeline, not to this seed loader.

Idempotency
-----------
Re-running the same input inserts nothing new. Keyed notes rely on the partial
unique index `(user_id, access_key)`; keyless notes (typed by hand,
`access_key IS NULL`) have no such index, so they are guarded on their natural
key `(user_id, store_id, purchase_date, amount_paid)`. Forms and mappings are
created-or-reused by their own keys -- a re-run neither duplicates the form nor
the mapping, and it never silently re-points an existing mapping.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import unicodedata
from collections import Counter
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

# The controlled vocabulary of the `sale_unit_recognized` enum, in the same
# order as the type definition. A label outside this list is not a unit the
# loader can confirm -- it must not become a meaning by spell.
SALE_UNIT_VOCABULARY = (
    "UN", "KG", "G", "ML", "L", "PC", "CX", "PCT", "SC", "LT", "FD", "DZ",
)

# `2x500g`, `6 x 1l`, `12X350ML`: N items of a stated consumption amount. The
# consumption unit on the SECOND factor is what makes it a pack; without it the
# claim is not confirmed.
MULTIPACK_RE = re.compile(
    r"(?<![\d,.])(\d{1,4})\s*[xX]\s*(\d{1,4}(?:[.,]\d+)?)\s*"
    r"(kg|g|mg|l|lt|ml|cl|un|pc|pct|dz)\b",
    re.IGNORECASE,
)
# `C/12` -- the store's "contains 12", no consumption unit stated.
CONTAINS_RE = re.compile(r"\bc\s*/\s*\d{1,3}\b", re.IGNORECASE)
# `12UN` written without a separator, the `Nun` form of the decision.
N_UN_RE = re.compile(r"\b\d{1,3}\s*un\b", re.IGNORECASE)

# Container words as the enum spells them (lowercase). A container is only
# recorded when the description states it; it is never inferred.
CONTAINER_WORDS = {
    "cx": "cx", "pc": "pc", "pct": "pct", "sc": "sc", "lt": "lt", "un": "un",
}

# GTIN: the observed barcode. The DDL CHECK accepts `^[0-9]{8,14}$`, but a regex
# cannot see that 9/10/11 digits is not a GTIN, nor that a digit was misread --
# the check digit is a second, independent gate.
GTIN_RE = re.compile(r"^[0-9]{8,14}$")
# The lengths GS1 defines for a GTIN. A code of another length is not one.
GTIN_LENGTHS = (8, 12, 13, 14)


def gtin_check_digit_ok(code: str) -> bool:
    """GS1 mod-10 check digit, valid for GTIN-8/12/13/14.

    Weights 3,1 alternate from the digit LEFT of the check digit. The digit is
    verified, never inferred: a wrong check digit is a misread, not a value to
    repair.
    """
    body, check = code[:-1], int(code[-1])
    total = sum((3 if i % 2 == 0 else 1) * int(digit)
                for i, digit in enumerate(reversed(body)))
    return (10 - total % 10) % 10 == check


def classify_observed_code(raw) -> tuple[str | None, str | None]:
    """`(gtin, None)` when `raw` is a valid GTIN, else `(None, reason)`.

    Reasons: `short_or_malformed` (fewer than 8 digits or non-numeric --
    reading noise), `invalid_length` (a digit count no GTIN has, e.g. 11),
    `check_digit` (the GS1 mod-10 digit fails). The raw value is never modified:
    nothing is padded, completed or guessed.
    """
    code = str(raw).strip()
    if not GTIN_RE.match(code):
        return None, "short_or_malformed"
    if len(code) not in GTIN_LENGTHS:
        return None, "invalid_length"
    if not gtin_check_digit_ok(code):
        return None, "check_digit"
    return code, None


def normalize_text(text: str) -> str:
    """Lowercase, strip accents, collapse whitespace -- `description_search`."""
    text = unicodedata.normalize("NFD", str(text))
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", text.strip().lower())


def only_digits(value) -> str:
    return re.sub(r"\D", "", str(value or ""))


def recognize_sale_unit(sale_unit: str) -> str | None:
    """Raw label -> controlled vocabulary, or NULL (funnel to review).

    Case does not change the unit (ADR-0001 rule 11), so the comparison is
    case-insensitive. Anything outside the vocabulary stays NULL: `BJ` does not
    become a meaning by being spelled `BJ`.
    """
    label = (sale_unit or "").strip().upper()
    return label if label in SALE_UNIT_VOCABULARY else None


def infer_base_unit_and_factor(sale_unit: str) -> tuple[str, str]:
    """Smallest comparable unit and the factor of one sale unit in it."""
    su = (sale_unit or "").upper().strip()
    if su == "KG":
        return "G", "1000"
    if su in ("L", "LT"):
        return "ML", "1000"
    return "UN", "1"


def container_word(description: str) -> str | None:
    """The container the description states, as the enum spells it."""
    for word in re.findall(r"[a-z]+", description.lower()):
        if word in CONTAINER_WORDS:
            return CONTAINER_WORDS[word]
    return None


def extract_multipack(description: str) -> tuple[int | None, str | None]:
    """Conservative multipack extraction (decision 4).

    Returns `(multipack_quantity, container_type)`. Only `NxM` whose second
    factor carries a consumption unit confirms a pack. Everything else -- no
    claim, `c/N`, `Nun`, or a second factor with no unit -- returns `(None,
    None)`: the line stays pending instead of being guessed.
    """
    match = MULTIPACK_RE.search(description)
    if not match:
        return None, None
    count = int(match.group(1))
    if count < 2:  # `ck_presentations_multipack`: a pack of 1 is not a pack.
        return None, None
    return count, container_word(description)


def pack_hint(description: str) -> str | None:
    """A pack claim present but NOT confirmable -> review funnel."""
    if CONTAINS_RE.search(description):
        return "c/N"
    if N_UN_RE.search(description):
        return "Nun"
    return None


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
    unrecognized_units: Counter = Counter()
    confirmed_packs: list[tuple[str, str, int, str | None]] = []
    pending_packs: list[tuple[str, str, str]] = []
    # GTIN (J2): the observed code, validated, then written to
    # presentation_identifiers once every form exists.
    gtin_rejections: Counter = Counter()
    gtin_accepted_lines = 0
    gtin_form_of: dict[str, tuple] = {}
    gtin_provenance: dict[str, list[tuple[str, int]]] = {}
    gtin_by_form: dict[tuple, list[str]] = {}
    gtin_conflicts: list[tuple[str, ...]] = []

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
            # The ONE derived search representation (Ponto C). It is what the
            # product name and the mapping's generated match_key both derive
            # from; the raw wording stays verbatim next to it.
            desc_search = normalize_text(desc_raw)
            # The raw label is preserved exactly as printed (`pc`, `Un`, `Kg`,
            # `CX 10`): a fiscal fact, not a schema error. Only the recognised
            # layer and the base-unit inference are case-insensitive.
            sale_unit_raw = str(item["sale_unit"]).strip()
            recognized = recognize_sale_unit(sale_unit_raw)
            if recognized is None:
                unrecognized_units[sale_unit_raw] += 1
            base_unit, factor_base = infer_base_unit_and_factor(sale_unit_raw)
            multipack, container = extract_multipack(desc_search)
            label = note.get("receipt_label") or note["_file"]
            if multipack is not None:
                confirmed_packs.append((label, desc_search, multipack, container))
            else:
                hint = pack_hint(desc_search)
                if hint is not None:
                    pending_packs.append((label, desc_search, hint))
            # The GTIN, when the line declares one: validated here, emitted
            # after every form exists (see the identifier section below).
            raw_code = item.get("observed_code")
            if raw_code not in (None, ""):
                gtin, reject = classify_observed_code(raw_code)
                if gtin is None:
                    gtin_rejections[reject] += 1
                else:
                    gtin_accepted_lines += 1
                    form_key = (desc_search, recognized, container, multipack)
                    known = gtin_form_of.get(gtin)
                    if known is None:
                        gtin_form_of[gtin] = form_key
                        gtin_by_form.setdefault(form_key, []).append(gtin)
                    elif known != form_key:
                        # One GTIN identifies ONE commercial item
                        # (`uk_presentation_identifiers_gtin`): a code that
                        # points at two forms is a real conflict and cannot be
                        # stored -- refuse rather than silently pick one.
                        gtin_conflicts.append((gtin, known[0], form_key[0]))
                    gtin_provenance.setdefault(gtin, []).append(
                        (label, int(item["line_no"]))
                    )
            pack_sql = "NULL" if multipack is None else str(multipack)
            out.append(
                "        INSERT INTO products (name, base_unit)\n"
                f"        VALUES ({sql_literal(desc_search)}, {sql_literal(base_unit)})\n"
                "        ON CONFLICT ON CONSTRAINT uk_products_name_brand DO NOTHING;\n\n"
                "        SELECT id INTO v_product_id FROM products\n"
                f"         WHERE name = {sql_literal(desc_search)} AND brand IS NULL;\n\n"
                "        -- The form: factor lives here, the store wording does not.\n"
                "        INSERT INTO presentations (product_id, factor_base, sale_unit_recognized,\n"
                "                                   content_kind, content_quantity, content_unit,\n"
                "                                   container_type, multipack_quantity)\n"
                f"        VALUES (v_product_id, {factor_base}, {sql_literal(recognized)},\n"
                f"                'UNKNOWN', NULL, NULL, {sql_literal(container)}, {pack_sql})\n"
                "        ON CONFLICT ON CONSTRAINT uk_presentations_form DO NOTHING;\n\n"
                "        SELECT id INTO v_presentation_id FROM presentations\n"
                "         WHERE product_id = v_product_id\n"
                f"           AND sale_unit_recognized IS NOT DISTINCT FROM {sql_literal(recognized)}\n"
                "           AND content_kind = 'UNKNOWN'\n"
                "           AND content_quantity IS NULL AND content_unit IS NULL\n"
                f"           AND container_type IS NOT DISTINCT FROM {sql_literal(container)}\n"
                f"           AND multipack_quantity IS NOT DISTINCT FROM {pack_sql};\n\n"
                "        -- The mapping: several wordings may point at one form.\n"
                "        INSERT INTO presentation_sources\n"
                "            (presentation_id, store_id, sale_unit, description_raw, description_search)\n"
                f"        VALUES (v_presentation_id, v_store_id, {sql_literal(sale_unit_raw)},\n"
                f"                {sql_literal(desc_raw)}, {sql_literal(desc_search)})\n"
                "        ON CONFLICT ON CONSTRAINT uk_presentation_sources_store_key DO NOTHING;\n\n"
                "        INSERT INTO line_items (note_id, product_id, presentation_id, line_no,\n"
                "                                unit_price, quantity, line_total)\n"
                f"        VALUES (v_note_id, v_product_id, v_presentation_id, {int(item['line_no'])},\n"
                f"                {Decimal(str(item['unit_price']))}, {Decimal(str(item['quantity']))}, "
                f"{Decimal(str(item['line_total']))});"
            )
        out.append("    END IF;\nEND $$;")

    # -------------------------------------------------------------------------
    # presentation_identifiers -- the observed GTINs (J2)
    # -------------------------------------------------------------------------
    # Emitted LAST, so every form the lines created already exists. That also
    # makes the section load onto a base whose notes were already imported: the
    # note insert is skipped, but the form remains and the GTIN still lands.
    if gtin_conflicts:
        detail = "; ".join(
            f"{gtin} -> {form_a!r} vs {form_b!r}"
            for gtin, form_a, form_b in gtin_conflicts
        )
        raise ValueError(
            "observed GTIN maps to more than one form, which "
            f"uk_presentation_identifiers_gtin cannot hold: {detail}"
        )

    if gtin_by_form:
        out.append(
            "-- ---------------------------------------------------------------------------\n"
            "-- presentation_identifiers -- observed GTINs (J2)\n"
            "--\n"
            "-- Only codes that are a REAL GTIN: format `^[0-9]{8,14}$` AND a GTIN length\n"
            "-- (8/12/13/14) AND a correct GS1 mod-10 check digit. Nothing is padded,\n"
            "-- completed or inferred; a code that fails stays only in the private source.\n"
            "-- Each is tied to the form its line derived, resolved by the same tuple, so\n"
            "-- this section also loads onto an already-loaded base. One row per distinct\n"
            "-- GTIN (`uk_presentation_identifiers_gtin`); provenance (note, line) is in the\n"
            "-- comment above each value."
        )
    for form_key, gtins in sorted(gtin_by_form.items(), key=lambda kv: kv[0][0]):
        desc_search, recognized, container, multipack = form_key
        pack_sql = "NULL" if multipack is None else str(multipack)
        block = [
            "DO $$",
            "DECLARE",
            "    v_presentation_id UUID;",
            "BEGIN",
            "    SELECT pr.id INTO v_presentation_id",
            "      FROM presentations pr",
            "      JOIN products p ON p.id = pr.product_id",
            f"     WHERE p.name = {sql_literal(desc_search)} AND p.brand IS NULL",
            f"       AND pr.sale_unit_recognized IS NOT DISTINCT FROM {sql_literal(recognized)}",
            "       AND pr.content_kind = 'UNKNOWN'",
            "       AND pr.content_quantity IS NULL AND pr.content_unit IS NULL",
            f"       AND pr.container_type IS NOT DISTINCT FROM {sql_literal(container)}",
            f"       AND pr.multipack_quantity IS NOT DISTINCT FROM {pack_sql};",
            "    IF v_presentation_id IS NULL THEN",
            "        RAISE NOTICE 'gtin section: no form for %; nothing loaded', "
            f"{sql_literal(desc_search)};",
            "    ELSE",
        ]
        for gtin in sorted(gtins):
            provenance = ", ".join(
                f"{lab} line {ln}" for lab, ln in gtin_provenance.get(gtin, [])
            )
            block.append(f"        -- {gtin} from {provenance}")
        block += [
            "        INSERT INTO presentation_identifiers (presentation_id, gtin) VALUES",
            ",\n".join(
                f"            (v_presentation_id, {sql_literal(g)})"
                for g in sorted(gtins)
            ),
            "        ON CONFLICT ON CONSTRAINT uk_presentation_identifiers_gtin DO NOTHING;",
            "    END IF;",
            "END $$;",
        ]
        out.append("\n".join(block))

    if args.transaction:
        out.append("COMMIT;")

    print(
        f"# files={len({n['_file'] for n in notes})} notes={notes_total} "
        f"lines={lines_total} empty_skipped={skipped}",
        file=sys.stderr,
    )
    for name in sorted(per_store):
        print(f"#   {name}: {per_store[name]} lines", file=sys.stderr)
    if unrecognized_units:
        total = sum(unrecognized_units.values())
        detail = ", ".join(f"{u!r}x{c}" for u, c in unrecognized_units.most_common())
        print(
            f"# sale_unit outside the vocabulary -> NULL, review funnel: "
            f"{total} line(s) [{detail}]",
            file=sys.stderr,
        )
    for label, desc, count, container in confirmed_packs:
        print(
            f"# multipack CONFIRMED {label}: {desc!r} -> multipack_quantity={count} "
            f"container_type={container or 'NULL'}",
            file=sys.stderr,
        )
    for label, desc, hint in pending_packs:
        print(
            f"# multipack PENDING ({hint}) {label}: {desc!r} -> left NULL for review",
            file=sys.stderr,
        )
    if gtin_accepted_lines or gtin_rejections:
        accepted_gtins = len(gtin_form_of)
        print(
            f"# GTIN observed: {gtin_accepted_lines} line(s) accepted -> "
            f"{accepted_gtins} distinct GTIN -> presentation_identifiers",
            file=sys.stderr,
        )
        if gtin_accepted_lines > accepted_gtins:
            print(
                f"#   duplicate line occurrences collapsed: "
                f"{gtin_accepted_lines - accepted_gtins}",
                file=sys.stderr,
            )
        if gtin_rejections:
            total_rejected = sum(gtin_rejections.values())
            detail = ", ".join(
                f"{reason}={count}" for reason, count in gtin_rejections.most_common()
            )
            print(
                f"#   rejected (never repaired): {total_rejected} [{detail}]",
                file=sys.stderr,
            )
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
