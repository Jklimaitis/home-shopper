#!/usr/bin/env python3
"""
Tests for `services/matcher.py` -- the automatic staging-line matcher.

Every test is a unit test: the database connection is mocked, so the suite
runs without Docker and without a live PostgreSQL. What is being pinned down:

* A valid GTIN in `presentation_identifiers` resolves to its presentation and
  product, with match_source=BARCODE and confidence=1.0.
* A normalized description in `presentation_sources` resolves with
  match_source=DESCRIPTION and confidence=0.9.
* A description that matches nothing returns match_source=NONE with NULL ids.
* A closed connection raises (the error propagates to the caller, which rolls
  back the transaction -- a matcher failure must never leave a half-matched
  receipt in staging).

Run:

    python -m unittest discover -s tests -p 'test_*.py'
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from services.matcher import match_staging_line, normalize_text  # noqa: E402


class FakeCursor:
    """A minimal psycopg2 cursor mock.

    The matcher issues at most two queries per call: first the GTIN lookup,
    then the description lookup. The mock routes by SQL content, so each test
    controls exactly what the database would return.
    """

    def __init__(self, gtin_row=None, desc_row=None):
        self._gtin_row = gtin_row
        self._desc_row = desc_row
        self._last_sql = ""

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, sql, params=None):
        self._last_sql = sql

    def fetchone(self):
        if "presentation_identifiers" in self._last_sql:
            return self._gtin_row
        return self._desc_row


class FakeConnection:
    """A minimal psycopg2 connection mock.

    `cursor()` returns a FakeCursor. When `closed` is True, cursor() raises
    ProgrammingError, simulating a connection that has been closed.
    """

    def __init__(self, gtin_row=None, desc_row=None, closed=False):
        self._gtin_row = gtin_row
        self._desc_row = desc_row
        self.closed = closed

    def cursor(self):
        if self.closed:
            raise RuntimeError("connection closed")
        return FakeCursor(self._gtin_row, self._desc_row)


class TestNormalizeText(unittest.TestCase):
    def test_strips_accents(self):
        self.assertEqual(normalize_text("ÇA FÉ COM LEITE"), "ca fe com leite")

    def test_lowercases(self):
        self.assertEqual(normalize_text("ARROZ TIO JOAO"), "arroz tio joao")

    def test_collapses_whitespace(self):
        self.assertEqual(normalize_text("  CARNE   MOIDA  "), "carne moida")

    def test_empty_string(self):
        self.assertEqual(normalize_text(""), "")


class TestMatchByBarcode(unittest.TestCase):
    def test_valid_gtin_resolves_to_presentation(self):
        gtin_row = ("pres-uuid-1", "prod-uuid-1")
        conn = FakeConnection(gtin_row=gtin_row)
        result = match_staging_line(conn, raw_description="ARROZ 5KG",
                                    barcode="7891000412855")
        self.assertEqual(result.match_source, "BARCODE")
        self.assertEqual(result.presentation_id, "pres-uuid-1")
        self.assertEqual(result.product_id, "prod-uuid-1")
        self.assertEqual(result.confidence, 1.0)

    def test_no_gtin_falls_through_to_description(self):
        # No barcode provided -> the GTIN query returns None, description query
        # is the next step.
        desc_row = ("pres-uuid-2", "prod-uuid-2")
        conn = FakeConnection(gtin_row=None, desc_row=desc_row)
        result = match_staging_line(conn, raw_description="FEIJAO 1KG")
        self.assertEqual(result.match_source, "DESCRIPTION")
        self.assertEqual(result.presentation_id, "pres-uuid-2")
        self.assertEqual(result.product_id, "prod-uuid-2")


class TestMatchByDescription(unittest.TestCase):
    def test_normalized_description_resolves(self):
        desc_row = ("pres-uuid-3", "prod-uuid-3")
        conn = FakeConnection(gtin_row=None, desc_row=desc_row)
        result = match_staging_line(conn, raw_description="  CARNE   MOIDA  ")
        self.assertEqual(result.match_source, "DESCRIPTION")
        self.assertEqual(result.presentation_id, "pres-uuid-3")
        self.assertEqual(result.product_id, "prod-uuid-3")
        self.assertEqual(result.confidence, 0.9)

    def test_no_match_returns_none(self):
        conn = FakeConnection(gtin_row=None, desc_row=None)
        result = match_staging_line(conn, raw_description="PRODUTO INEXISTENTE")
        self.assertEqual(result.match_source, "NONE")
        self.assertIsNone(result.product_id)
        self.assertIsNone(result.presentation_id)
        self.assertEqual(result.confidence, 0.0)


class TestErrorPropagation(unittest.TestCase):
    def test_closed_connection_raises(self):
        conn = FakeConnection(closed=True)
        with self.assertRaises(RuntimeError):
            match_staging_line(conn, raw_description="ARROZ", barcode="123")

    def test_connection_closed_does_not_swallow_error(self):
        # The matcher must NOT catch the error silently: the caller (ingest)
        # needs to know so it can roll back the transaction.
        conn = FakeConnection(closed=True)
        raised = False
        try:
            match_staging_line(conn, raw_description="FEIJAO")
        except RuntimeError:
            raised = True
        self.assertTrue(raised)


if __name__ == "__main__":
    unittest.main()
