-- =============================================================================
-- home_shopper -- internal task (D8) proof: the catalogue entry survives an LGPD
-- erasure and is reported as having NO price history.
--
-- internal task hardening: the original fixture proved the orphan case for a
-- product whose only history was a LINE ITEM, and its C4 check ("orphan absent
-- from v_best_price") was vacuously true for `v_best_price` -- that product had
-- no `price_ref`, so it was never in `v_best_price` to begin with (its own C0
-- recorded 0 rows BEFORE the purge). This file adds the missing strong case:
-- a product P2 whose ONLY history is `price_refs` owned by the user being
-- erased, in TWO stores, so it IS in `v_best_price`/`v_current_prices` before
-- the purge (1 and 2 rows) and must be gone after it.
--
-- Run against a THROWAWAY database (never the canonical one):
--   psql -v ON_ERROR_STOP=1 -f db/001..006 -f db/011 -f tests/orphan_visibility_test.sql
--
-- The whole file runs inside one transaction and ends in ROLLBACK: the proof
-- leaves the disposable database exactly as it found it.
--
-- Fixtures, by design:
--   * product P  -- history comes from a LINE ITEM only (user A, one store);
--   * product Q  -- history comes from PRICE REFS of a LIVE user B (two
--                   stores): the control that must survive the purge and that
--                   keeps `v_best_price` populated;
--   * product P2 -- history comes ONLY from PRICE REFS of the user being
--                   erased (user A, two stores): the strong orphan case. It has
--                   NO line item at all, so nothing but the price_refs cascade
--                   can remove it from `v_best_price`/`v_current_prices`;
--   * product P3 -- exists ONLY as a staging line of the LIVE user B, so it is
--                   present before AND after the purge: `has_history` must stay
--                   false because staging is untrusted, not because the erasure
--                   removed the rows.
-- The pre-purge checks are what make the post-purge ones non-vacuous: they
-- assert the orphan IS visible (> 0 rows) before the DELETE, so a view that
-- kept serving it afterwards would fail C3b/C4b instead of passing silently.
--
-- C2's price_refs check was re-scoped from "all price_refs survive" (true only
-- while every ref belonged to a live user) to "the LIVE user's refs survive"
-- plus "the erased user's refs are gone" -- the original assertion cannot hold
-- once the fixture owns refs of the erased user, and the card requires the
-- live user's refs to be checked explicitly. All other checks are unchanged.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE t021_results (
    check_name TEXT,
    observed   TEXT,
    expected   TEXT,
    result     TEXT
) ON COMMIT DROP;

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
INSERT INTO users (name, email) VALUES ('Orphan A', 'orphan.a@example.com');
INSERT INTO users (name, email) VALUES ('Survivor B', 'survivor.b@example.com');

INSERT INTO stores (name, cnpj, ibge_code, trade_name) VALUES
    ('Store One', '11111111111111', '3550308', 'ONE'),
    ('Store Two', '22222222222222', '3550308', 'TWO');

INSERT INTO products (name, brand, base_unit) VALUES
    ('Produto Orfao',      'Marca X', 'UN'),
    ('Produto Comparavel', 'Marca Y', 'UN'),
    ('Produto So Preco',   'Marca Z', 'UN'),
    ('Produto So Staging', 'Marca W', 'UN');

INSERT INTO presentations
    (product_id, sale_unit_recognized, content_kind, content_quantity,
     content_unit, factor_base)
SELECT p.id, 'UN', 'FIXED', 1, 'UN', 1
  FROM products p
 WHERE p.name IN ('Produto Orfao', 'Produto Comparavel',
                  'Produto So Preco', 'Produto So Staging');

-- The store's wording (catalogue, survives the purge).
INSERT INTO presentation_sources
    (presentation_id, store_id, sale_unit, description_raw, description_search,
     match_source, reviewed)
SELECT pr.id, s.id, 'UN', v.descr, v.descr, 'MANUAL', TRUE
  FROM (VALUES
        ('Produto Orfao',      'ONE', 'PRODUTO ORFAO UN'),
        ('Produto Comparavel', 'ONE', 'PRODUTO COMPARAVEL ONE UN'),
        ('Produto Comparavel', 'TWO', 'PRODUTO COMPARAVEL TWO UN'),
        ('Produto So Preco',   'ONE', 'PRODUTO SO PRECO ONE UN'),
        ('Produto So Preco',   'TWO', 'PRODUTO SO PRECO TWO UN'),
        ('Produto So Staging', 'ONE', 'PRODUTO SO STAGING UN')
       ) AS v(pname, store_trade, descr)
  JOIN products p ON p.name = v.pname
  JOIN presentations pr ON pr.product_id = p.id
  JOIN stores s ON s.trade_name = v.store_trade;

-- User A: a consolidated note with ONE line for P. This is P's only history.
INSERT INTO purchase_notes (user_id, store_id, purchase_date, amount_paid)
SELECT (SELECT id FROM users WHERE name='Orphan A'),
       (SELECT id FROM stores WHERE trade_name='ONE'),
       DATE '2026-08-01', 5.00;

INSERT INTO line_items (note_id, product_id, presentation_id, line_no,
                        unit_price, quantity, line_total)
SELECT (SELECT n.id FROM purchase_notes n JOIN users u ON u.id=n.user_id
         WHERE u.name='Orphan A'),
       p.id, pr.id, 1, 5.00, 1, 5.00
  FROM products p JOIN presentations pr ON pr.product_id=p.id
 WHERE p.name='Produto Orfao';

-- User B: no line items, but price refs for Q in TWO stores. This is Q's only
-- history, and what makes v_best_price emit a row. B is NOT erased: the control.
INSERT INTO price_refs (user_id, product_id, store_id, ref_date,
                        base_price, base_unit)
SELECT (SELECT id FROM users WHERE name='Survivor B'),
       p.id, s.id, d.ref_date, d.price, 'UN'
  FROM products p
  CROSS JOIN (VALUES ('ONE', DATE '2026-08-02', 4.90),
                      ('TWO', DATE '2026-08-03', 5.40)) AS d(trade, ref_date, price)
  JOIN stores s ON s.trade_name = d.trade
 WHERE p.name='Produto Comparavel';

-- User A (the one to be erased): price refs for P2 in TWO stores. This is P2's
-- ONLY history -- there is deliberately no line item for P2 anywhere -- and it
-- is what puts P2 in v_current_prices (2 rows) and v_best_price (1 row).
INSERT INTO price_refs (user_id, product_id, store_id, ref_date,
                        base_price, base_unit)
SELECT (SELECT id FROM users WHERE name='Orphan A'),
       p.id, s.id, d.ref_date, d.price, 'UN'
  FROM products p
  CROSS JOIN (VALUES ('ONE', DATE '2026-08-04', 9.10),
                      ('TWO', DATE '2026-08-05', 8.70)) AS d(trade, ref_date, price)
  JOIN stores s ON s.trade_name = d.trade
 WHERE p.name='Produto So Preco';

-- P3 exists only as staging (untrusted capture) of the LIVE user B, so the rows
-- survive the purge and the "staging is not history" claim stays testable after
-- it. presentation_id stays NULL: no reviewed form matched this line.
INSERT INTO staging_receipts (user_id, source, store_id, status)
SELECT (SELECT id FROM users WHERE name='Survivor B'),
       'MANUAL',
       (SELECT id FROM stores WHERE trade_name='ONE'),
       'PENDING';

INSERT INTO staging_lines (receipt_id, line_no, description_raw, sale_unit,
                           quantity, unit_price, line_total, product_id,
                           match_source, reviewed)
SELECT (SELECT sr.id FROM staging_receipts sr JOIN users u ON u.id=sr.user_id
         WHERE u.name='Survivor B'),
       1, 'PRODUTO SO STAGING UN', 'UN', 1, 3.30, 3.30,
       (SELECT id FROM products WHERE name='Produto So Staging'),
       'DESCRIPTION', FALSE;

-- -----------------------------------------------------------------------------
-- C0 -- control: BEFORE the purge, both original products have history
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C0 coverage before purge: orphan',
       (SELECT has_history::text FROM v_catalog_coverage
         WHERE product_name='Produto Orfao'), 'true',
       CASE WHEN (SELECT has_history FROM v_catalog_coverage
                   WHERE product_name='Produto Orfao') THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0 coverage before purge: comparable',
       (SELECT has_history::text FROM v_catalog_coverage
         WHERE product_name='Produto Comparavel'), 'true',
       CASE WHEN (SELECT has_history FROM v_catalog_coverage
                   WHERE product_name='Produto Comparavel') THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0 orphan stores_count before purge',
       (SELECT stores_count::text FROM v_catalog_coverage
         WHERE product_name='Produto Orfao'), '1',
       CASE WHEN (SELECT stores_count FROM v_catalog_coverage
                   WHERE product_name='Produto Orfao') = 1 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0 comparable stores_count before purge',
       (SELECT stores_count::text FROM v_catalog_coverage
         WHERE product_name='Produto Comparavel'), '2',
       CASE WHEN (SELECT stores_count FROM v_catalog_coverage
                   WHERE product_name='Produto Comparavel') = 2 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0 v_best_price has the 2-store product',
       (SELECT count(*)::text FROM v_best_price
         WHERE product_name='Produto Comparavel'), '1',
       CASE WHEN (SELECT count(*) FROM v_best_price
                   WHERE product_name='Produto Comparavel') = 1 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0 v_best_price has NO orphan (single store)',
       (SELECT count(*)::text FROM v_best_price
         WHERE product_name='Produto Orfao'), '0',
       CASE WHEN (SELECT count(*) FROM v_best_price
                   WHERE product_name='Produto Orfao') = 0 THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C0b -- the STRONG case, BEFORE the purge: the price-refs-only product is
--        really visible today, and its refs really belong to the user that is
--        about to be erased. Without these > 0 assertions the C3b/C4b checks
--        below would be vacuous (the defect this card fixes).
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C0b P2 has NO line_items (its only history is price_refs)',
       (SELECT count(*)::text FROM line_items li
          JOIN products p ON p.id=li.product_id
         WHERE p.name='Produto So Preco'), '0',
       CASE WHEN (SELECT count(*) FROM line_items li
                    JOIN products p ON p.id=li.product_id
                   WHERE p.name='Produto So Preco') = 0 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0b P2 price_refs belong to the user to be erased',
       (SELECT count(*)::text FROM price_refs pr
          JOIN products p ON p.id=pr.product_id
          JOIN users u ON u.id=pr.user_id
         WHERE p.name='Produto So Preco' AND u.name='Orphan A'), '2',
       CASE WHEN (SELECT count(*) FROM price_refs pr
                    JOIN products p ON p.id=pr.product_id
                    JOIN users u ON u.id=pr.user_id
                   WHERE p.name='Produto So Preco' AND u.name='Orphan A') = 2
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0b P2 in v_best_price before purge (1 row)',
       (SELECT count(*)::text FROM v_best_price
         WHERE product_name='Produto So Preco'), '1',
       CASE WHEN (SELECT count(*) FROM v_best_price
                   WHERE product_name='Produto So Preco') = 1 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0b P2 in v_current_prices before purge (2 rows)',
       (SELECT count(*)::text FROM v_current_prices
         WHERE product_name='Produto So Preco'), '2',
       CASE WHEN (SELECT count(*) FROM v_current_prices
                   WHERE product_name='Produto So Preco') = 2 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0b P2 coverage before purge: has_history',
       (SELECT has_history::text FROM v_catalog_coverage
         WHERE product_name='Produto So Preco'), 'true',
       CASE WHEN (SELECT has_history FROM v_catalog_coverage
                   WHERE product_name='Produto So Preco') THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C0b P2 stores_count before purge',
       (SELECT stores_count::text FROM v_catalog_coverage
         WHERE product_name='Produto So Preco'), '2',
       CASE WHEN (SELECT stores_count FROM v_catalog_coverage
                   WHERE product_name='Produto So Preco') = 2 THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C0c -- control: staging-only P3 is NOT history even before the purge, while
--        its staging rows are demonstrably present (C7 re-checks after).
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C0c staging-only product has_history = false (before purge)',
       (SELECT has_history::text FROM v_catalog_coverage
         WHERE product_name='Produto So Staging'), 'false',
       CASE WHEN NOT (SELECT has_history FROM v_catalog_coverage
                       WHERE product_name='Produto So Staging') THEN 'PASS' ELSE 'FAIL' END;

-- Capture counts BEFORE the purge (the "contagem antes").
CREATE TEMP TABLE t021_before
ON COMMIT DROP
AS
SELECT (SELECT count(*) FROM products)       AS products,
       (SELECT count(*) FROM presentations)  AS presentations,
       (SELECT count(*) FROM line_items)     AS line_items,
       (SELECT count(*) FROM purchase_notes) AS notes,
       (SELECT count(*) FROM price_refs)     AS price_refs,
       -- Refs owned by a LIVE user: they must survive the erasure.
       (SELECT count(*) FROM price_refs pr JOIN users u ON u.id = pr.user_id
         WHERE u.name = 'Survivor B')        AS live_price_refs,
       -- Refs of P2, whose only history is refs of the erased user.
       (SELECT count(*) FROM price_refs pr JOIN products p ON p.id = pr.product_id
         WHERE p.name = 'Produto So Preco')  AS p2_price_refs,
       (SELECT count(*) FROM staging_lines)  AS staging_lines;

-- -----------------------------------------------------------------------------
-- The erasure, exactly as the LGPD path prescribes: the proof row first, then
-- DELETE FROM users (cascades notes -> lines, and price_refs).
-- -----------------------------------------------------------------------------
INSERT INTO data_erasure_requests (user_id, email, reason)
SELECT id, email, 'internal task proof'
  FROM users WHERE name='Orphan A';

DELETE FROM users WHERE name='Orphan A';

-- -----------------------------------------------------------------------------
-- C1 -- the orphan product SURVIVES (count before == after)
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C1 orphan product survives',
       (SELECT count(*)::text FROM products WHERE name='Produto Orfao'), '1',
       CASE WHEN (SELECT count(*) FROM products WHERE name='Produto Orfao') = 1
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C1 total products unchanged',
       (SELECT count(*)::text FROM products), (SELECT products::text FROM t021_before),
       CASE WHEN (SELECT count(*) FROM products) = (SELECT products FROM t021_before)
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C1 orphan presentation survives',
       (SELECT count(*)::text FROM presentations pr JOIN products p ON p.id=pr.product_id
         WHERE p.name='Produto Orfao'), '1',
       CASE WHEN (SELECT count(*) FROM presentations pr JOIN products p ON p.id=pr.product_id
                   WHERE p.name='Produto Orfao') = 1 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C1 orphan wording survives',
       (SELECT count(*)::text FROM presentation_sources ps
          JOIN presentations pr ON pr.id=ps.presentation_id
          JOIN products p ON p.id=pr.product_id
         WHERE p.name='Produto Orfao'), '1',
       CASE WHEN (SELECT count(*) FROM presentation_sources ps
                    JOIN presentations pr ON pr.id=ps.presentation_id
                    JOIN products p ON p.id=pr.product_id
                   WHERE p.name='Produto Orfao') = 1 THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C1b -- the price-refs-only orphan SURVIVES as a catalogue entry too: losing
--        all history must not delete the product, its form or the store wording.
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C1b P2 product survives the purge',
       (SELECT count(*)::text FROM products WHERE name='Produto So Preco'), '1',
       CASE WHEN (SELECT count(*) FROM products WHERE name='Produto So Preco') = 1
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C1b P2 presentation survives the purge',
       (SELECT count(*)::text FROM presentations pr JOIN products p ON p.id=pr.product_id
         WHERE p.name='Produto So Preco'), '1',
       CASE WHEN (SELECT count(*) FROM presentations pr JOIN products p ON p.id=pr.product_id
                   WHERE p.name='Produto So Preco') = 1 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C1b P2 wording survives the purge (both stores)',
       (SELECT count(*)::text FROM presentation_sources ps
          JOIN presentations pr ON pr.id=ps.presentation_id
          JOIN products p ON p.id=pr.product_id
         WHERE p.name='Produto So Preco'), '2',
       CASE WHEN (SELECT count(*) FROM presentation_sources ps
                    JOIN presentations pr ON pr.id=ps.presentation_id
                    JOIN products p ON p.id=pr.product_id
                   WHERE p.name='Produto So Preco') = 2 THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C2 -- the erasure removed the purchase data (contagem antes/depois)
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C2 line_items removed (before -> after)',
       (SELECT line_items::text FROM t021_before) || ' -> ' || (SELECT count(*)::text FROM line_items),
       '1 -> 0',
       CASE WHEN (SELECT line_items FROM t021_before) = 1
             AND (SELECT count(*) FROM line_items) = 0 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C2 purchase_notes removed (before -> after)',
       (SELECT notes::text FROM t021_before) || ' -> ' || (SELECT count(*)::text FROM purchase_notes),
       '1 -> 0',
       CASE WHEN (SELECT notes FROM t021_before) = 1
             AND (SELECT count(*) FROM purchase_notes) = 0 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C2 price_refs total (before -> after)',
       (SELECT price_refs::text FROM t021_before) || ' -> ' || (SELECT count(*)::text FROM price_refs),
       '4 -> 2',
       CASE WHEN (SELECT price_refs FROM t021_before) = 4
             AND (SELECT count(*) FROM price_refs) = 2 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C2 live user price_refs survive (before -> after)',
       (SELECT live_price_refs::text FROM t021_before) || ' -> ' ||
       (SELECT count(*)::text FROM price_refs pr JOIN users u ON u.id=pr.user_id
         WHERE u.name='Survivor B'),
       '2 -> 2',
       CASE WHEN (SELECT count(*) FROM price_refs pr JOIN users u ON u.id=pr.user_id
                   WHERE u.name='Survivor B') = (SELECT live_price_refs FROM t021_before)
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C2 erased user price_refs removed (before -> after)',
       (SELECT p2_price_refs::text FROM t021_before) || ' -> ' ||
       (SELECT count(*)::text FROM price_refs pr JOIN products p ON p.id=pr.product_id
         WHERE p.name='Produto So Preco'),
       '2 -> 0',
       CASE WHEN (SELECT p2_price_refs FROM t021_before) = 2
             AND (SELECT count(*) FROM price_refs pr JOIN products p ON p.id=pr.product_id
                   WHERE p.name='Produto So Preco') = 0 THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C3 -- v_catalog_coverage reports the orphan with has_history = false
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C3 orphan has_history = false',
       (SELECT has_history::text FROM v_catalog_coverage WHERE product_name='Produto Orfao'),
       'false',
       CASE WHEN NOT (SELECT has_history FROM v_catalog_coverage
                       WHERE product_name='Produto Orfao') THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C3 orphan stores_count = 0',
       (SELECT stores_count::text FROM v_catalog_coverage WHERE product_name='Produto Orfao'),
       '0',
       CASE WHEN (SELECT stores_count FROM v_catalog_coverage
                   WHERE product_name='Produto Orfao') = 0 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C3 orphan last_seen_date IS NULL',
       coalesce((SELECT last_seen_date::text FROM v_catalog_coverage
                  WHERE product_name='Produto Orfao'), 'NULL'), 'NULL',
       CASE WHEN (SELECT last_seen_date FROM v_catalog_coverage
                   WHERE product_name='Produto Orfao') IS NULL THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C3 comparable product still has history',
       (SELECT has_history::text FROM v_catalog_coverage
         WHERE product_name='Produto Comparavel'), 'true',
       CASE WHEN (SELECT has_history FROM v_catalog_coverage
                   WHERE product_name='Produto Comparavel') THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C3b -- the price-refs-only orphan is reported with NO history after the purge
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C3b P2 has_history = false',
       (SELECT has_history::text FROM v_catalog_coverage WHERE product_name='Produto So Preco'),
       'false',
       CASE WHEN NOT (SELECT has_history FROM v_catalog_coverage
                       WHERE product_name='Produto So Preco') THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C3b P2 stores_count = 0',
       (SELECT stores_count::text FROM v_catalog_coverage WHERE product_name='Produto So Preco'),
       '0',
       CASE WHEN (SELECT stores_count FROM v_catalog_coverage
                   WHERE product_name='Produto So Preco') = 0 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C3b P2 last_seen_date IS NULL',
       coalesce((SELECT last_seen_date::text FROM v_catalog_coverage
                  WHERE product_name='Produto So Preco'), 'NULL'), 'NULL',
       CASE WHEN (SELECT last_seen_date FROM v_catalog_coverage
                   WHERE product_name='Produto So Preco') IS NULL THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C4 -- the orphan is absent from v_best_price and v_current_prices
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C4 orphan absent from v_best_price (0 rows, no error)',
       (SELECT count(*)::text FROM v_best_price WHERE product_name='Produto Orfao'), '0',
       CASE WHEN (SELECT count(*) FROM v_best_price WHERE product_name='Produto Orfao') = 0
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C4 orphan absent from v_current_prices (0 rows)',
       (SELECT count(*)::text FROM v_current_prices WHERE product_name='Produto Orfao'), '0',
       CASE WHEN (SELECT count(*) FROM v_current_prices WHERE product_name='Produto Orfao') = 0
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C4 no price was invented for the orphan',
       coalesce((SELECT best_price::text FROM v_best_price WHERE product_name='Produto Orfao'), 'NULL'),
       'NULL',
       CASE WHEN (SELECT best_price FROM v_best_price WHERE product_name='Produto Orfao') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C4 comparable product still comparable',
       (SELECT count(*)::text FROM v_best_price WHERE product_name='Produto Comparavel'), '1',
       CASE WHEN (SELECT count(*) FROM v_best_price WHERE product_name='Produto Comparavel') = 1
            THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C4b -- the price-refs-only orphan is absent from both price views. THIS is the
--        non-vacuous version of C4: C0b proved it had 1 and 2 rows before the
--        purge, so 0 here can only mean the cascade removed the refs.
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C4b P2 absent from v_best_price (0 rows, no error)',
       (SELECT count(*)::text FROM v_best_price WHERE product_name='Produto So Preco'), '0',
       CASE WHEN (SELECT count(*) FROM v_best_price WHERE product_name='Produto So Preco') = 0
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C4b P2 absent from v_current_prices (0 rows)',
       (SELECT count(*)::text FROM v_current_prices WHERE product_name='Produto So Preco'), '0',
       CASE WHEN (SELECT count(*) FROM v_current_prices WHERE product_name='Produto So Preco') = 0
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C4b no price was invented for P2',
       coalesce((SELECT best_price::text FROM v_best_price WHERE product_name='Produto So Preco'), 'NULL'),
       'NULL',
       CASE WHEN (SELECT best_price FROM v_best_price WHERE product_name='Produto So Preco') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C5 -- the orphan is REUSABLE: a new user buys the same product and the view
--       reports history again, with NO write to `products`.
-- This is the card's own scenario ("outro usuário pode fazer o match e ganhar
-- comparação") and, at the same time, the proof that a STORED marker would be
-- wrong: a cached `orphan_since` would still say "orphan" here, because nothing
-- fires on the insert to clear it.
-- -----------------------------------------------------------------------------
INSERT INTO users (name, email) VALUES ('New Buyer C', 'buyer.c@example.com');

INSERT INTO purchase_notes (user_id, store_id, purchase_date, amount_paid)
SELECT (SELECT id FROM users WHERE name='New Buyer C'),
       (SELECT id FROM stores WHERE trade_name='TWO'),
       DATE '2026-09-10', 5.20;

INSERT INTO line_items (note_id, product_id, presentation_id, line_no,
                        unit_price, quantity, line_total)
SELECT (SELECT n.id FROM purchase_notes n JOIN users u ON u.id=n.user_id
         WHERE u.name='New Buyer C'),
       p.id, pr.id, 1, 5.20, 1, 5.20
  FROM products p JOIN presentations pr ON pr.product_id=p.id
 WHERE p.name='Produto Orfao';

INSERT INTO t021_results
SELECT 'C5 reused orphan has_history back to true (no writer)',
       (SELECT has_history::text FROM v_catalog_coverage WHERE product_name='Produto Orfao'),
       'true',
       CASE WHEN (SELECT has_history FROM v_catalog_coverage
                   WHERE product_name='Produto Orfao') THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C5 reused orphan stores_count reflects the new store',
       (SELECT stores_count::text FROM v_catalog_coverage WHERE product_name='Produto Orfao'), '1',
       CASE WHEN (SELECT stores_count FROM v_catalog_coverage
                   WHERE product_name='Produto Orfao') = 1 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C5 reused orphan last_seen_date is the new purchase',
       (SELECT last_seen_date::text FROM v_catalog_coverage WHERE product_name='Produto Orfao'),
       '2026-09-10',
       CASE WHEN (SELECT last_seen_date FROM v_catalog_coverage
                   WHERE product_name='Produto Orfao') = DATE '2026-09-10'
            THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C6 -- NO migration was needed: db/011 added no column and no trigger
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C6 products has no orphan marker column',
       (SELECT count(*)::text FROM information_schema.columns
         WHERE table_name='products' AND column_name LIKE '%orphan%'), '0',
       CASE WHEN (SELECT count(*) FROM information_schema.columns
                   WHERE table_name='products' AND column_name LIKE '%orphan%') = 0
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C6 products keeps only its own touch trigger',
       (SELECT count(*)::text FROM pg_trigger
         WHERE tgrelid='products'::regclass AND NOT tgisinternal), '1',
       CASE WHEN (SELECT count(*) FROM pg_trigger
                   WHERE tgrelid='products'::regclass AND NOT tgisinternal) = 1
            THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C6 v_catalog_coverage is a VIEW',
       (SELECT count(*)::text FROM pg_views WHERE viewname='v_catalog_coverage'), '1',
       CASE WHEN (SELECT count(*) FROM pg_views WHERE viewname='v_catalog_coverage') = 1
            THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- C7 -- staging is NOT trusted history (db/011 counts line_items + price_refs).
-- P3's staging receipt belongs to the LIVE user B, so the rows are still there
-- after the purge (asserted below): has_history stays false for the right
-- reason -- staging is untrusted -- and not because the erasure emptied it.
-- -----------------------------------------------------------------------------
INSERT INTO t021_results
SELECT 'C7 staging-only product has_history = false (after purge)',
       (SELECT has_history::text FROM v_catalog_coverage
         WHERE product_name='Produto So Staging'), 'false',
       CASE WHEN NOT (SELECT has_history FROM v_catalog_coverage
                       WHERE product_name='Produto So Staging') THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C7 staging-only product stores_count = 0',
       (SELECT stores_count::text FROM v_catalog_coverage
         WHERE product_name='Produto So Staging'), '0',
       CASE WHEN (SELECT stores_count FROM v_catalog_coverage
                   WHERE product_name='Produto So Staging') = 0 THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C7 staging-only product last_seen_date IS NULL',
       coalesce((SELECT last_seen_date::text FROM v_catalog_coverage
                  WHERE product_name='Produto So Staging'), 'NULL'), 'NULL',
       CASE WHEN (SELECT last_seen_date FROM v_catalog_coverage
                   WHERE product_name='Produto So Staging') IS NULL THEN 'PASS' ELSE 'FAIL' END;

INSERT INTO t021_results
SELECT 'C7 staging line survives the purge (live user, before -> after)',
       (SELECT staging_lines::text FROM t021_before) || ' -> ' || (SELECT count(*)::text FROM staging_lines),
       '1 -> 1',
       CASE WHEN (SELECT staging_lines FROM t021_before) = 1
             AND (SELECT count(*) FROM staging_lines) = 1 THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- Report -- expected: 49 checks, ALL PASS (see the TOTAL row below).
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- internal task: orphan visibility after an LGPD erasure ---'
SELECT check_name, observed, expected, result FROM t021_results ORDER BY check_name;

SELECT 'TOTAL' AS check_name,
       count(*) FILTER (WHERE result='PASS')::text || '/' || count(*)::text AS observed,
       'all PASS' AS expected,
       CASE WHEN count(*) FILTER (WHERE result='FAIL') = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM t021_results;

ROLLBACK;
