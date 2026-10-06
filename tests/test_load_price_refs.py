#!/usr/bin/env python3
"""Tests for `scripts/load_price_refs.py` -- the price_refs batch.

Run without Docker and without real data:

    python -m unittest discover -s tests -p 'test_*.py'

What is being pinned down, and why it is worth a test
-----------------------------------------------------
* The 30-day window is relative to each row's `ref_date` -- never to
  `current_date`. A `current_date` window on data spanning 2025-09..2026-09
  leaves `min_30d`/`max_30d` empty for nearly every row with no error: the
  single most expensive mistake this batch can make, and invisible without a
  test.
* `base_unit` is part of the window join. Dropping it would `min()` across
  `0,0299 in G` and `29,9 in KG` (ADR-0003 1).
* `samples_30d` is written -- the count the alert minimum needs (ADR-0003
  pending item, db/013). Without it the threshold is undecidable later.
* `var_pct_30d` is NOT written (left NULL): ADR-0003 does not define the
  formula, so neither reading may be stored by default.
* The re-run is a true no-op: the `ON CONFLICT ... DO UPDATE` carries a
  `WHERE ... IS DISTINCT FROM`, so a second run touches zero rows and
  `updated_at` does not move.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import load_price_refs  # noqa: E402  (needs the sys.path above)


class TestWindowIsRelativeToRefDate(unittest.TestCase):
    def setUp(self):
        self.sql = load_price_refs.build_sql(None)

    def test_window_ends_at_ref_date(self):
        self.assertIn("va3.ref_date  <= va.ref_date", self.sql)

    def test_window_starts_30_days_before_ref_date(self):
        self.assertIn("va3.ref_date   > va.ref_date - 30", self.sql)

    def test_current_date_is_never_used(self):
        # The whole point: a current_date window empties min_30d/max_30d on
        # historical rows with no error.
        self.assertNotIn("current_date", self.sql.lower())
        self.assertNotIn("now()::date", self.sql.lower())

    def test_base_unit_is_part_of_the_window_join(self):
        self.assertIn("va3.base_unit  = va.base_unit", self.sql)


class TestColumnsWritten(unittest.TestCase):
    def setUp(self):
        self.sql = load_price_refs.build_sql(None)

    def test_sample_count_is_written_in_insert_and_update(self):
        self.assertIn("samples_30d", self.sql)
        self.assertIn("samples_30d = EXCLUDED.samples_30d", self.sql)

    def test_var_pct_is_left_null(self):
        # No expression may compute var_pct_30d: ADR-0003 does not define it.
        self.assertIn("NULL::numeric", self.sql)
        self.assertNotIn("EXCLUDED.var_pct_30d", self.sql)
        self.assertNotIn("w.mx - w.mn", self.sql)

    def test_conflict_targets_the_named_constraint(self):
        self.assertIn(
            "ON CONFLICT ON CONSTRAINT uk_price_refs_user_product_store_date",
            self.sql,
        )

    def test_update_is_guarded_for_idempotency(self):
        self.assertIn("IS DISTINCT FROM", self.sql)


class TestUserScope(unittest.TestCase):
    def test_no_filter_by_default(self):
        self.assertNotIn("va.user_id =", load_price_refs.build_sql(None))

    def test_filter_is_placed_before_on_conflict(self):
        uid = "00000000-0000-0000-0000-000000000001"
        sql = load_price_refs.build_sql(uid)
        self.assertIn(f"WHERE va.user_id = '{uid}'::uuid", sql)
        self.assertLess(sql.index("WHERE va.user_id ="), sql.index("ON CONFLICT"))

    def test_invalid_uuid_is_refused(self):
        with self.assertRaises(SystemExit):
            load_price_refs.build_sql("not-a-uuid")


if __name__ == "__main__":
    unittest.main()
