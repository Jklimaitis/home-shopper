-- =============================================================================
-- home_shopper -- part 11: catalogue coverage after an LGPD erasure
-- PostgreSQL 16
--
-- internal task (D8). Decision: an erasure is accepted to leave the catalogue
-- entry in place. `DELETE FROM users` cascades to `purchase_notes` ->
-- `line_items` and to `price_refs` (both keyed by `user_id`), but `products`
-- has no `user_id` (ADR-0004) and no FK points at `users`, so the product
-- survives -- now with no price and no history.
--
-- This file adds NO column and NO trigger. It is a VIEW on purpose; the
-- reasoning is in docs/decisions/2026-10-05-catalogo-apos-purge.md. The short
-- version:
--
--   * `products` has no `user_id`, so there is no authorship to mark. An
--     `orphan_since` column would have no owner and no writer.
--   * The only event that could write it is a cascade DELETE from `users`.
--     `AFTER DELETE ON line_items` cannot tell "the last holder was erased"
--     from "one line was corrected while another holder remains", and it
--     cannot clear the mark when a different user later buys the same product
--     -- a cache with no invalidation, i.e. a value that drifts.
--   * `has_history` is derivable EXACTLY from rows that already exist, so a
--     stored copy would only add a way to be wrong.
--
-- `has_history = false` IS the orphan marker. Nothing is deleted; the product
-- stays visible and usable, and the panel renders "sem histórico de preço"
-- (PRD 13.8 / F11: partial coverage must be declared, never faked).
--
-- SCOPE NOTE (ADR-0004). Unlike `v_current_prices`/`v_best_price`, this view
-- is deliberately NOT scoped by `user_id`: its whole purpose is to answer the
-- catalogue-level question "does ANY price history survive for this product?",
-- which is what distinguishes an orphan from a healthy entry. It exposes
-- coverage aggregates only -- no price, no user identity, no access key. The
-- residual signal (`last_seen_date`, `stores_count`) is discussed in the
-- decision document so it is a reviewed choice, not an oversight.
-- =============================================================================

BEGIN;

-- Price history = a TRUSTED observation of the product's price:
--   * `line_items` -- a reviewed line of a consolidated note; the store and
--     date come from its `purchase_notes` header;
--   * `price_refs` -- the per-(user, product, store, day) reference price the
--     aggregation job maintains.
-- Both are keyed by `user_id` through their header/owner, so both vanish with
-- the user. `staging_lines.product_id` is NOT counted: staging is untrusted
-- and also cascades with the user, so it is neither history nor a survivor.
CREATE OR REPLACE VIEW v_catalog_coverage AS
WITH observed AS (
    SELECT li.product_id,
           n.store_id,
           n.purchase_date AS observed_on
      FROM line_items li
      JOIN purchase_notes n ON n.id = li.note_id
    UNION ALL
    SELECT pr.product_id,
           pr.store_id,
           pr.ref_date AS observed_on
      FROM price_refs pr
)
SELECT
    p.id                                   AS product_id,
    p.name                                 AS product_name,
    p.base_unit                            AS base_unit,
    -- The orphan marker: true iff at least one trusted observation survives.
    count(o.product_id) > 0                AS has_history,
    -- Most recent observation; NULL when there is none (absence shown as
    -- absence -- never a fabricated date or price).
    max(o.observed_on)                     AS last_seen_date,
    -- Distinct stores the product was seen in across all users. This is the
    -- number the panel needs to say "comparável" (>= 2) or not.
    count(DISTINCT o.store_id)             AS stores_count
FROM products p
LEFT JOIN observed o ON o.product_id = p.id
GROUP BY p.id, p.name, p.base_unit;

COMMIT;
