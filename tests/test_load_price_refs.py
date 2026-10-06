#!/usr/bin/env python3
"""Tests for `scripts/load_price_refs.py` -- the price_refs batch.

Run without Docker and without real data:

    python -m unittest discover -s tests -p 'test_*.py'

What is being pinned down, and why it is worth a test
-----------------------------------------------------
* The batch writes the OBSERVATION and nothing else. Decision D10 (db/016)
  removed every per-preset column; a batch that still wrote `min_30d` /
  `max_30d` / `samples_30d` would be a second producer of a number
  `v_price_window` already computes, and the only one that can go stale.
* `price_change_pct` is written, and it is a LAG -- not a window. It compares
  against the previous observation of the same
  (user, product, store, unit), ordered by ref_date, so it does not depend on
  the preset the screen asks for.
* `price_change_pct` is NULL -- never 0 -- when there is nothing to compare
  against or the price did not move. `ck_price_refs_change_finite` forbids a 0,
  and a 0 would claim a variation that did not happen.
* `current_date` is never used. The window is relative to each row's `ref_date`;
  a `current_date` window on data spanning 2025-09..2026-09 is silently empty.
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

GONE_COLUMNS = ("min_30d", "max_30d", "var_pct_30d", "samples_30d",
                "price_spread_pct")


class TestObservationOnly(unittest.TestCase):
    def setUp(self):
        self.sql = load_price_refs.build_sql(None)

    def test_no_per_preset_column_is_written(self):
        # D10 option B: the window is a query (db/016). Writing any of these
        # would resurrect the column the migration dropped.
        for col in GONE_COLUMNS:
            self.assertNotIn(col, self.sql)

    def test_no_window_computation_at_all(self):
        # The 30-day LATERAL is what db/016 removed from the batch.
        self.assertNotIn("LATERAL", self.sql.upper())
        self.assertNotIn("make_interval", self.sql)
        self.assertNotIn("BETWEEN", self.sql.upper())

    def test_observation_columns_are_written(self):
        self.assertIn("(user_id, product_id, store_id, ref_date, base_unit,", self.sql)
        self.assertIn("base_price, price_change_pct, updated_at)", self.sql)
        self.assertIn("va.weighted_price", self.sql)

    def test_source_is_the_weighted_aggregation(self):
        self.assertIn("FROM v_price_aggregation va0", self.sql)

    def test_current_date_is_never_used(self):
        # A current_date window empties the historical rows with no error.
        self.assertNotIn("current_date", self.sql.lower())
        self.assertNotIn("now()::date", self.sql.lower())


class TestPriceChange(unittest.TestCase):
    def setUp(self):
        self.sql = load_price_refs.build_sql(None)

    def test_change_is_a_lag_over_the_same_key(self):
        self.assertIn("lag(va0.weighted_price) OVER w", self.sql)
        self.assertIn(
            "PARTITION BY va0.user_id, va0.product_id, va0.store_id, va0.base_unit",
            self.sql,
        )
        self.assertIn("ORDER BY va0.ref_date", self.sql)

    def test_change_against_the_previous_observation(self):
        self.assertIn("(va.weighted_price - va.prev_price)", self.sql)
        self.assertIn("/ va.prev_price * 100", self.sql)

    def test_no_previous_or_no_movement_is_null_never_zero(self):
        # Three honest NULLs and not one 0: no previous observation, a previous
        # price of 0 (division), and a price that did not move.
        self.assertIn("va.prev_price IS NULL", self.sql)
        self.assertIn("va.prev_price = 0", self.sql)
        self.assertIn("va.weighted_price = va.prev_price THEN NULL", self.sql)
        # The check constraint forbids 0, so the batch must never produce one.
        self.assertNotIn("ELSE 0", self.sql)
        self.assertNotIn("ELSE NULL::numeric, 0", self.sql)

    def test_change_is_updated_on_conflict(self):
        self.assertIn("price_change_pct = EXCLUDED.price_change_pct", self.sql)


class TestIdempotency(unittest.TestCase):
    def setUp(self):
        self.sql = load_price_refs.build_sql(None)

    def test_conflict_targets_the_named_constraint(self):
        self.assertIn(
            "ON CONFLICT ON CONSTRAINT uk_price_refs_user_product_store_date",
            self.sql,
        )

    def test_update_is_guarded_over_every_value_the_batch_owns(self):
        self.assertIn("IS DISTINCT FROM", self.sql)
        self.assertIn(
            "WHERE (price_refs.base_price, price_refs.base_unit, price_refs.price_change_pct)",
            self.sql,
        )
        self.assertIn(
            "(EXCLUDED.base_price, EXCLUDED.base_unit, EXCLUDED.price_change_pct)",
            self.sql,
        )


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
