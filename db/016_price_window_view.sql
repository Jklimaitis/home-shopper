-- =============================================================================
-- home_shopper -- part 16: the price window becomes a query (decision D10)
-- PostgreSQL 16
-- =============================================================================
-- internal task. Decision D10 (Jonas, 2026-10-05, ratified in the internal task thread)
-- chose OPTION B: the screen presets 7 / 30 / 90 / 180 / 365 days are a FILTER,
-- not a column. `price_refs` keeps the observed price; every aggregate over a
-- window is computed on read. The 30-day columns this replaces answered exactly
-- one preset and would have to be cloned per preset (min_90d, max_90d,
-- samples_90d, ...) -- a schema that grows with the interface.
--
-- WHAT LEAVES `price_refs` AND WHY
--
--   min_30d, max_30d, var_pct_30d   db/002. Window-dependent, one preset each.
--   samples_30d                     db/013. The count that window held.
--   price_spread_pct                db/014 (decision D9). Window-dependent: it
--                                   IS (max-min)/min of the 30-day window.
--
--   All five are the same fact computed for one preset. `v_price_window`
--   computes them for any preset with the same formulas, so keeping them would
--   be a second producer of the same number -- and the only producer that can
--   go stale, because the batch is the writer and a preset the batch does not
--   know about has no column at all.
--
-- WHAT STAYS, AND WHY IT IS NOT A WINDOW
--
--   base_price, base_unit          the observation itself.
--   price_change_pct  db/014 (D9)  the SIGNED change against the IMMEDIATELY
--                                  PREVIOUS observation of the same
--                                  (user, product, store, base_unit) -- a LAG,
--                                  not a window. It answers "did this price
--                                  move since we last saw it", which is true
--                                  whatever preset the screen asks for. dm/023's
--                                  option B kept exactly this column and no
--                                  other. The batch now writes it (see
--                                  scripts/load_price_refs.py) -- before this
--                                  migration only db/014's one-shot backfill
--                                  filled it, so it went stale on the next run.
--
-- NULL IS THE HONEST VALUE -- STILL
--
--   A window holding a single observation has NO variation: max == min and a
--   "spread" would be a division of noise. Both variation columns come out
--   NULL, never 0 -- a 0 there would claim the price did not move, which is a
--   different, unsupported claim. With TWO or more observations a 0.00 IS the
--   honest value when every price in the window is the same (measured on the
--   real rows: it happens, and the self-check does not forbid it).
--   `coverage` says which state the row is in: OK (samples >= 2), INSUFFICIENT
--   (samples = 1) or NO_OBSERVATIONS (the pair has no observation in the window
--   at all). The screen can then say "no observations in the last 90 days"
--   instead of drawing a zero that never happened.
--
-- WHY A VIEW *AND* A FUNCTION, NOT ONE VIEW
--
--   A view cannot take a parameter, and any view MUST bake a preset -- which is
--   exactly what option B rejects. So the two questions get one object each:
--
--     v_price_window   one row per (OBSERVATION x PRESET). Presets are ROWS,
--                      never columns; adding one is adding a VALUES entry, no
--                      ALTER TABLE. Window = the W days ending at that row's
--                      own ref_date, inclusive at both ends: [R-(W-1), R].
--                      That is the interval dm/019 wrote into the columns
--                      ((R-30, R] == [R-29, R]) and it is what makes this view
--                      reproduce them bit for bit.
--
--     price_window()   one row per (product, store) PAIR, window anchored at an
--                      as-of date (default: the user's own latest observation).
--                      The window is a real PARAMETER -- 7 and 365 in the same
--                      query are two calls or two predicates, with no DDL. This
--                      is the shape the screen runs, and it is where a pair
--                      with NO observation in the window can appear at all
--                      (samples = 0), which the per-observation view cannot
--                      express: every row of that view is inside its own window.
--
-- WINDOW ARITHMETIC -- MEASURED, NOT ASSUMED
--
--   [R-(W-1), R] inclusive at both ends. `make_interval(days => W)` gives
--   [R-W, R] = W+1 days: an off-by-one that no type check catches (dm/023 §5,
--   dm/035 §Medicao).
--
--   The card that requested this migration warned that
--   `RANGE BETWEEN INTERVAL 'N days' PRECEDING AND CURRENT ROW` does not exist
--   in PostgreSQL 16. It DOES, when ORDER BY is a `date` (verified here on
--   16.15, pg_proc.in_range(date,date,interval,bool,bool)). It is not used
--   anyway, for a different reason: a window frame's offset is fixed per query,
--   so one query could serve one preset -- the thing D10 rejects. Both objects
--   below take the window from a join, not from a frame.
--
-- GROUP BY (product_id, store_id) -- MEASURED ON THE REAL SCHEMA, WITH ITS
--                                      CONDITION
--
--   The pair key repeats the leading order of BOTH indexes that touch this
--   table -- idx_price_refs_user_product (user_id, product_id, ref_date DESC)
--   and idx_price_refs_lookup (user_id, product_id, store_id, ref_date DESC) --
--   so an ordered index scan feeds the aggregate with product_id already
--   sorted. Measured on 358,400 rows for ONE user (400 products x 8 stores x
--   112 dates, inserted in ref_date order -- the order the batch writes), 1-day
--   window (3,200 of the 358,400 rows kept), EXPLAIN (ANALYZE), best of 3:
--
--     (product_id, store_id)      GroupAggregate <- Incremental Sort 27 kB,
--                                 Presorted Key: product_id <- Index Scan using
--                                 idx_price_refs_user_product          2.7 ms
--     (store_id, product_id)      GroupAggregate <- Sort 322 kB <- Index Scan
--                                 using idx_price_refs_user_product    3.0 ms
--
--   ("forced" = enable_seqscan = off, enable_bitmapscan = off.) Both keys give
--   a GroupAggregate, never a HashAggregate, and the pair key only sorts inside
--   each product (27 kB, 100 groups) where the reversed key sorts the whole
--   window (322 kB). base_unit is in neither index and changes nothing: the
--   second key column needs an incremental sort either way (2.4 ms).
--
--   THE CONDITION -- and it is the settings, not the key, that decide at this
--   selectivity. With DEFAULT settings the planner does not use the index order
--   here: the 1-day window keeps 3,200 rows, so it runs
--   `Parallel Seq Scan -> Sort 127 kB -> Partial/Finalize GroupAggregate`
--   (10.9 ms, best of 3) -- and the SAME shape and time for the reversed key
--   (11.4 ms) and the base_unit key (10.8 ms); product_id alone plans the same
--   way (13.2 ms, single run). Turning parallelism off makes
--   it take the index path, the "forced" plan above (2.7 ms). Widen the window
--   and the streaming stops even with the index forced: 30 days (48,000 rows)
--   plans as HashAggregate, 17.5 ms. idx_price_refs_lookup itself only appears
--   when BOTH key columns are constrained -- the product-detail query:
--   `Index Scan using idx_price_refs_lookup`, 0.05 ms -- because a pure date
--   window has no store_id predicate, and store_id is that index's third
--   column. The shape is what this migration controls; which plan wins is the
--   planner's business.
--
--   (An earlier version of this paragraph claimed an `Index Only Scan` over a
--   benchmark table at 5.5 ms. No index on price_refs contains base_price --
--   the aggregate has to fetch it -- so an Index Only Scan is impossible for
--   this shape, and the table that was measured was not this schema's.)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Views that read the columns being dropped have to go first: a view's
--    dependency on a column blocks the DROP. v_best_price sits on top of
--    v_current_prices, so it goes first.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_best_price;
DROP VIEW IF EXISTS v_current_prices;

-- -----------------------------------------------------------------------------
-- 2. price_refs keeps the observation and the window-INDEPENDENT change.
--    ck_price_refs_samples_30d and ck_price_refs_spread_finite die with their
--    columns; ck_price_refs_change_finite stays, because price_change_pct does.
-- -----------------------------------------------------------------------------
ALTER TABLE price_refs
    DROP COLUMN IF EXISTS min_30d,
    DROP COLUMN IF EXISTS max_30d,
    DROP COLUMN IF EXISTS var_pct_30d,
    DROP COLUMN IF EXISTS samples_30d,
    DROP COLUMN IF EXISTS price_spread_pct;

COMMENT ON COLUMN price_refs.price_change_pct IS
    'Signed change against the IMMEDIATELY PREVIOUS observation of the same '
    '(user_id, product_id, store_id, base_unit) -- a LAG, not a window, so it is '
    'independent of the screen preset. NULL means "not comparable yet"; never 0 '
    '(ck_price_refs_change_finite). Written by scripts/load_price_refs.py.';

-- -----------------------------------------------------------------------------
-- 3. v_current_prices: the latest observation per (user, product, store).
--    The three *_30d columns it used to expose are gone; price_change_pct is
--    exposed instead, because it is the only variation that does not depend on
--    the window (it is the MVP badge, internal task P2).
-- -----------------------------------------------------------------------------
CREATE VIEW v_current_prices AS
SELECT
    pr.user_id,
    pr.product_id,
    p.name          AS product_name,
    p.brand,
    c.name          AS category,
    pr.store_id,
    s.name          AS store_name,
    pr.ref_date,
    pr.base_unit,
    pr.base_price,
    pr.price_change_pct
FROM price_refs pr
JOIN products p       ON p.id = pr.product_id
JOIN stores s         ON s.id = pr.store_id
LEFT JOIN categories c ON c.id = p.category_id
WHERE pr.ref_date = (
    SELECT max(pr2.ref_date)
      FROM price_refs pr2
     WHERE pr2.user_id    = pr.user_id
       AND pr2.product_id = pr.product_id
       AND pr2.store_id   = pr.store_id
);

-- -----------------------------------------------------------------------------
-- 4. v_best_price: rebuilt unchanged in substance, because its base view had to
--    be dropped. It is the between-store comparison the project is named after.
-- -----------------------------------------------------------------------------
CREATE VIEW v_best_price AS
SELECT
    user_id,
    product_id,
    product_name,
    brand,
    category,
    base_unit,
    count(*) AS store_count,
    min(base_price) AS best_price,
    max(base_price) AS worst_price,
    round(
        (max(base_price) - min(base_price))
        / nullif(min(base_price), 0) * 100, 2
    ) AS spread_pct,
    (array_agg(store_id    ORDER BY base_price))[1] AS best_store_id,
    (array_agg(store_name  ORDER BY base_price))[1] AS best_store_name
FROM v_current_prices
GROUP BY user_id, product_id, product_name, brand, category, base_unit
HAVING count(*) > 1;

-- -----------------------------------------------------------------------------
-- 5. v_price_window: one row per (observation x preset).
--
--    The presets are ROWS. `window_days` is a column of the result, so asking
--    for two presets in one query is a predicate, and a new preset is a VALUES
--    entry -- never a new column, never a migration.
--
--    The LATERAL is the index range scan: for each observation, the window is
--    the same (user, product, store, base_unit) key, ref_date in
--    [ref_date-(W-1), ref_date]. Window frames cannot do this: the frame offset
--    is constant per query while W varies with the row (dm/023).
-- -----------------------------------------------------------------------------
CREATE VIEW v_price_window AS
SELECT
    pr.user_id,
    pr.product_id,
    pr.store_id,
    pr.base_unit,
    pr.ref_date,
    p.window_days,
    pr.base_price,
    w.samples,
    w.price_min,
    w.price_max,
    -- A window with a single observation has NO variation. NULL, never 0.
    CASE WHEN w.samples >= 2
         THEN round((w.price_max - w.price_min) / nullif(w.price_min, 0) * 100, 2)
    END AS price_spread_pct,
    CASE WHEN w.samples >= 2 THEN 'OK' ELSE 'INSUFFICIENT' END AS coverage
FROM price_refs pr
JOIN (VALUES (7), (30), (90), (180), (365)) AS p(window_days) ON TRUE
JOIN LATERAL (
    SELECT
        count(*)            AS samples,
        min(pr2.base_price) AS price_min,
        max(pr2.base_price) AS price_max
    FROM price_refs pr2
    WHERE pr2.user_id    = pr.user_id
      AND pr2.product_id = pr.product_id
      AND pr2.store_id   = pr.store_id
      AND pr2.base_unit  = pr.base_unit
      AND pr2.ref_date BETWEEN pr.ref_date - (p.window_days - 1) AND pr.ref_date
) w ON TRUE;

COMMENT ON VIEW v_price_window IS
    'Price window per (observation x screen preset) -- option B of decision D10. '
    'The window is a query, not a column. window_days counts the days ENDING at '
    'ref_date, inclusive at both ends: [ref_date-(window_days-1), ref_date]. '
    'price_spread_pct is NULL when the window holds fewer than 2 observations '
    '(coverage = INSUFFICIENT), never 0. price_change_pct is NOT here: it does '
    'not depend on the window (it lives on price_refs).';

-- -----------------------------------------------------------------------------
-- 6. price_window(): the screen's shape -- one row per (product, store) pair,
--    over the window ending at an as-of date.
--
--    p_as_of defaults to the user's own latest observation: "the last 90 days"
--    means the 90 days ending at the last price we have, not at current_date.
--    A current_date window would empty every historical row silently -- the
--    single most expensive mistake this surface can make (dm/019).
--
--    A pair with NO observation inside the window still comes back, with
--    samples = 0 and coverage = NO_OBSERVATIONS. That is the state the screen
--    has to be able to say out loud ("no observations in the last 90 days")
--    instead of showing an empty panel with no reason.
--
--    The aggregate is keyed (product_id, store_id), in the order of
--    idx_price_refs_lookup. base_unit carries the window's unit; unit_count
--    exposes a pair that held MORE THAN ONE unit in the window -- ADR-0003 1
--    forbids comparing across scales, and a mixed pair is not a comparison.
--    On the 480 real rows unit_count is 1 for every pair (measured).
-- -----------------------------------------------------------------------------
CREATE FUNCTION price_window(
    p_user_id     UUID,
    p_window_days INTEGER,
    p_as_of       DATE DEFAULT NULL
)
RETURNS TABLE (
    product_id       UUID,
    store_id         UUID,
    base_unit        base_unit,
    unit_count       BIGINT,
    as_of            DATE,
    window_days      INTEGER,
    ref_date         DATE,
    base_price       NUMERIC,
    price_change_pct NUMERIC,
    samples          BIGINT,
    price_min        NUMERIC,
    price_max        NUMERIC,
    price_spread_pct NUMERIC,
    coverage         TEXT
)
LANGUAGE sql STABLE AS $$
    WITH bounds AS (
        -- The anchor. Explicit when the caller gives one, otherwise the last
        -- observation this user has. A window shorter than a day is not a
        -- window: it matches nothing and returns no rows.
        SELECT coalesce(
                   p_as_of,
                   (SELECT max(pr.ref_date) FROM price_refs pr
                     WHERE pr.user_id = p_user_id)
               ) AS as_of
         WHERE p_window_days >= 1
    ),
    pairs AS (
        SELECT DISTINCT pr.product_id, pr.store_id
          FROM price_refs pr
         WHERE pr.user_id = p_user_id
    ),
    win AS (
        SELECT
            pr.product_id,
            pr.store_id,
            count(*)                      AS samples,
            min(pr.base_price)            AS price_min,
            max(pr.base_price)            AS price_max,
            count(DISTINCT pr.base_unit)  AS unit_count,
            min(pr.base_unit)             AS base_unit,
            max(pr.ref_date)              AS ref_date,
            (array_agg(pr.base_price ORDER BY pr.ref_date DESC))[1]       AS base_price,
            (array_agg(pr.price_change_pct ORDER BY pr.ref_date DESC))[1] AS price_change_pct
          FROM price_refs pr
          CROSS JOIN bounds b
         WHERE pr.user_id   = p_user_id
           AND b.as_of IS NOT NULL
           AND pr.ref_date  >  b.as_of - p_window_days
           AND pr.ref_date  <= b.as_of
         GROUP BY pr.product_id, pr.store_id
    )
    SELECT
        pp.product_id,
        pp.store_id,
        w.base_unit,
        coalesce(w.unit_count, 0),
        b.as_of,
        p_window_days,
        w.ref_date,
        w.base_price,
        -- Variation needs TWO observations. With fewer, NULL -- never 0.
        CASE WHEN w.samples >= 2 THEN w.price_change_pct END,
        coalesce(w.samples, 0),
        w.price_min,
        w.price_max,
        CASE WHEN w.samples >= 2
             THEN round((w.price_max - w.price_min) / nullif(w.price_min, 0) * 100, 2)
        END,
        CASE
            WHEN w.samples IS NULL THEN 'NO_OBSERVATIONS'
            WHEN w.samples <  2    THEN 'INSUFFICIENT'
            ELSE 'OK'
        END
      FROM pairs pp
      CROSS JOIN bounds b
      LEFT JOIN win w ON w.product_id = pp.product_id AND w.store_id = pp.store_id;
$$;

COMMENT ON FUNCTION price_window(UUID, INTEGER, DATE) IS
    'Windowed price aggregation per (product, store) pair, for ANY window -- '
    'option B of decision D10. Window = the W days ending at p_as_of inclusive '
    'at both ends: [as_of-(W-1), as_of]; p_as_of defaults to the user''s latest '
    'observation. Variation columns are NULL when samples < 2. coverage is '
    'OK / INSUFFICIENT / NO_OBSERVATIONS. p_window_days must be >= 1.';

-- -----------------------------------------------------------------------------
-- 7. Self-check. It has to pass on a database with NO data -- the CI applies
--    db/*.sql to an empty one -- so the structural assertions always run and the
--    data-dependent ones are skipped with a NOTICE when price_refs is empty.
--    (A self-check that demands rows fails a perfectly good schema: dm/033.)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_leftover TEXT;
    v_rows     INTEGER;
    v_bad      INTEGER;
    v_unnamed  TEXT;
BEGIN
    -- (1) No per-preset column can survive. The whole point of D10 option B.
    SELECT string_agg(a.attname || ' (' ||
                      (CASE WHEN a.attname LIKE '%\_30d' THEN 'preset-bound' ELSE 'window-dependent' END) || ')',
                      ', ' ORDER BY a.attname)
      INTO v_leftover
      FROM pg_attribute a
     WHERE a.attrelid = 'price_refs'::regclass
       AND a.attnum > 0
       AND NOT a.attisdropped
       AND a.attname IN ('min_30d', 'max_30d', 'var_pct_30d', 'samples_30d',
                         'price_spread_pct');

    IF v_leftover IS NOT NULL THEN
        RAISE EXCEPTION 'price_refs still carries a per-preset column: %', v_leftover;
    END IF;

    -- (2) The window-independent change must still be there: dropping it would
    --     take the MVP badge with it.
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'price_refs'::regclass
                      AND attname = 'price_change_pct'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'price_refs lost price_change_pct -- it is window-independent';
    END IF;

    -- (3) The preset must be a COLUMN OF THE RESULT, not a column of the table.
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'v_price_window'::regclass
                      AND attname = 'window_days'
                      AND NOT attisdropped) THEN
        RAISE EXCEPTION 'v_price_window does not expose window_days as a column';
    END IF;

    -- (4) The parameterised surface exists with the documented signature.
    IF NOT EXISTS (SELECT 1 FROM pg_proc p
                    JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'public'
                     AND p.proname = 'price_window'
                     AND pg_get_function_arguments(p.oid) =
                         'p_user_id uuid, p_window_days integer, p_as_of date DEFAULT NULL::date') THEN
        RAISE EXCEPTION 'price_window(uuid, integer, date DEFAULT NULL) is missing';
    END IF;

    -- (5) Every constraint still follows the pk_/uk_/ck_/fk_ convention.
    SELECT string_agg(conname, ', ')
      INTO v_unnamed
      FROM pg_constraint c
      JOIN pg_namespace n ON n.oid = c.connamespace
     WHERE n.nspname = 'public'
       AND c.conname !~ '^(pk|uk|ck|fk)_';
    IF v_unnamed IS NOT NULL THEN
        RAISE EXCEPTION 'unnamed constraints after db/016: %', v_unnamed;
    END IF;

    -- (6) Data-dependent: NULL is the honest value, and the split is exact.
    SELECT count(*) INTO v_rows FROM price_refs;
    IF v_rows = 0 THEN
        RAISE NOTICE 'price_refs is empty -- the window assertions are skipped '
                     '(the schema is what this migration checks)';
        RETURN;
    END IF;

    SELECT count(*) INTO v_bad FROM v_price_window
     WHERE (samples >= 2 AND price_spread_pct IS NULL)
        OR (samples <  2 AND price_spread_pct IS NOT NULL);
    IF v_bad > 0 THEN
        RAISE EXCEPTION
            '% rows of v_price_window disagree with samples about price_spread_pct '
            '(a single-sample window must be NULL, never 0)', v_bad;
    END IF;

    -- A 0.00 spread IS honest when the window holds two observations of the
    -- SAME price: "it did not vary" is a claim the data supports. What must
    -- never happen is a 0 standing in for "not measurable", and the check above
    -- already pins that: with fewer than two samples the value is NULL.

    -- (7) Data-dependent: the pair-level surface must reproduce, per pair and
    --     per user, the same window the per-observation view computes at that
    --     pair's latest observation. Two objects, one arithmetic.
    WITH pair_side AS (
        SELECT p.user_id, w.product_id, w.store_id, w.samples, w.price_min, w.price_max
          FROM (
            SELECT pp.user_id, pp.product_id, pp.store_id, last.ref_date
              FROM (SELECT DISTINCT user_id, product_id, store_id FROM price_refs) pp
              JOIN LATERAL (
                  SELECT max(pr.ref_date) AS ref_date FROM price_refs pr
                   WHERE pr.user_id    = pp.user_id
                     AND pr.product_id = pp.product_id
                     AND pr.store_id   = pp.store_id
              ) last ON TRUE
          ) p
          CROSS JOIN LATERAL price_window(p.user_id, 30, p.ref_date) w
         WHERE w.product_id = p.product_id AND w.store_id = p.store_id
    ),
    row_side AS (
        SELECT vw.user_id, vw.product_id, vw.store_id, vw.samples, vw.price_min, vw.price_max
          FROM v_price_window vw
          JOIN (SELECT user_id, product_id, store_id, max(ref_date) AS ref_date
                  FROM price_refs GROUP BY user_id, product_id, store_id) last
            ON last.user_id    = vw.user_id
           AND last.product_id = vw.product_id
           AND last.store_id   = vw.store_id
           AND last.ref_date   = vw.ref_date
         WHERE vw.window_days = 30
    )
    SELECT count(*) INTO v_bad
      FROM pair_side a
      FULL JOIN row_side b
        ON b.user_id = a.user_id AND b.product_id = a.product_id AND b.store_id = a.store_id
     WHERE a.samples   IS DISTINCT FROM b.samples
        OR a.price_min IS DISTINCT FROM b.price_min
        OR a.price_max IS DISTINCT FROM b.price_max;

    IF v_bad > 0 THEN
        RAISE EXCEPTION
            '% pairs where price_window() at the pair''s latest observation '
            'disagrees with v_price_window at 30 days', v_bad;
    END IF;

    RAISE NOTICE 'db/016: price_refs holds only the observation (+ price_change_pct); '
                 'v_price_window and price_window() compute the window on read; '
                 '% rows agree on samples/min/max between both surfaces', v_rows;
END $$;

COMMIT;
