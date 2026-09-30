-- =============================================================================
-- home_shopper -- part 4: indexes and views
-- PostgreSQL 16
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
-- Catalogue
CREATE INDEX idx_products_category  ON products (category_id);
CREATE INDEX idx_products_brand     ON products (brand) WHERE brand IS NOT NULL;
-- EAN is rare (0 of 42 real line items) but when present it is the
-- strongest key available.
CREATE UNIQUE INDEX uq_products_ean ON products (ean) WHERE ean IS NOT NULL;
-- Trigram index for the search box and for name-based matching.
CREATE INDEX idx_products_name_trgm ON products USING gin (name gin_trgm_ops);

CREATE INDEX idx_synonyms_expands ON synonyms (expands_to);

CREATE INDEX idx_presentations_key     ON presentations (match_key);
CREATE INDEX idx_presentations_product ON presentations (product_id);
CREATE INDEX idx_presentations_unit    ON presentations (product_id, sale_unit);
CREATE INDEX idx_presentations_store   ON presentations (store_id) WHERE store_id IS NOT NULL;

-- Staging
CREATE INDEX idx_staging_receipts_user_status
    ON staging_receipts (user_id, status);
-- Idempotency: reprocessing the same source must not duplicate a receipt.
CREATE UNIQUE INDEX uq_staging_receipts_source
    ON staging_receipts (user_id, source, source_ref_norm)
    WHERE source_ref_norm <> '';
CREATE INDEX idx_staging_lines_receipt ON staging_lines (receipt_id);
-- The review queue: lines that matched no product at all.
CREATE INDEX idx_staging_lines_unmatched
    ON staging_lines (product_id) WHERE product_id IS NULL;
CREATE INDEX idx_staging_lines_presentation ON staging_lines (presentation_id);

-- Trusted layer
CREATE INDEX idx_purchase_notes_user_date
    ON purchase_notes (user_id, purchase_date DESC);
CREATE INDEX idx_purchase_notes_store_date
    ON purchase_notes (store_id, purchase_date DESC);
-- The access key is the natural identity of an NFC-e: one per user.
-- Reprocessing (job retry, re-import) must not duplicate.
CREATE UNIQUE INDEX uq_purchase_notes_access_key
    ON purchase_notes (user_id, access_key) WHERE access_key IS NOT NULL;
CREATE INDEX idx_line_items_note       ON line_items (note_id);
CREATE INDEX idx_line_items_product    ON line_items (product_id);
CREATE INDEX idx_line_items_presentation ON line_items (presentation_id);

-- Analytics
CREATE INDEX idx_price_refs_user_product
    ON price_refs (user_id, product_id, ref_date DESC);
CREATE INDEX idx_price_refs_lookup
    ON price_refs (user_id, product_id, store_id, ref_date DESC);
CREATE INDEX idx_price_alerts_unread
    ON price_alerts (user_id, read, created_at DESC);
CREATE INDEX idx_audit_log_user_time
    ON audit_log (user_id, occurred_at DESC);

-- -----------------------------------------------------------------------------
-- VIEWS
-- -----------------------------------------------------------------------------

-- Latest reference price per (product, store), per user.
--
-- The max() MUST be scoped by (user, product, store). Filtering by product
-- alone returned a single row per product, so the two stores never appeared
-- together -- meaning the between-store comparison, the thing the project
-- is named after, did not exist anywhere in the schema.
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
    pr.min_30d,
    pr.max_30d,
    pr.var_pct_30d
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

-- Cheapest store per product, among the stores the user has bought from.
-- Derived from v_current_prices, so it inherits the (user, product, store)
-- filter. Kept separate because the view above answers "how much in each
-- store" while this one answers "where should I buy".
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

-- Equivalent-basket comparison across stores, as a FUNCTION rather than a
-- view.
--
-- CURRENT_DATE in a view makes the SAME query return a different result
-- tomorrow: no historical reproduction, no stable report, no stable test.
-- The 30-day window is a business decision, so it is a parameter.
-- Grouping by base_unit matters: without it, a MIN across '0.0299 in G'
-- and '29.9 in KG' would compare different scales.
CREATE OR REPLACE FUNCTION compare_baskets(
    p_user_id     UUID,
    p_as_of       DATE,
    p_window_days INTEGER DEFAULT 30
)
RETURNS TABLE (
    product_id    UUID,
    product_name  TEXT,
    base_unit     base_unit,
    store_count   BIGINT,
    best_price    NUMERIC,
    worst_price   NUMERIC,
    spread_pct    NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT
        p.id,
        p.name,
        pr.base_unit,
        count(DISTINCT pr.store_id),
        min(pr.base_price),
        max(pr.base_price),
        round(
            (max(pr.base_price) - min(pr.base_price))
            / nullif(min(pr.base_price), 0) * 100, 2
        )
    FROM price_refs pr
    JOIN products p ON p.id = pr.product_id
    WHERE pr.user_id = p_user_id
      AND pr.ref_date >= p_as_of - make_interval(days => p_window_days)
      AND pr.ref_date <= p_as_of
    GROUP BY p.id, p.name, pr.base_unit
    HAVING count(DISTINCT pr.store_id) > 1;
$$;

-- Monthly spend: personal inflation, per store.
CREATE VIEW v_monthly_spend AS
SELECT
    n.user_id,
    n.store_id,
    s.name AS store_name,
    date_trunc('month', n.purchase_date)::DATE AS month,
    sum(n.amount_paid) AS total_spent,
    count(*)          AS note_count
FROM purchase_notes n
JOIN stores s ON s.id = n.store_id
GROUP BY n.user_id, n.store_id, s.name,
         date_trunc('month', n.purchase_date);

-- The review queue: what needs a human eye.
-- Orders by accounting divergence first, then unmatched lines: a wrong
-- total is worse than a missing name.
--
-- description_raw, store_code and sale_unit are surfaced deliberately.
-- Without them the review screen showed a NULL and the user had no way to
-- decide what to match.
CREATE VIEW v_review_queue AS
SELECT
    sr.id AS staging_receipt_id,
    sr.user_id,
    sr.source,
    sr.status,
    sr.total_gross,
    sr.discount_total,
    sr.amount_paid,
    sr.total_computed,
    sr.divergence_cents,
    s.name AS store_name,
    count(sl.id) FILTER (WHERE sl.product_id IS NULL AND NOT sl.discarded)
        AS unmatched_lines,
    count(sl.id) FILTER (WHERE NOT sl.reviewed AND NOT sl.discarded)
        AS lines_to_review,
    count(sl.id) AS total_lines
FROM staging_receipts sr
LEFT JOIN stores s ON s.id = sr.store_id
-- LEFT JOIN, not JOIN: a receipt with no lines at all (ingestion failure,
-- or an upload the parser could not open) has to show up. With an inner
-- join it vanishes, and that receipt is exactly the one the user needs in
-- order to understand what happened.
LEFT JOIN staging_lines sl ON sl.receipt_id = sr.id
WHERE sr.status IN ('PENDING', 'IN_REVIEW')
GROUP BY sr.id, sr.user_id, sr.source, sr.status, sr.total_gross,
         sr.discount_total, sr.amount_paid, sr.total_computed,
         sr.divergence_cents, s.name
ORDER BY abs(sr.divergence_cents) DESC NULLS LAST,
         count(sl.id) FILTER (WHERE sl.product_id IS NULL) DESC;

COMMIT;
