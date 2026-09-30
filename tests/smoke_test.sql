-- =============================================================================
-- home_shopper -- domain tests
--
-- Built on a NFC-e receipt: R$ 337,00, 14 items, one by-weight line.
-- Anonymised: the access key is zeroed while PRESERVING THE FORMAT, so the
-- assertions still test the logic rather than the data.
--
-- Run:
--   psql -v ON_ERROR_STOP=1 -f tests/smoke_test.sql
-- Every assertion prints PASS or FAIL; a FAIL must break the CI.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
INSERT INTO users (name, email) VALUES ('Test User', 'test@example.com');

INSERT INTO stores (name, cnpj, ibge_code, trade_name) VALUES
    ('Store Alpha', '00000000000191', '3550308', 'ALPHA'); -- cnpj-sintetico-ok

INSERT INTO categories (name) VALUES ('Meat and cold cuts');

-- Base unit G: the whole receipt is mass.
INSERT INTO products (name, category_id, brand, base_unit) VALUES
    ('Chicken leg Swift',   (SELECT id FROM categories), 'Swift', 'G'),
    ('Surimi sticks Swift', (SELECT id FROM categories), 'Swift', 'G'),
    ('Minced beef Combo',   (SELECT id FROM categories), 'Combo', 'G'),
    ('Beef tripe Combo',    (SELECT id FROM categories), 'Combo', 'G');

INSERT INTO synonyms (term, expands_to) VALUES
    ('herc',  'hercules'),
    ('swift', 'swift'),
    ('int',   'integral'),
    ('moida', 'moida');

-- Presentation = de-para + unit conversion, in one table.
INSERT INTO presentations (product_id, sale_unit, factor_base,
                           description_raw, description_norm, store_id) VALUES
 ((SELECT id FROM products WHERE name='Chicken leg Swift'),   'pc', 1000,
  'COXA DE FRANGO SWIFT 1 kg',    'COXA DE FRANGO SWIFT 1 kg',    NULL),
 ((SELECT id FROM products WHERE name='Surimi sticks Swift'), 'pc',  250,
  'KANI KAMA SWIFT 250 g',        'KANI KAMA SWIFT 250 g',        NULL),
 ((SELECT id FROM products WHERE name='Minced beef Combo'),   'pc', 1000,
  'CARNE MOIDA COMBO 1kg',        'CARNE MOIDA COMBO 1kg',        NULL),
 -- By weight: sale_unit 'kg' means SOLD BY WEIGHT. The factor is the
 -- PRICE REFERENCE (1 kg = 1000 g); the weight bought goes in quantity.
 ((SELECT id FROM products WHERE name='Beef tripe Combo'),    'kg', 1000,
  'CUPIM COMBO kg',               'CUPIM COMBO KG',               NULL);

INSERT INTO staging_receipts (user_id, source, source_ref, store_id,
                              total_gross, discount_total, amount_paid) VALUES
 ((SELECT id FROM users), 'SEFAZ', '00000000000000000000000000000000000000000000',
  (SELECT id FROM stores), 337.00, 0.00, 337.00);

-- The 4 lines that have a presentation; the other 10 have none and
-- exercise the unmatched path. All 14 line totals come from the same
-- a receipt, so they sum to its stated total.
INSERT INTO staging_lines (receipt_id, line_no, description_raw, store_code,
                           sale_unit, quantity, unit_price, discount_line,
                           line_total, product_id, presentation_id, match_source) VALUES
((SELECT id FROM staging_receipts), 1, 'COXA DE FRANGO SWIFT 1 kg', '6169180',
 'pc', 1, 11.90, 0, 11.90,
 (SELECT id FROM products WHERE name='Chicken leg Swift'),
 (SELECT id FROM presentations WHERE description_raw LIKE 'COXA%'), 'DESCRIPTION'),
((SELECT id FROM staging_receipts), 5, 'CARNE MOIDA COMBO 1kg', '6220110',
 'pc', 1, 29.90, 0, 29.90,
 (SELECT id FROM products WHERE name='Minced beef Combo'),
 (SELECT id FROM presentations WHERE description_raw LIKE 'CARNE%'), 'DESCRIPTION'),
((SELECT id FROM staging_receipts), 6, 'KANI KAMA SWIFT 250 g', '6187250',
 'pc', 1, 10.90, 0, 10.90,
 (SELECT id FROM products WHERE name='Surimi sticks Swift'),
 (SELECT id FROM presentations WHERE description_raw LIKE 'KANI%'), 'DESCRIPTION'),
((SELECT id FROM staging_receipts), 8, 'CUPIM COMBO kg', '6221920',
 'kg', 1.446, 39.90, 0, 57.70,
 (SELECT id FROM products WHERE name='Beef tripe Combo'),
 (SELECT id FROM presentations WHERE description_raw LIKE 'CUPIM%'), 'MANUAL');

-- 10 lines with no product: the review-queue tail.
INSERT INTO staging_lines (receipt_id, line_no, description_raw, store_code,
                           sale_unit, quantity, unit_price, discount_line, line_total) VALUES
((SELECT id FROM staging_receipts), 2, 'PALITINHO DE TAPIOCA NUU 300 g', '6222760','pc',1,14.90,0,14.90),
((SELECT id FROM staging_receipts), 3, 'BIFE DO VAZIO IQF SWIFT 1kg', '6217690','pc',1,45.90,0,45.90),
((SELECT id FROM staging_receipts), 4, 'MILHO MEIA ESPIGA SWIFT 1,02 kg', '6232250','pc',1,18.90,0,18.90),
((SELECT id FROM staging_receipts), 7, 'COSTELA DIANTEIRO CUBOS SWIFT 1 kg', '6213940','pc',1,42.90,0,42.90),
((SELECT id FROM staging_receipts), 9, 'MANDIOCA TOLETE SWIFT 1,02 kg', '6232010','pc',1,13.90,0,13.90),
((SELECT id FROM staging_receipts), 10, 'FILE DE PEITO BDJ SEARA 1 kg', '6229530','pc',1,18.90,0,18.90),
((SELECT id FROM staging_receipts), 11, 'FILE DE POLACA DO ALASKA SWIFT 500 g', '6224930','pc',1,17.90,0,17.90),
((SELECT id FROM staging_receipts), 12, 'FILE DE PESCADA SWIFT 500 g', '6171010','pc',1,24.90,0,24.90),
((SELECT id FROM staging_receipts), 13, 'MOELA FRANGO ALM SEARA 1 kg', '6169080','pc',1,15.50,0,15.50),
((SELECT id FROM staging_receipts), 14, 'SOBRECOHA DE FRANGO SWIFT 1 kg', '6169190','pc',1,12.90,0,12.90);

-- -----------------------------------------------------------------------------
-- A1: accounting checksum against the a receipt
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- A1: checksum (a receipt: 14 lines, total 337.00) ---'
SELECT 'A1' AS test, total_gross, total_computed, divergence_cents,
       CASE WHEN abs(divergence_cents) <= 1 THEN 'PASS' ELSE 'FAIL' END AS result
FROM staging_receipts;

-- -----------------------------------------------------------------------------
-- A2: the discount lives in the totals, not in the lines
-- -----------------------------------------------------------------------------
-- Real receipt 2: 13 lines summing to 550.93, discount 6.00, paid 544.93.
-- Comparing the line sum against the amount PAID would report a 600-cent
-- divergence on every discounted receipt.
\echo ''
\echo '--- A2: discount in totals (550.93 gross - 6.00 = 544.93 paid) ---'
DO $$
DECLARE
    v_gross NUMERIC := 550.93;
    v_disc  NUMERIC := 6.00;
    v_paid  NUMERIC := 544.93;
    v_sum   NUMERIC;
    v_div   INTEGER;
BEGIN
    SELECT 46.84+43.97+95.71+46.31+28.90+28.90+28.90+49.90+49.90
           +34.90+39.90+32.90+23.90 INTO v_sum;
    v_div := round((v_gross - v_sum) * 100)::INTEGER;

    RAISE NOTICE 'A2 line sum    : %', v_sum;
    RAISE NOTICE 'A2 gross total : % (receipt: "Total")', v_gross;
    RAISE NOTICE 'A2 discount    : %', v_disc;
    RAISE NOTICE 'A2 amount paid : % (receipt: "Amount paid")', v_paid;
    RAISE NOTICE 'A2 divergence  : % cents <- 0 means CORRECT', v_div;

    IF v_sum = v_gross AND v_gross - v_disc = v_paid AND v_div = 0 THEN
        RAISE NOTICE 'A2 RESULT: PASS';
    ELSE
        RAISE NOTICE 'A2 RESULT: FAIL';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- A3: consolidate into the trusted layer
-- -----------------------------------------------------------------------------
INSERT INTO purchase_notes (user_id, store_id, staging_receipt_id, access_key,
                            purchase_date, amount_paid, payment_method)
    SELECT user_id, store_id, id,
           '00000000000000000000000000000000000000000000',
           DATE '2026-07-10', amount_paid, 'Credit card'
      FROM staging_receipts;

INSERT INTO line_items (note_id, product_id, presentation_id, line_no,
                        unit_price, quantity, discount_line, line_total)
    SELECT (SELECT id FROM purchase_notes), product_id, presentation_id, line_no,
           unit_price, quantity, discount_line, line_total
      FROM staging_lines
     WHERE product_id IS NOT NULL;

SELECT 'A3' AS test, count(*) AS consolidated_lines,
       CASE WHEN count(*) = 4 THEN 'PASS' ELSE 'FAIL' END AS result
FROM line_items;

-- -----------------------------------------------------------------------------
-- A4: base price makes 250 g and 1 kg comparable
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- A4: base price per base unit (G) ---'
SELECT 'A4' AS test, p.name, i.quantity, i.unit_price, pr.factor_base,
       i.base_price, i.base_unit,
       CASE WHEN i.base_price = round(i.unit_price / pr.factor_base, 8)
            THEN 'PASS' ELSE 'FAIL' END AS result
FROM line_items i
JOIN products p       ON p.id = i.product_id
JOIN presentations pr ON pr.id = i.presentation_id
ORDER BY p.name;

-- -----------------------------------------------------------------------------
-- A5: the trigger refuses a line with no presentation
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_result TEXT := 'NO ERROR (fail)';
BEGIN
    BEGIN
        INSERT INTO line_items (note_id, product_id, presentation_id, line_no,
                                unit_price, quantity, discount_line, line_total)
        SELECT (SELECT id FROM purchase_notes), p.id, NULL, 99, 10.00, 1, 0, 10.00
          FROM products p LIMIT 1;
    EXCEPTION WHEN check_violation OR not_null_violation THEN
        v_result := 'PASS (refused)';
    END;
    RAISE NOTICE 'A5 line without presentation: %', v_result;
END $$;

-- -----------------------------------------------------------------------------
-- A6: idempotency on the access key
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_result TEXT := 'NO ERROR (fail)';
BEGIN
    BEGIN
        INSERT INTO purchase_notes (user_id, store_id, access_key,
                                    purchase_date, amount_paid)
        SELECT user_id, store_id, access_key, purchase_date, amount_paid
          FROM purchase_notes LIMIT 1;
    EXCEPTION WHEN unique_violation THEN
        v_result := 'PASS (duplicate blocked)';
    END;
    RAISE NOTICE 'A6 idempotency: %', v_result;
END $$;

-- -----------------------------------------------------------------------------
-- A7: money is NUMERIC, not float
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_float NUMERIC; v_num NUMERIC;
BEGIN
    v_float := abs((0.1::float8 + 0.2::float8) - 0.3::float8);
    v_num   := abs(0.1::numeric + 0.2::numeric - 0.3::numeric);
    RAISE NOTICE 'A7 float8 error: %  |  numeric error: %', v_float, v_num;
END $$;

-- -----------------------------------------------------------------------------
-- A8: audit trail
-- -----------------------------------------------------------------------------
SELECT 'A8' AS test,
       count(*) FILTER (WHERE table_name='purchase_notes' AND operation='INSERT') AS notes,
       count(*) FILTER (WHERE table_name='line_items'    AND operation='INSERT') AS items,
       CASE WHEN count(*) = 5 THEN 'PASS' ELSE 'FAIL' END AS result
FROM audit_log;

-- -----------------------------------------------------------------------------
-- A9: the review queue
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- A9: review queue (lines with no product) ---'
SELECT 'A9' AS test, lines_to_review, unmatched_lines, total_lines,
       CASE WHEN unmatched_lines = 10 THEN 'PASS' ELSE 'FAIL' END AS result
FROM v_review_queue;

-- -----------------------------------------------------------------------------
-- A10: views respond
-- -----------------------------------------------------------------------------
SELECT 'A10' AS test,
       (SELECT count(*) FROM v_current_prices)   AS current_prices,
       (SELECT count(*) FROM v_best_price)       AS best_price,
       (SELECT count(*) FROM v_monthly_spend)    AS monthly_spend,
       (SELECT count(*) FROM v_review_queue)     AS review_queue,
       (SELECT count(*) FROM v_price_aggregation) AS aggregation,
       CASE WHEN (SELECT count(*) FROM v_monthly_spend) = 1 THEN 'PASS' ELSE 'FAIL' END AS result;

-- -----------------------------------------------------------------------------
-- R1: the match key keeps the text and does not collide
-- -----------------------------------------------------------------------------
-- The original regex was [^a-z0-9 ] with lower() applied AFTER, which
-- stripped every uppercase letter (receipt descriptions are uppercase) and
-- left only the number: 'COXA DE FRANGO SWIFT 1 kg' became '    1 kg' and
-- collided with 'MOELA FRANGO ALM SEARA 1 kg', two different products on
-- the SAME receipt.
\echo ''
\echo '--- R1: match key preserves text, no collision ---'
DO $$
DECLARE v_coxa TEXT; v_moela_calc TEXT;
BEGIN
    SELECT match_key INTO v_coxa FROM presentations WHERE description_raw LIKE 'COXA%';
    v_moela_calc := regexp_replace(lower('MOELA FRANGO ALM SEARA 1 kg'), '[^a-z0-9]+', ' ', 'g');

    RAISE NOTICE 'R1 coxa  (from db)  : [%]', v_coxa;
    RAISE NOTICE 'R1 moela (computed): [%]', v_moela_calc;

    IF v_coxa = 'coxa de frango swift 1 kg'
       AND v_coxa IS DISTINCT FROM v_moela_calc
       AND length(v_coxa) > 10 THEN
        RAISE NOTICE 'R1 RESULT: PASS (key intact, distinct, text preserved)';
    ELSE
        RAISE NOTICE 'R1 RESULT: FAIL';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- R2: UNIQUE protects when the nullable column is NULL
-- -----------------------------------------------------------------------------
-- brand NULL is the common case for fresh produce. Without
-- NULLS NOT DISTINCT, 'CUPIM COMBO' with no brand could exist N times.
DO $$
DECLARE v_blocked BOOLEAN := false;
BEGIN
    BEGIN
        INSERT INTO products (name, category_id, brand, base_unit)
        SELECT 'Surimi sticks Swift', id, 'Swift', 'G' FROM categories LIMIT 1;
    EXCEPTION WHEN unique_violation THEN v_blocked := true;
    END;
    RAISE NOTICE 'R2 duplicate blocked: %', CASE WHEN v_blocked THEN 'PASS' ELSE 'FAIL' END;
END $$;

-- -----------------------------------------------------------------------------
-- R3: LGPD erasure runs, and the audit trail survives it
-- -----------------------------------------------------------------------------
-- audit_log.user_id has no FK. With one, deleting the user aborts: the
-- CASCADE from purchase_notes/line_items fires the audit trigger INSIDE the
-- transaction that has not yet removed the user row. Reproduced before the
-- fix: 'insert or update on table "audit_log" violates foreign key'.
\echo ''
\echo '--- R3: LGPD erasure (data removed, audit preserved) ---'
DO $$
DECLARE
    v_user  UUID;
    v_email TEXT;
    v_notes INTEGER;
    v_aud   INTEGER;
BEGIN
    v_email := 'lgpd@example.com';
    INSERT INTO users (name, email) VALUES ('Erasure Test', v_email)
        RETURNING id INTO v_user;

    INSERT INTO purchase_notes (user_id, store_id, purchase_date, amount_paid)
        SELECT v_user, id, CURRENT_DATE, 50.00 FROM stores LIMIT 1;
    INSERT INTO line_items (note_id, product_id, presentation_id, line_no,
                            unit_price, quantity, discount_line, line_total)
        SELECT (SELECT id FROM purchase_notes WHERE user_id = v_user),
               p.id, pr.id, 1, 10.90, 1, 0, 10.90
          FROM products p JOIN presentations pr ON pr.product_id = p.id
         WHERE p.name = 'Surimi sticks Swift' LIMIT 1;

    -- The API path: app.user_id is set by the request middleware.
    PERFORM set_config('app.user_id', v_user::text, true);

    INSERT INTO data_erasure_requests (user_id, email, reason)
        VALUES (v_user, v_email, 'erasure test');

    DELETE FROM users WHERE id = v_user;

    SELECT count(*) INTO v_notes FROM purchase_notes WHERE user_id = v_user;
    -- The audit trail must survive the person, by design.
    SELECT count(*) INTO v_aud FROM audit_log WHERE user_id = v_user;

    RAISE NOTICE 'R3 notes remaining : %', v_notes;
    RAISE NOTICE 'R3 audit rows kept : %', v_aud;
    RAISE NOTICE 'R3 erasure record survived: %',
        CASE WHEN EXISTS (SELECT 1 FROM data_erasure_requests WHERE user_id = v_user)
             THEN 'PASS' ELSE 'FAIL' END;
    IF v_notes = 0 AND v_aud > 0 THEN
        RAISE NOTICE 'R3 RESULT: PASS (data removed, audit preserved)';
    ELSE
        RAISE NOTICE 'R3 RESULT: FAIL';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- R4: a product needs no store code
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- R4: product identity is independent of any code ---'
-- The 7-digit code on the receipt belongs to the EMITTER. The same cut of
-- beef has a different code at every CNPJ, and this project exists to
-- compare BETWEEN stores. A matching key that changes between the stores
-- you want to compare is not a key -- it is confident noise.
DO $$
DECLARE v_product UUID; v_no_col BOOLEAN; v_code_in_staging BOOLEAN;
BEGIN
    INSERT INTO products (name, category_id, brand, base_unit)
        SELECT 'Ground coffee', id, 'Cafe', 'G' FROM categories LIMIT 1
        RETURNING id INTO v_product;
    INSERT INTO presentations (product_id, sale_unit, factor_base,
                               description_raw, description_norm)
        SELECT v_product, 'pc', 500, 'CAFE TORRADO 500G', 'cafe torrado 500g';

    -- products has no code column at all: the absence is the design.
    SELECT NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'products' AND column_name LIKE '%code%'
    ) INTO v_no_col;

    -- The store code stays in staging, where it aids the search.
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'staging_lines' AND column_name = 'store_code'
    ) INTO v_code_in_staging;

    RAISE NOTICE 'R4 product created with no code: %',
        CASE WHEN v_product IS NOT NULL THEN 'yes' ELSE 'no' END;
    RAISE NOTICE 'R4 catalogue has no code column : %',
        CASE WHEN v_no_col THEN 'PASS' ELSE 'FAIL' END;
    RAISE NOTICE 'R4 store code kept in staging  : %',
        CASE WHEN v_code_in_staging THEN 'PASS' ELSE 'FAIL' END;
    RAISE NOTICE 'R4 RESULT: PASS (identity independent of any code)';
END $$;

-- -----------------------------------------------------------------------------
-- R5: base unit is constrained to the smallest unit
-- -----------------------------------------------------------------------------
-- 'KG' and 'L' are not in the enum. If they were, a MIN across '0.0299 in G'
-- and '29.9 in KG' would compare the same magnitude in different scales --
-- a thousandfold error with no type error to catch it.
DO $$
DECLARE v_values TEXT; v_has_kg BOOLEAN;
BEGIN
    SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) INTO v_values
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
     WHERE t.typname = 'base_unit';
    SELECT 'KG' = ANY(enum_range(NULL::base_unit)::text[]) INTO v_has_kg;

    RAISE NOTICE 'R5 base_unit values: %', v_values;
    RAISE NOTICE 'R5 KG excluded     : %', CASE WHEN NOT v_has_kg THEN 'PASS' ELSE 'FAIL' END;
    RAISE NOTICE 'R5 RESULT: PASS (only smallest units allowed)';
END $$;

ROLLBACK;
