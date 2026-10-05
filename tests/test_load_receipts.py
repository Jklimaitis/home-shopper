#!/usr/bin/env python3
"""
Tests for `scripts/load_receipts.py` -- the form/mapping loader.

Run without Docker and without real data; every receipt in here is synthetic:

    python -m unittest discover -s tests -p 'test_*.py'

What is being pinned down, and why it is worth a test
----------------------------------------------------
* The controlled vocabulary of `sale_unit_recognized`: a label outside it must
  stay NULL (review funnel) and case must not change the unit (ADR-0001 rule 11).
* The CONSERVATIVE multipack extraction (segment 1, decision 4): `NxM` is a pack
  only when the second factor carries a consumption unit; `c/N` and `Nun` are
  hints that go to review. A regression here silently invents packaging.
* The generated SQL must target the split model -- no `presentations.sale_unit`
  / `description_raw` / `description_norm` / `match_key` / `store_id` and no
  `products.ean`, and the two keys that replace the old one must be named.
"""
from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import load_receipts  # noqa: E402  (needs the sys.path above)

# A placeholder CNPJ, not a real store. `stores.ck_stores_cnpj` wants 14 digits.
PLACEHOLDER_CNPJ = "99999999000199"


def synthetic_note(items: list[dict]) -> dict:
    """A keyless note: no access key ever lands in a test fixture."""
    return {
        "issuer_cnpj": PLACEHOLDER_CNPJ,
        "issuer_name": "Loja Sintetica",
        "receipt_label": "synthetic_note",
        "purchase_date": "2026-01-02",
        "amount_paid": "10.00",
        "items": items,
    }


def synthetic_item(line_no: int, description: str, sale_unit: str = "UN",
                   observed_code: str | None = None) -> dict:
    item = {
        "line_no": line_no,
        "description_raw": description,
        "sale_unit": sale_unit,
        "quantity": "1",
        "unit_price": "10.00",
        "line_total": "10.00",
    }
    if observed_code is not None:
        item["observed_code"] = observed_code
    return item


class TestNormalizeAndUnits(unittest.TestCase):
    def test_normalize_strips_accents_case_and_extra_space(self):
        self.assertEqual(load_receipts.normalize_text("  CAFÉ  COM   Leite \n"),
                         "cafe com leite")

    def test_recognized_unit_is_case_folded(self):
        for raw, expected in (("UN", "UN"), ("un", "UN"), ("Un", "UN"),
                              ("KG", "KG"), ("Kg", "KG"), ("kg", "KG"),
                              ("PC", "PC"), ("pc", "PC")):
            with self.subTest(raw=raw):
                self.assertEqual(load_receipts.recognize_sale_unit(raw), expected)

    def test_label_outside_the_vocabulary_is_null_not_guessed(self):
        # `BJ`, `Gf`, `Am`, `Gl`, `La` are real emitter labels the canonical
        # base kept NULL; they must never become a unit by spell.
        for raw in ("BJ", "Gf", "Am", "Gl", "La", "FRASCO", "CX 10", "c/N", ""):
            with self.subTest(raw=raw):
                self.assertIsNone(load_receipts.recognize_sale_unit(raw))

    def test_base_unit_and_factor(self):
        self.assertEqual(load_receipts.infer_base_unit_and_factor("kg"), ("G", "1000"))
        self.assertEqual(load_receipts.infer_base_unit_and_factor("KG"), ("G", "1000"))
        self.assertEqual(load_receipts.infer_base_unit_and_factor("L"), ("ML", "1000"))
        self.assertEqual(load_receipts.infer_base_unit_and_factor("lt"), ("ML", "1000"))
        # No conversion is presumed: an uninterpreted label is 1 UN, never a
        # mass/volume factor derived from the description.
        self.assertEqual(load_receipts.infer_base_unit_and_factor("BJ"), ("UN", "1"))
        self.assertEqual(load_receipts.infer_base_unit_and_factor("pc"), ("UN", "1"))


class TestMultipack(unittest.TestCase):
    def test_nxm_with_consumption_unit_is_confirmed(self):
        self.assertEqual(load_receipts.extract_multipack("mn hellm 2x500g l+p-"), (2, None))
        self.assertEqual(load_receipts.extract_multipack("refri 6x1l"), (6, None))
        self.assertEqual(load_receipts.extract_multipack("leite cx 12x1l"), (12, "cx"))

    def test_nxm_without_consumption_unit_is_not_confirmed(self):
        # `48x5` (the sacola) has no unit on the second factor: pending.
        self.assertEqual(load_receipts.extract_multipack("sacola verde sp 48x5"), (None, None))
        self.assertEqual(load_receipts.extract_multipack("sem pack aqui"), (None, None))
        # A pack of one is not a pack (`ck_presentations_multipack`).
        self.assertEqual(load_receipts.extract_multipack("1x500g"), (None, None))

    def test_hints_go_to_review_and_are_never_values(self):
        self.assertEqual(load_receipts.pack_hint("prot fog facili c/12"), "c/N")
        self.assertEqual(load_receipts.pack_hint("ovo org c ftoca 20un"), "Nun")
        self.assertEqual(load_receipts.pack_hint("arroz 5kg"), None)
        for hint in ("prot fog facili c/12", "ovo 20un"):
            self.assertEqual(load_receipts.extract_multipack(hint), (None, None))


class TestGtinValidation(unittest.TestCase):
    """A code enters `presentation_identifiers` only when it is a REAL GTIN."""

    def test_accepts_valid_gtin8_gtin12_gtin13(self):
        for code in ("7891000412855", "7891203010056", "618231517695",
                     "96385074"):
            with self.subTest(code=code):
                self.assertEqual(load_receipts.classify_observed_code(code),
                                 (code, None))

    def test_short_and_non_numeric_codes_are_reading_noise(self):
        # 1-7 digits are the fragments an emitter prints; never a GTIN, and
        # never completed into one.
        for raw in ("504", "5984", "1339812", "", "ABC123", "12 34"):
            with self.subTest(raw=raw):
                self.assertEqual(load_receipts.classify_observed_code(raw),
                                 (None, "short_or_malformed"))

    def test_a_length_no_gtin_has_is_rejected(self):
        # 11 digits passes the DDL CHECK but is not a GTIN length. The value is
        # anonymised (eleven zeros): a real 11-digit emitter code reads as a
        # CPF to the guard, and the test must pin the LENGTH, not the digits.
        self.assertEqual(load_receipts.classify_observed_code("00000000000"),
                         (None, "invalid_length"))

    def test_a_wrong_check_digit_is_rejected_not_repaired(self):
        # 7891000412855 is valid; the trailing 4 is a misread, not a value to fix.
        self.assertEqual(load_receipts.classify_observed_code("7891000412854"),
                         (None, "check_digit"))

    def test_whitespace_is_stripped_but_digits_are_untouched(self):
        self.assertEqual(load_receipts.classify_observed_code(" 7891000412855 "),
                         ("7891000412855", None))


class TestNoteFields(unittest.TestCase):
    def test_iso_date_accepts_both_formats(self):
        self.assertEqual(load_receipts.iso_date({"emission": "05/10/2026 13:22:00"}),
                         "2026-10-05")
        self.assertEqual(load_receipts.iso_date({"purchase_date": "2026-10-05"}),
                         "2026-10-05")
        self.assertIsNone(load_receipts.iso_date({}))

    def test_access_key_accepts_formatted_input_and_rejects_short_values(self):
        digits = "3" * 43 + "1"
        formatted = "-".join(digits[i:i + 4] for i in range(0, 44, 4))
        self.assertEqual(load_receipts.access_key({"access_key": formatted}), digits)
        self.assertEqual(load_receipts.access_key({"source_ref": digits}), digits)
        self.assertIsNone(load_receipts.access_key({"access_key": "123"}))

    def test_amount_paid_falls_back_to_amount_payable(self):
        self.assertEqual(load_receipts.amount_paid({"amount_payable": "544.93"}), "544.93")
        self.assertIsNone(load_receipts.amount_paid({}))

    def test_sql_literal_escapes_quotes(self):
        self.assertEqual(load_receipts.sql_literal("d'or"), "'d''or'")
        self.assertEqual(load_receipts.sql_literal(None), "NULL")


class TestEmittedSql(unittest.TestCase):
    """End to end over a synthetic input dir: the SQL must target the new model."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        note = synthetic_note([
            synthetic_item(1, "CARNE MOIDA 1KG", "Kg",
                           observed_code="7891000412855"),
            synthetic_item(2, "REFRIG 2X500G", "UN"),
            synthetic_item(3, "PAPEL C/12", "UN"),
            synthetic_item(4, "SAL grosso", "BJ"),
        ])
        path = Path(self._tmp.name) / "note.json"
        path.write_text(json.dumps([note]), encoding="utf-8")
        args = load_receipts.argparse.Namespace(
            user_id="00000000-0000-0000-0000-0000000000aa",
            user_name="Teste", user_email="teste@example.com",
            transaction=True, dry_run=False,
        )
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.sql = "\n".join(load_receipts.emit(load_receipts.load_notes(Path(self._tmp.name)), args))
        self.summary = err.getvalue()

    def test_targets_the_split_model_keys(self):
        self.assertIn("uk_presentations_form", self.sql)
        self.assertIn("uk_presentation_sources_store_key", self.sql)
        self.assertIn("uk_products_name_brand", self.sql)

    def test_never_names_a_dropped_column_or_key(self):
        for dropped in ("description_norm", "match_key", "products (name, base_unit, ean)",
                        "(product_id, match_key, store_id)"):
            with self.subTest(dropped=dropped):
                self.assertNotIn(dropped, self.sql)
        # `store_id` must appear only as the MAPPING's own column, never on the
        # form: the form insert lists its columns explicitly.
        insert_form = [ln for ln in self.sql.splitlines()
                       if "INSERT INTO presentations (" in ln or ln.strip().startswith("content_kind")][0]
        self.assertNotIn("store_id", insert_form)

    def test_sale_unit_is_verbatim_and_recognized_is_separate(self):
        # `Kg` is preserved verbatim on the mapping while the form carries the
        # case-folded `KG` -- the two layers must not be collapsed into one.
        self.assertIn("'Kg'", self.sql)
        self.assertIn("'KG'", self.sql)
        self.assertIn("'UN'", self.sql)

    def test_multipack_and_review_funnel_in_the_summary(self):
        self.assertIn("multipack CONFIRMED", self.summary)
        self.assertIn("multipack_quantity=2", self.summary)
        self.assertIn("multipack PENDING (c/N)", self.summary)
        self.assertIn("outside the vocabulary", self.summary)

    def test_content_is_left_unknown(self):
        self.assertIn("'UNKNOWN', NULL, NULL", self.sql)

    def test_valid_gtin_is_written_to_presentation_identifiers(self):
        self.assertIn("INSERT INTO presentation_identifiers", self.sql)
        self.assertIn("'7891000412855'", self.sql)
        self.assertIn("uk_presentation_identifiers_gtin", self.sql)
        # One row per distinct GTIN; the section carries the provenance.
        self.assertIn("-- 7891000412855 from synthetic_note line 1", self.sql)
        self.assertIn("GTIN observed: 1 line(s) accepted -> 1 distinct GTIN",
                      self.summary)

    def test_no_observed_code_means_no_identifier_section(self):
        # The other three lines have no `observed_code`: they must never
        # produce an identifier row.
        self.assertEqual(self.sql.count("INSERT INTO presentation_identifiers"), 1)


class TestGtinConflict(unittest.TestCase):
    """A GTIN that would point at two forms is refused, never silently kept."""

    def test_same_gtin_on_two_forms_raises(self):
        note = synthetic_note([
            synthetic_item(1, "CARNE MOIDA 1KG", "Kg",
                           observed_code="7891000412855"),
            synthetic_item(2, "ARROZ TIO JOAO 5KG", "UN",
                           observed_code="7891000412855"),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "note.json"
            path.write_text(json.dumps([note]), encoding="utf-8")
            args = load_receipts.argparse.Namespace(
                user_id="00000000-0000-0000-0000-0000000000bb",
                user_name="Teste", user_email="teste@example.com",
                transaction=True, dry_run=False,
            )
            notes = load_receipts.load_notes(Path(tmp))
            with contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(ValueError):
                load_receipts.emit(notes, args)


if __name__ == "__main__":
    unittest.main()
