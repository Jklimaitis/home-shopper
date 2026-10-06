#!/usr/bin/env python3
"""Generate the SQL that populates `price_refs` from the trusted layer.

Why this file exists
--------------------
`price_refs` is populated by a JOB, not by a trigger (ADR-0003 5). The schema
said so since 002 and nothing ever wrote it, so `v_current_prices`,
`v_best_price` and `v_monthly_spend` -- the three views the comparison panel
reads -- returned zero rows (technical validation 2026-10-05, finding A-1). This
loader is that job's writer: it turns `v_price_aggregation` into `price_refs`.

The contract of the job, fixed here
-----------------------------------
Source: `v_price_aggregation` -- one row per
`(user_id, product_id, store_id, ref_date, base_unit)`, price =
`sum(base_price * quantity) / sum(quantity)`, the quantity-WEIGHTED average
(ADR-0003 5). Target: `price_refs`, keyed on
`uk_price_refs_user_product_store_date (user_id, product_id, store_id, ref_date)`.

`base_price` is the weighted price for that key. The row's `base_unit` is the
unit that price is expressed in and is part of the window: a `min()` across
`0,0299 in G` and `29,9 in KG` would compare different scales (ADR-0003 1), and
this schema has no `KG`/`L` at all for that reason.

### `price_refs` holds the OBSERVATION, and the window is a query (decision D10)

Decision D10 (Jonas, 2026-10-05) made the 7/30/90/180/365-day window a SCREEN
FILTER, not a column, and `db/016` carries that out: the five per-preset columns
(`min_30d`, `max_30d`, `var_pct_30d`, `samples_30d`, `price_spread_pct`) are
gone. Every aggregate over a window is computed on read by `v_price_window` (one
row per observation x preset) and by `price_window()` (one row per product/store
pair, window as a parameter).

That is why this batch no longer carries the 30-day LATERAL: writing
`min_30d`/`max_30d`/`samples_30d` would be a second producer of a number the
view already computes -- and the only one that can go stale, since it would know
exactly one preset. What remains is the price a person actually paid.

### `price_change_pct` -- written here, and NOT a window

The one derived value that stays is the signed change against the IMMEDIATELY
PREVIOUS observation of the same `(user_id, product_id, store_id, base_unit)`
(decision D9, `db/014`). It is a `LAG`, not a window: it answers "did this price
move since we last saw it", a fact that is true whatever preset the screen asks
for. It is the MVP badge (internal task P2), and before this change only db/014's
one-shot backfill filled it -- so it went stale on the next batch run.

NULL is the honest value: it means "not comparable yet" (no previous
observation, or the previous price is 0). A signed change of exactly 0 would
mean "the price is identical", which is NOT a variation, and
`ck_price_refs_change_finite` forbids it -- so an unchanged price is written as
NULL, never 0.

Idempotency
-----------
Re-running the loader changes nothing. The insert is keyed on the unique
constraint; `ON CONFLICT ... DO UPDATE` carries a `WHERE` that compares every
value the batch owns, so a row whose recomputed values are identical is not
updated at all -- the command tag is `INSERT 0 0`, `updated_at` does not move,
and the table checksum is unchanged. This is stricter than "no new rows": a
re-run with the same inputs rewrites zero rows.

Output -- SQL on stdout, applied with the same client the README documents:

    python3 scripts/load_price_refs.py | docker compose exec -T db \\
        psql -U home_shopper -d home_shopper -v ON_ERROR_STOP=1

Nothing here is personal data -- the batch reads no receipt and writes no access
key -- so the SQL is plain and safe to log. For the canonical database the run
still needs Jonas's go (internal task): prove it on a disposable base first.
"""
from __future__ import annotations

import argparse
import re
import sys

# The batch. `%(user_filter)s` is replaced for --user-id; empty by default.
BATCH_SQL = """\
-- price_refs <- v_price_aggregation (ADR-0003 5). The observation and the
-- window-INDEPENDENT change (D9); no 30-day window any more (D10, db/016).
INSERT INTO price_refs
    (user_id, product_id, store_id, ref_date, base_unit,
     base_price, price_change_pct, updated_at)
SELECT
    va.user_id,
    va.product_id,
    va.store_id,
    va.ref_date,
    va.base_unit,
    va.weighted_price,
    -- Signed change against the previous observation of the same
    -- (user, product, store, unit). NULL when there is nothing to compare
    -- against, and NULL (never 0) when the price did not move:
    -- ck_price_refs_change_finite forbids a 0 that would claim a variation.
    CASE
        WHEN va.prev_price IS NULL
          OR va.prev_price = 0
          OR va.weighted_price = va.prev_price THEN NULL
        ELSE round(((va.weighted_price - va.prev_price)
                    / va.prev_price * 100)::numeric, 2)
    END,
    now()
FROM (
    SELECT
        va0.user_id,
        va0.product_id,
        va0.store_id,
        va0.ref_date,
        va0.base_unit,
        va0.weighted_price,
        lag(va0.weighted_price) OVER w AS prev_price
    FROM v_price_aggregation va0
    WINDOW w AS (PARTITION BY va0.user_id, va0.product_id, va0.store_id, va0.base_unit
                 ORDER BY va0.ref_date)
) va
%(user_filter)s\
ON CONFLICT ON CONSTRAINT uk_price_refs_user_product_store_date
DO UPDATE SET
    base_price       = EXCLUDED.base_price,
    base_unit        = EXCLUDED.base_unit,
    price_change_pct = EXCLUDED.price_change_pct,
    updated_at       = now()
-- Rewrite nothing when the recomputed values are identical: a second run with
-- the same source is a true no-op (command tag INSERT 0 0), and updated_at
-- moves only when a value actually changed.
WHERE (price_refs.base_price, price_refs.base_unit, price_refs.price_change_pct)
      IS DISTINCT FROM
      (EXCLUDED.base_price, EXCLUDED.base_unit, EXCLUDED.price_change_pct);
"""

_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def build_sql(user_id: str | None) -> str:
    """Return the batch statements, optionally scoped to one user."""
    if user_id is None:
        user_filter = ""
    else:
        if not _UUID_RE.match(user_id):
            raise SystemExit(f"error: --user-id is not a UUID: {user_id!r}")
        # On the subquery that already computed the lag, before ON CONFLICT.
        user_filter = f"WHERE va.user_id = '{user_id}'::uuid\n"
    return BATCH_SQL % {"user_filter": user_filter}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate the SQL that populates price_refs "
                    "(line_items -> v_price_aggregation -> price_refs)."
    )
    parser.add_argument("--user-id", default=None,
                        help="restrict the batch to one user (default: all)")
    parser.add_argument("--no-transaction", dest="transaction",
                        action="store_false",
                        help="emit bare statements (no BEGIN/COMMIT)")
    args = parser.parse_args()

    statements = []
    if args.transaction:
        statements.append("BEGIN;")
    statements.append(build_sql(args.user_id))
    if args.transaction:
        statements.append("COMMIT;")

    scope = f"user {args.user_id}" if args.user_id else "all users"
    print(
        f"# price_refs batch: {scope}; writes the observed price and "
        f"price_change_pct (previous observation of the same key); the window "
        f"is a query (D10, db/016)",
        file=sys.stderr,
    )
    sys.stdout.write("\n".join(statements) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
