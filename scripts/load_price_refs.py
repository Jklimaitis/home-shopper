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

### The 30-day window is relative to each row, never to `current_date`

For a row at `ref_date = R`, `min_30d` / `max_30d` are the min and max of the
weighted price over `(R - 30 days, R]` for the SAME
`(user_id, product_id, store_id, base_unit)`. The window ends at `R`, not at
today: `ref_date` spans 2025-09 to 2026-09, so a `current_date` window would
leave `min_30d` / `max_30d` empty for nearly every row -- a silently wrong
result, not a visible error.

### `samples_30d` -- the count the alert threshold needs

`samples_30d` is how many aggregated (day) price points the window held: the
number of values `min_30d` / `max_30d` were taken over. ADR-0003 requires a
MINIMUM number of samples before those columns may drive an alert ("alertar
sobre uma unica compra e ficcao") and leaves that number as a product decision
(internal task). This loader does not decide the number -- it writes the count so
the decision can be applied later. Without it the threshold is undecidable,
because the window is relative to `ref_date` and cannot be recomputed from
`price_refs` once the row is stored (migration `db/013`).

### `var_pct_30d` is left NULL, deliberately

ADR-0003 does not define the formula. The two candidate readings disagree in
sign and in meaning:

  * amplitude:      `(max_30d - min_30d) / min_30d * 100` -- always >= 0.
  * trend:          the newest price against the oldest in the window -- signed.

The panel needs a SIGNED direction (PRD: "variacao sempre com seta", down/up),
which the amplitude cannot express; the trend reading is the one that could, but
which endpoint counts as "the previous price" is a business definition the ADR
never states. This is the same family as the minimum-sample number: a product
decision, not this card's. So the column stays NULL -- never 0 -- rather than
assert a variation no decision authorised. Resolving it is a one-line change
where the `NULL::numeric` below sits.

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
-- price_refs <- v_price_aggregation (ADR-0003 5). Window per row:
-- (ref_date - 30 days, ref_date] for the same (user, product, store, base_unit).
INSERT INTO price_refs
    (user_id, product_id, store_id, ref_date, base_unit,
     base_price, min_30d, max_30d, var_pct_30d, samples_30d, updated_at)
SELECT
    va.user_id,
    va.product_id,
    va.store_id,
    va.ref_date,
    va.base_unit,
    va.weighted_price,
    w.mn,
    w.mx,
    -- var_pct_30d: ADR-0003 does not define the formula; see the module
    -- docstring. NULL, not 0 -- no variation is asserted.
    NULL::numeric,
    w.n::integer,
    now()
FROM v_price_aggregation va
JOIN LATERAL (
    SELECT min(va3.weighted_price) AS mn,
           max(va3.weighted_price) AS mx,
           count(*)               AS n
      FROM v_price_aggregation va3
     WHERE va3.user_id    = va.user_id
       AND va3.product_id = va.product_id
       AND va3.store_id   = va.store_id
       AND va3.base_unit  = va.base_unit
       AND va3.ref_date   > va.ref_date - 30
       AND va3.ref_date  <= va.ref_date
) w ON true
%(user_filter)s\
ON CONFLICT ON CONSTRAINT uk_price_refs_user_product_store_date
DO UPDATE SET
    base_price  = EXCLUDED.base_price,
    base_unit   = EXCLUDED.base_unit,
    min_30d     = EXCLUDED.min_30d,
    max_30d     = EXCLUDED.max_30d,
    samples_30d = EXCLUDED.samples_30d,
    updated_at  = now()
-- Rewrite nothing when the recomputed values are identical: a second run with
-- the same source is a true no-op (command tag INSERT 0 0), and updated_at
-- moves only when a value actually changed.
WHERE (price_refs.base_price, price_refs.base_unit, price_refs.min_30d,
       price_refs.max_30d, price_refs.samples_30d)
      IS DISTINCT FROM
      (EXCLUDED.base_price, EXCLUDED.base_unit, EXCLUDED.min_30d,
       EXCLUDED.max_30d, EXCLUDED.samples_30d);
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
        # After the LATERAL join, before ON CONFLICT.
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
        f"# price_refs batch: {scope}; window (ref_date-30, ref_date] per "
        f"(user, product, store, base_unit); var_pct_30d left NULL (ADR-0003 "
        f"does not define the formula)",
        file=sys.stderr,
    )
    sys.stdout.write("\n".join(statements) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
