#!/usr/bin/env python3
"""Generate SQL to populate home_shopper DB with 15 receipts."""
import json
import re
import unicodedata
from pathlib import Path

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
    text = unicodedata.normalize("NFD", text)
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", text.strip().lower())


def infer_base_unit_and_factor(sale_unit: str, description: str) -> tuple:
    su = sale_unit.upper().strip()
    if su == "KG":
        return "G", "1000"
    if su in ("L", "LT"):
        return "ML", "1000"
    return "UN", "1"


def sql_escape(s: str) -> str:
    return s.replace("'", "''")


def main():
    lines = []
    lines.append("BEGIN;")
    lines.append("")

    # User
    lines.append("-- User")
    lines.append("""
INSERT INTO users (id, name, email)
VALUES ('00000000-0000-0000-0000-000000000001', 'default_user', 'user@example.com')
ON CONFLICT (email) DO NOTHING;
""")

    # Stores
    lines.append("-- Stores")
    for cnpj, name in STORE_MAP.items():
        lines.append(f"""
INSERT INTO stores (name, cnpj)
VALUES ('{sql_escape(name)}', '{cnpj}')
ON CONFLICT (cnpj) DO UPDATE SET name = EXCLUDED.name;
""")

    # Process receipts
    for rel_path in RECEIPTS:
        path = PROBE_DIR / rel_path
        with open(path, "r", encoding="utf-8") as f:
            receipt = json.load(f)

        cnpj = receipt["issuer_cnpj"]
        source_ref = (receipt.get("source_ref") or "")[:44] or None
        purchase_date = receipt["purchase_date"]
        amount_paid = receipt["amount_paid"]
        source_ref_sql = f"'{source_ref}'" if source_ref else "NULL"

        lines.append(f"-- Receipt: {receipt['receipt_label']}")

        lines.append(f"""
DO $$
DECLARE
    v_note_id UUID;
    v_product_id UUID;
    v_presentation_id UUID;
    v_store_id UUID;
BEGIN
    SELECT id INTO v_store_id FROM stores WHERE cnpj = '{cnpj}';

    INSERT INTO purchase_notes (user_id, store_id, access_key, purchase_date, amount_paid)
    VALUES ('00000000-0000-0000-0000-000000000001', v_store_id, {source_ref_sql}, '{purchase_date}', {amount_paid})
    ON CONFLICT (user_id, access_key) WHERE access_key IS NOT NULL DO NOTHING
    RETURNING id INTO v_note_id;

    IF v_note_id IS NULL THEN
        RAISE NOTICE 'Skipping duplicate receipt: %', {source_ref_sql};
    ELSE
""")

        for item in receipt["items"]:
            desc = item["description_raw"]
            desc_norm = normalize_text(desc)
            sale_unit = item["sale_unit"]
            quantity = item["quantity"]
            unit_price = item["unit_price"]
            line_total = item["line_total"]
            line_no = item["line_no"]

            base_unit, factor_base = infer_base_unit_and_factor(sale_unit, desc)

            lines.append(f"""
        INSERT INTO products (name, base_unit)
        VALUES ('{sql_escape(desc_norm)}', '{base_unit}')
        ON CONFLICT (name, brand) WHERE brand IS NULL DO NOTHING;

        SELECT id INTO v_product_id FROM products WHERE name = '{sql_escape(desc_norm)}' AND brand IS NULL;

        INSERT INTO presentations (product_id, sale_unit, factor_base, description_raw, description_norm, store_id)
        VALUES (v_product_id, '{sale_unit}', {factor_base}, '{sql_escape(desc)}', '{sql_escape(desc_norm)}', v_store_id)
        ON CONFLICT (product_id, match_key, store_id) WHERE store_id IS NOT NULL DO UPDATE SET id = presentations.id
        RETURNING id INTO v_presentation_id;

        INSERT INTO line_items (note_id, product_id, presentation_id, line_no, unit_price, quantity, line_total)
        VALUES (v_note_id, v_product_id, v_presentation_id, {line_no}, {unit_price}, {quantity}, {line_total});
""")

        lines.append("""    END IF;
END $$;
""")

    lines.append("COMMIT;")

    output_path = Path("<home>/<internal>")
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"SQL written to {output_path}")
    print(f"Total lines: {len(lines)}")


if __name__ == "__main__":
    main()