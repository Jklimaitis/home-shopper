#!/usr/bin/env python3
"""Populate home_shopper DB with 15 receipts from the probe."""
import json
import os
import re
import sys
from decimal import Decimal
from pathlib import Path

import psycopg2
import psycopg2.extras

DB_DSN = "dbname=home_shopper user=home_shopper host=localhost"
PROBE_DIR = Path("<windows>/AppData/Local/<internal>")

RECEIPTS = [
    "receipt_1.json",
    "nfs_2025/receipt_37971.json",
    "nfs_2025/receipt_39333.json",
    "nfs_2025/receipt_44700.json",
    "nfs_2025/receipt_46419.json",
    "nfs_2025/receipt_40798.json",
    "nfs_2025/receipt_14160.json",
    "nfs_2025/receipt_143973.json",
    "receipt_5.json",
    "receipt_6.json",
    "receipt_4.json",
    "nfs_20260930/receipt_3.json",
    "nfs_20260930/receipt_7.json",
    "nfs_20260930/receipt_8.json",
    "nfs_20260930/receipt_5.json",
]

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
    """Lowercase, strip accents, collapse whitespace."""
    import unicodedata
    text = unicodedata.normalize("NFD", text)
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", text.strip().lower())


def infer_base_unit_and_factor(sale_unit: str, description: str) -> tuple[str, Decimal]:
    """Infer base_unit and factor_base from sale_unit and description."""
    su = sale_unit.upper().strip()
    desc_lower = description.lower()

    # KG sold by weight -> base G, factor 1000
    if su == "KG":
        return "G", Decimal("1000")

    # Liters -> base ML, factor 1000
    if su in ("L", "LT"):
        return "ML", Decimal("1000")

    # UN, PC, BJ, etc. -> base UN, factor 1
    if su in ("UN", "PC", "BJ", "PCT", "PAC", "CX", "FD", "GL", "GF", "LA", "AM"):
        return "UN", Decimal("1")

    # Default: UN
    return "UN", Decimal("1")


def load_receipts():
    receipts = []
    for rel_path in RECEIPTS:
        path = PROBE_DIR / rel_path
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        receipts.append(data)
    return receipts


def main():
    receipts = load_receipts()
    print(f"Loaded {len(receipts)} receipts")

    conn = psycopg2.connect(DB_DSN)
    conn.autocommit = False
    cur = conn.cursor()

    # Create user
    cur.execute("""
        INSERT INTO users (id, name, email)
        VALUES ('00000000-0000-0000-0000-000000000001', 'Jonas Klimaitis', 'user@example.com')
        ON CONFLICT (email) DO NOTHING
        RETURNING id
    """)
    user_id = cur.fetchone()[0]
    print(f"User: {user_id}")

    # Create stores
    store_ids = {}
    for cnpj, name in STORE_MAP.items():
        cur.execute("""
            INSERT INTO stores (name, cnpj)
            VALUES (%s, %s)
            ON CONFLICT (cnpj) DO UPDATE SET name = EXCLUDED.name
            RETURNING id
        """, (name, cnpj))
        store_ids[cnpj] = cur.fetchone()[0]
    print(f"Stores: {len(store_ids)}")

    # Process each receipt
    total_items = 0
    for receipt in receipts:
        cnpj = receipt["issuer_cnpj"]
        store_id = store_ids[cnpj]
        source_ref = receipt.get("source_ref")
        purchase_date = receipt["purchase_date"]
        amount_paid = Decimal(receipt["amount_paid"])
        reported_total = Decimal(receipt["reported_total"])
        discount = Decimal(receipt.get("discount", "0"))

        # Create purchase_note
        cur.execute("""
            INSERT INTO purchase_notes (user_id, store_id, access_key, purchase_date, amount_paid)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (user_id, access_key) WHERE access_key IS NOT NULL DO NOTHING
            RETURNING id
        """, (user_id, store_id, source_ref, purchase_date, amount_paid))
        note_row = cur.fetchone()
        if note_row is None:
            print(f"  SKIP duplicate: {receipt['receipt_label']}")
            continue
        note_id = note_row[0]

        # Process items
        for item in receipt["items"]:
            desc = item["description_raw"]
            desc_norm = normalize_text(desc)
            sale_unit = item["sale_unit"]
            quantity = Decimal(item["quantity"])
            unit_price = Decimal(item["unit_price"])
            line_total = Decimal(item["line_total"])

            base_unit, factor_base = infer_base_unit_and_factor(sale_unit, desc)

            # Create or get product
            cur.execute("""
                INSERT INTO products (name, base_unit)
                VALUES (%s, %s)
                ON CONFLICT (name, brand) WHERE brand IS NULL DO NOTHING
                RETURNING id
            """, (desc_norm, base_unit))
            prod_row = cur.fetchone()
            if prod_row is None:
                cur.execute("SELECT id FROM products WHERE name = %s AND brand IS NULL", (desc_norm,))
                prod_row = cur.fetchone()
            product_id = prod_row[0]

            # Create or get presentation
            cur.execute("""
                INSERT INTO presentations (product_id, sale_unit, factor_base, description_raw, description_norm, store_id)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (product_id, match_key, store_id) WHERE store_id IS NOT NULL DO NOTHING
                RETURNING id
            """, (product_id, sale_unit, factor_base, desc, desc_norm, store_id))
            pres_row = cur.fetchone()
            if pres_row is None:
                cur.execute("""
                    SELECT id FROM presentations
                    WHERE product_id = %s AND match_key = %s AND store_id = %s
                """, (product_id, desc_norm, store_id))
                pres_row = cur.fetchone()
            presentation_id = pres_row[0]

            # Create line_item
            cur.execute("""
                INSERT INTO line_items (note_id, product_id, presentation_id, line_no, unit_price, quantity, line_total)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, (note_id, product_id, presentation_id, item["line_no"], unit_price, quantity, line_total))
            total_items += 1

        print(f"  {receipt['receipt_label']}: {len(receipt['items'])} items")

    conn.commit()
    print(f"\nTotal items inserted: {total_items}")

    # Validate checksums
    print("\n=== CHECKSUM VALIDATION ===")
    cur.execute("""
        SELECT n.id, n.amount_paid, sum(li.line_total) as computed
        FROM purchase_notes n
        JOIN line_items li ON li.note_id = n.id
        GROUP BY n.id, n.amount_paid
    """)
    mismatches = 0
    for row in cur.fetchall():
        note_id, amount_paid, computed = row
        if amount_paid != computed:
            print(f"  MISMATCH note {note_id}: paid={amount_paid} computed={computed}")
            mismatches += 1
    if mismatches == 0:
        print("  All checksums OK")
    else:
        print(f"  {mismatches} mismatches found")

    cur.close()
    conn.close()


if __name__ == "__main__":
    main()