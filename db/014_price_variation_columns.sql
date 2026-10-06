-- =============================================================================
-- home_shopper -- part 14: the two honest variation columns (decision D9)
-- =============================================================================
-- internal task. Decision D9 (Jonas, 2026-10-05) replaced the single, undefined
-- `var_pct_30d` with TWO columns whose names say what they measure.
--
-- WHY TWO AND NOT ONE
--   `var_pct_30d` existed in db/002 with no defined formula and no producer. The
--   ADR-0003 does not define it, so the batch wrote NULL into every row
--   (480/480). Two readings were possible and they diverge in SIGN:
--
--     amplitude  (max - min) / min * 100   -- always >= 0. "it varied X%"
--     change     (now - prev) / prev * 100 -- signed. "it fell 29%"
--
--   Measured on the real rows: a single amplitude cannot drive the arrow. On
--   product <uuid> the price went 0.01259 -> 0.00899 between 2026-06-10 and
--   2026-09-25: a FALL of 28.6%, while the window amplitude reads +20.0%. A UI
--   built on amplitude shows "up" on the day the price fell. Hence:
--
--     price_spread_pct  -- amplitude, no sign, "the price varied X% in 30d"
--     price_change_pct  -- signed change against the IMMEDIATELY PREVIOUS
--                          observation of the same
--                          (user_id, product_id, store_id, base_unit),
--                          NOT the window average.
--
-- NULL IS THE HONEST VALUE
--   price_change_pct needs TWO observations. On this data only 87 of the 480
--   rows have a previous observation; the other 393 stay NULL. NULL means
--   "not comparable yet", which is true -- and a zero would claim the price did
--   not move. The alert spec must treat NULL as "no signal", never as 0%.
--
-- SCOPE OF THIS MIGRATION
--   Schema only. It adds the two columns and backfills what the current rows
--   can honestly carry. The batch (scripts/load_price_refs.py, internal task)
--   keeps writing NULL into `var_pct_30d`, which is left in place: removing it
--   is a separate decision (D10 makes the window a view, and then these two
--   columns become the batch's cache of that view -- see the note at the end).
-- =============================================================================

BEGIN;

ALTER TABLE price_refs
    ADD COLUMN price_spread_pct NUMERIC(8,2);

ALTER TABLE price_refs
    ADD COLUMN price_change_pct NUMERIC(8,2);

ALTER TABLE price_refs
    ADD CONSTRAINT ck_price_refs_spread_finite
        CHECK (price_spread_pct IS NULL OR price_spread_pct >= 0);

ALTER TABLE price_refs
    ADD CONSTRAINT ck_price_refs_change_finite
        CHECK (price_change_pct IS NULL OR price_change_pct <> 0);

-- -----------------------------------------------------------------------------
-- Backfill: the amplitude, per row, from the 30-day window the batch already
-- computed. Only rows whose window actually held more than one price can have
-- a spread -- with a single sample, max == min and the "spread" would be a
-- division of noise.
-- -----------------------------------------------------------------------------
UPDATE price_refs pr
   SET price_spread_pct = round(
           ((pr.max_30d - pr.min_30d) / NULLIF(pr.min_30d, 0) * 100)::numeric, 2)
 WHERE pr.samples_30d > 1
   AND pr.min_30d IS NOT NULL
   AND pr.max_30d IS NOT NULL
   AND pr.min_30d <> 0;

-- -----------------------------------------------------------------------------
-- Backfill: the signed change against the immediately previous observation of
-- the same (user, product, store, unit). LAG over the stored rows, ordered by
-- ref_date, partitioned exactly like the batch's window lookup.
-- -----------------------------------------------------------------------------
WITH prev AS (
    SELECT pr.id,
           LAG(pr.base_price) OVER w AS previous_price
      FROM price_refs pr
    WINDOW w AS (PARTITION BY pr.user_id, pr.product_id, pr.store_id, pr.base_unit
                 ORDER BY pr.ref_date)
)
UPDATE price_refs pr
   SET price_change_pct = round(
           ((pr.base_price - p.previous_price) / NULLIF(p.previous_price, 0) * 100)::numeric, 2)
  FROM prev p
 WHERE p.id = pr.id
   AND p.previous_price IS NOT NULL
   AND p.previous_price <> 0
   AND pr.base_price <> p.previous_price;

-- -----------------------------------------------------------------------------
-- Self-check. A backfill that silently wrote 0 rows is the failure mode worth
-- refusing: the columns would exist, look right, and carry nothing.
--
-- The check must tell "there was NOTHING to backfill" from "the backfill
-- FAILED", and it judges each column against the rows that column could
-- actually have filled -- not against the row count of the whole table:
--
--   v_total = 0                -- price_refs is empty (this migration applied to
--                              -- a new database, which is what the CI does).
--                              -- 0 rows backfilled because there are no rows.
--                              -- NOTICE, no exception: a failure here would be
--                              -- a false alarm on a perfectly applied schema.
--
--   v_window = 0 (with rows)   -- the table has rows but no 30-day window: no
--                              -- row has samples_30d > 1, so no row can carry an
--                              -- amplitude. spread = 0 is the honest count.
--
--   v_window > 0, v_spread = 0 -- rows WITH a window exist and the amplitude
--                              -- backfill filled none of them: a real defect.
--
--   v_pairs = 0 (with rows)    -- no row of the database has a previous
--                              -- observation of the same (user, product, store,
--                              -- unit). A signed change needs TWO observations;
--                              -- with none, change = 0 is honest, not a defect.
--
--   v_pairs > 0, v_change = 0  -- comparable rows exist and none got a change:
--                              -- a real defect.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_total   INTEGER;
    v_window  INTEGER;
    v_spread  INTEGER;
    v_pairs   INTEGER;
    v_change  INTEGER;
BEGIN
    SELECT count(*) INTO v_total FROM price_refs;

    IF v_total = 0 THEN
        RAISE NOTICE 'price_refs is empty -- nothing to backfill';
        RETURN;
    END IF;

    -- Rows the spread backfill above could fill: exactly its WHERE clause.
    SELECT count(*) INTO v_window
      FROM price_refs pr
     WHERE pr.samples_30d > 1
       AND pr.min_30d IS NOT NULL
       AND pr.max_30d IS NOT NULL
       AND pr.min_30d <> 0;

    SELECT count(*) INTO v_spread FROM price_refs WHERE price_spread_pct IS NOT NULL;

    -- Rows with a previous observation of the same (user, product, store, unit)
    -- -- the only rows the signed change can come from. Same partition, same
    -- order as the backfill above.
    WITH prev AS (
        SELECT LAG(pr.base_price) OVER w AS previous_price
          FROM price_refs pr
        WINDOW w AS (PARTITION BY pr.user_id, pr.product_id, pr.store_id, pr.base_unit
                     ORDER BY pr.ref_date)
    )
    SELECT count(*) INTO v_pairs FROM prev WHERE previous_price IS NOT NULL;

    SELECT count(*) INTO v_change FROM price_refs WHERE price_change_pct IS NOT NULL;

    IF v_window > 0 AND v_spread = 0 THEN
        RAISE EXCEPTION
            'price_spread_pct backfilled 0 rows of % -- % rows carry a 30d window',
            v_total, v_window;
    END IF;

    IF v_pairs > 0 AND v_change = 0 THEN
        RAISE EXCEPTION
            'price_change_pct backfilled 0 rows of % -- % rows have a previous observation',
            v_total, v_pairs;
    END IF;

    -- A signed change of exactly 0 would mean "identical price", which is not a
    -- variation. The CHECK forbids it; assert the backfill agrees. Only rows the
    -- backfill actually wrote can be tested.
    IF v_change > 0 AND EXISTS (SELECT 1 FROM price_refs WHERE price_change_pct = 0) THEN
        RAISE EXCEPTION 'price_change_pct holds a 0.00%% row -- forbidden by ck';
    END IF;

    IF v_window = 0 THEN
        RAISE NOTICE 'no row has a 30d window (samples_30d > 1) -- spread 0 is honest';
    END IF;

    IF v_pairs = 0 THEN
        RAISE NOTICE 'no row has a previous observation -- change 0 is honest';
    END IF;

    RAISE NOTICE 'variation backfill: % rows, % window, % spread, % pairs, % change',
        v_total, v_window, v_spread, v_pairs, v_change;
END;
$$;

COMMIT;

-- =============================================================================
-- WHAT THIS DOES NOT DO
--   * It does not populate `var_pct_30d`. That column stays NULL and stays in
--     the table; see the note at the top.
--   * It does not make the UI safe. See internal task: eight rows show a jump
--     above 50%, four of them on the same three June-2026 receipts, and the
--     change column WILL render an arrow for them. One of the eight (CAQUI FUYU
--     on 2026-06-18) was verified against the preserved source and the source
--     agrees: 20.99/KG. The remaining seven are not yet audited.
--   * With decision D10 the window becomes a view and these two columns are the
--     batch's cache of it. They are computed per ref_date row, which is exactly
--     what a view over `price_refs` would recompute; if the view lands, these
--     columns stop being written and the view becomes the single source.
-- =============================================================================
