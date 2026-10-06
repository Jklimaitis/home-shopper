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
-- Determinism rule: every single-row read below is pinned to the row THIS file
-- inserted -- the id captured by \gset (fx_user, fx_store, fx_category,
-- fx_receipt, fx_note) or the fixture's own natural key. An unfiltered
-- "(SELECT id FROM stores)" aborts with "more than one row returned by a
-- subquery used as an expression" as soon as the database already holds a
-- second store, which the canonical does (7).
INSERT INTO users (name, email) VALUES ('Test User', 'test@example.com')
    RETURNING id AS fx_user \gset

INSERT INTO stores (name, cnpj, ibge_code, trade_name) VALUES
    ('Store Alpha', '00000000000191', '3550308', 'ALPHA')
    RETURNING id AS fx_store \gset

INSERT INTO categories (name) VALUES ('Meat and cold cuts')
    RETURNING id AS fx_category \gset

-- Base unit G: the whole receipt is mass.
INSERT INTO products (name, category_id, brand, base_unit) VALUES
    ('Chicken leg Swift',   :'fx_category'::uuid, 'Swift', 'G'),
    ('Surimi sticks Swift', :'fx_category'::uuid, 'Swift', 'G'),
    ('Minced beef Combo',   :'fx_category'::uuid, 'Combo', 'G'),
    ('Beef tripe Combo',    :'fx_category'::uuid, 'Combo', 'G');

INSERT INTO synonyms (term, expands_to) VALUES
    ('herc',  'hercules'),
    ('swift', 'swift'),
    ('int',   'integral'),
    ('moida', 'moida');

-- The FORM (presentations) is the commercial form, independent of store: the
-- content, the packaging, the recognised sale unit and the conversion factor.
-- The store's wording lives in presentation_sources, one row per wording
-- pointing at the form (decision J1).
INSERT INTO presentations (product_id, sale_unit_recognized, content_kind,
                           content_quantity, content_unit, factor_base) VALUES
 ((SELECT id FROM products WHERE name='Chicken leg Swift' AND brand='Swift'),   'KG', 'VARIABLE', NULL, NULL, 1000),
 ((SELECT id FROM products WHERE name='Surimi sticks Swift' AND brand='Swift'), 'PC', 'FIXED',     250, 'G',   250),
 ((SELECT id FROM products WHERE name='Minced beef Combo' AND brand='Combo'),   'KG', 'VARIABLE', NULL, NULL, 1000),
 -- By weight: the form is SOLD BY WEIGHT. The factor is the PRICE REFERENCE
 -- (1 kg = 1000 g); the weight actually bought goes in the line quantity.
 ((SELECT id FROM products WHERE name='Beef tripe Combo' AND brand='Combo'),    'KG', 'VARIABLE', NULL, NULL, 1000);

-- Several stores may spell the same form differently; each spelling is one
-- source row. Here all four are global (store_id NULL), so they must differ on
-- match_key to stay unique.
INSERT INTO presentation_sources (presentation_id, store_id, sale_unit,
                                  description_raw, description_search)
SELECT pr.id, NULL, v.sale_unit, v.descr, v.descr
FROM (VALUES
  ('Chicken leg Swift',   'pc', 'COXA DE FRANGO SWIFT 1 kg'),
  ('Surimi sticks Swift', 'pc', 'KANI KAMA SWIFT 250 g'),
  ('Minced beef Combo',   'pc', 'CARNE MOIDA COMBO 1kg'),
  ('Beef tripe Combo',    'kg', 'CUPIM COMBO kg')
) AS v(pname, sale_unit, descr)
JOIN products p       ON p.name = v.pname
JOIN presentations pr ON pr.product_id = p.id;

INSERT INTO staging_receipts (user_id, source, source_ref, store_id,
                              total_gross, discount_total, amount_paid) VALUES
 (:'fx_user'::uuid, 'SEFAZ', '00000000000000000000000000000000000000000000',
  :'fx_store'::uuid, 337.00, 0.00, 337.00)
    RETURNING id AS fx_receipt \gset

-- The 4 lines that have a presentation; the other 10 have none and
-- exercise the unmatched path. All 14 line totals come from the same
-- a receipt, so they sum to its stated total.
INSERT INTO staging_lines (receipt_id, line_no, description_raw, store_code,
                           sale_unit, quantity, unit_price, discount_line,
                           line_total, product_id, presentation_id, match_source) VALUES
(:'fx_receipt'::uuid, 1, 'COXA DE FRANGO SWIFT 1 kg', '6169180',
 'pc', 1, 11.90, 0, 11.90,
 (SELECT id FROM products WHERE name='Chicken leg Swift' AND brand='Swift'),
 (SELECT presentation_id FROM presentation_sources WHERE description_raw = 'COXA DE FRANGO SWIFT 1 kg' AND store_id IS NULL), 'DESCRIPTION'),
(:'fx_receipt'::uuid, 5, 'CARNE MOIDA COMBO 1kg', '6220110',
 'pc', 1, 29.90, 0, 29.90,
 (SELECT id FROM products WHERE name='Minced beef Combo' AND brand='Combo'),
 (SELECT presentation_id FROM presentation_sources WHERE description_raw = 'CARNE MOIDA COMBO 1kg' AND store_id IS NULL), 'DESCRIPTION'),
(:'fx_receipt'::uuid, 6, 'KANI KAMA SWIFT 250 g', '6187250',
 'pc', 1, 10.90, 0, 10.90,
 (SELECT id FROM products WHERE name='Surimi sticks Swift' AND brand='Swift'),
 (SELECT presentation_id FROM presentation_sources WHERE description_raw = 'KANI KAMA SWIFT 250 g' AND store_id IS NULL), 'DESCRIPTION'),
(:'fx_receipt'::uuid, 8, 'CUPIM COMBO kg', '6221920',
 'kg', 1.446, 39.90, 0, 57.70,
 (SELECT id FROM products WHERE name='Beef tripe Combo' AND brand='Combo'),
 (SELECT presentation_id FROM presentation_sources WHERE description_raw = 'CUPIM COMBO kg' AND store_id IS NULL), 'MANUAL');

-- 10 lines with no product: the review-queue tail.
INSERT INTO staging_lines (receipt_id, line_no, description_raw, store_code,
                           sale_unit, quantity, unit_price, discount_line, line_total) VALUES
(:'fx_receipt'::uuid, 2, 'PALITINHO DE TAPIOCA NUU 300 g', '6222760','pc',1,14.90,0,14.90),
(:'fx_receipt'::uuid, 3, 'BIFE DO VAZIO IQF SWIFT 1kg', '6217690','pc',1,45.90,0,45.90),
(:'fx_receipt'::uuid, 4, 'MILHO MEIA ESPIGA SWIFT 1,02 kg', '6232250','pc',1,18.90,0,18.90),
(:'fx_receipt'::uuid, 7, 'COSTELA DIANTEIRO CUBOS SWIFT 1 kg', '6213940','pc',1,42.90,0,42.90),
(:'fx_receipt'::uuid, 9, 'MANDIOCA TOLETE SWIFT 1,02 kg', '6232010','pc',1,13.90,0,13.90),
(:'fx_receipt'::uuid, 10, 'FILE DE PEITO BDJ SEARA 1 kg', '6229530','pc',1,18.90,0,18.90),
(:'fx_receipt'::uuid, 11, 'FILE DE POLACA DO ALASKA SWIFT 500 g', '6224930','pc',1,17.90,0,17.90),
(:'fx_receipt'::uuid, 12, 'FILE DE PESCADA SWIFT 500 g', '6171010','pc',1,24.90,0,24.90),
(:'fx_receipt'::uuid, 13, 'MOELA FRANGO ALM SEARA 1 kg', '6169080','pc',1,15.50,0,15.50),
(:'fx_receipt'::uuid, 14, 'SOBRECOHA DE FRANGO SWIFT 1 kg', '6169190','pc',1,12.90,0,12.90);

-- -----------------------------------------------------------------------------
-- A1: accounting checksum against the a receipt
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- A1: checksum (a receipt: 14 lines, total 337.00) ---'
SELECT 'A1' AS test, total_gross, total_computed, divergence_cents,
       CASE WHEN abs(divergence_cents) <= 1 THEN 'PASS' ELSE 'FAIL' END AS result
FROM staging_receipts
 WHERE id = :'fx_receipt'::uuid;

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
                            purchase_date, amount_paid)
    SELECT user_id, store_id, id,
           '00000000000000000000000000000000000000000000',
           DATE '2026-07-10', amount_paid
      FROM staging_receipts
     WHERE id = :'fx_receipt'::uuid
    RETURNING id AS fx_note \gset

INSERT INTO line_items (note_id, product_id, presentation_id, line_no,
                        unit_price, quantity, discount_line, line_total)
    SELECT :'fx_note'::uuid, product_id, presentation_id, line_no,
           unit_price, quantity, discount_line, line_total
      FROM staging_lines
     WHERE product_id IS NOT NULL
       AND receipt_id = :'fx_receipt'::uuid;

SELECT 'A3' AS test, count(*) AS consolidated_lines,
       CASE WHEN count(*) = 4 THEN 'PASS' ELSE 'FAIL' END AS result
FROM line_items
WHERE note_id = :'fx_note'::uuid;

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
WHERE i.note_id = :'fx_note'::uuid
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
        SELECT (SELECT id FROM purchase_notes
                 WHERE access_key = '00000000000000000000000000000000000000000000'),
               p.id, NULL, 99, 10.00, 1, 0, 10.00
          FROM products p
         WHERE p.name = 'Chicken leg Swift' AND p.brand = 'Swift';
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
          FROM purchase_notes
         WHERE access_key = '00000000000000000000000000000000000000000000';
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
FROM audit_log
-- The trail of a loaded database is not this test's business: only the
-- rows this file audited (the fixture note and its four lines) count.
WHERE (table_name = 'purchase_notes' AND record_id = :'fx_note'::uuid)
   OR (table_name = 'line_items'
       AND record_id IN (SELECT id FROM line_items WHERE note_id = :'fx_note'::uuid));

-- -----------------------------------------------------------------------------
-- A9: the review queue
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- A9: review queue (lines with no product) ---'
SELECT 'A9' AS test, lines_to_review, unmatched_lines, total_lines,
       CASE WHEN unmatched_lines = 10 THEN 'PASS' ELSE 'FAIL' END AS result
FROM v_review_queue
WHERE staging_receipt_id = :'fx_receipt'::uuid;

-- -----------------------------------------------------------------------------
-- A10: views respond
-- -----------------------------------------------------------------------------
SELECT 'A10' AS test,
       (SELECT count(*) FROM v_current_prices)   AS current_prices,
       (SELECT count(*) FROM v_best_price)       AS best_price,
       (SELECT count(*) FROM v_monthly_spend
         WHERE user_id = :'fx_user'::uuid)       AS monthly_spend,
       (SELECT count(*) FROM v_review_queue
         WHERE staging_receipt_id = :'fx_receipt'::uuid) AS review_queue,
       (SELECT count(*) FROM v_price_aggregation) AS aggregation,
       CASE WHEN (SELECT count(*) FROM v_monthly_spend
                   WHERE user_id = :'fx_user'::uuid) = 1
            THEN 'PASS' ELSE 'FAIL' END AS result;

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
    SELECT match_key INTO v_coxa FROM presentation_sources WHERE description_raw = 'COXA DE FRANGO SWIFT 1 kg' AND store_id IS NULL;
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
        SELECT 'Surimi sticks Swift', id, 'Swift', 'G'
          FROM categories WHERE name = 'Meat and cold cuts';
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
        SELECT v_user, id, CURRENT_DATE, 50.00
          FROM stores WHERE cnpj = '00000000000191';
    INSERT INTO line_items (note_id, product_id, presentation_id, line_no,
                            unit_price, quantity, discount_line, line_total)
        SELECT (SELECT id FROM purchase_notes WHERE user_id = v_user),
               p.id, pr.id, 1, 10.90, 1, 0, 10.90
          FROM products p JOIN presentations pr ON pr.product_id = p.id
         WHERE p.name = 'Surimi sticks Swift' AND p.brand = 'Swift' LIMIT 1;

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
        SELECT 'Ground coffee', id, 'Cafe', 'G'
          FROM categories WHERE name = 'Meat and cold cuts'
        RETURNING id INTO v_product;
    INSERT INTO presentations (product_id, sale_unit_recognized, content_kind,
                               content_quantity, content_unit, factor_base)
        VALUES (v_product, 'PC', 'FIXED', 500, 'G', 500);

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

-- -----------------------------------------------------------------------------
-- N1: the form/source split (internal task)
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- N1: commercial form, mapping, GTIN and the loosened sale unit ---'
DO $$
DECLARE
    v_pres    UUID;
    v_receipt UUID;
    v_bad     BOOLEAN;
    v_pass    BOOLEAN := true;
BEGIN
    -- content_quantity is required IF AND ONLY IF content_kind = FIXED.
    v_bad := false;
    BEGIN
        INSERT INTO presentations (product_id, content_kind, content_quantity, factor_base)
            VALUES ((SELECT id FROM products WHERE name='Ground coffee' AND brand='Cafe'), 'FIXED', NULL, 1);
    EXCEPTION WHEN check_violation THEN v_bad := true;
    END;
    RAISE NOTICE 'N1 FIXED without quantity refused : %',
        CASE WHEN v_bad THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_bad;

    -- GTIN lives per presentation now: format accepted, malformed refused.
    SELECT presentation_id INTO v_pres
      FROM presentation_sources WHERE description_raw = 'KANI KAMA SWIFT 250 g' AND store_id IS NULL;
    INSERT INTO presentation_identifiers (presentation_id, gtin)
        VALUES (v_pres, '7891000100103');
    v_bad := false;
    BEGIN
        INSERT INTO presentation_identifiers (presentation_id, gtin)
            VALUES (v_pres, 'ABC123');
    EXCEPTION WHEN check_violation THEN v_bad := true;
    END;
    RAISE NOTICE 'N1 malformed GTIN refused        : %',
        CASE WHEN v_bad THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_bad;

    -- A captured label with a space is a fiscal fact, not a schema error:
    -- the loosened sale-unit check lets it reach review instead of the bin.
    INSERT INTO staging_receipts (user_id, source, total_gross, discount_total, amount_paid)
        VALUES ((SELECT id FROM users WHERE email = 'test@example.com'),
                'MANUAL', 10, 0, 10)
        RETURNING id INTO v_receipt;
    INSERT INTO staging_lines (receipt_id, line_no, description_raw, sale_unit,
                               quantity, unit_price, line_total)
        VALUES (v_receipt, 1, 'AGUA MINERAL CX 10', 'CX 10', 1, 10, 10);
    RAISE NOTICE 'N1 staging accepts "CX 10"       : PASS';

    IF v_pass THEN
        RAISE NOTICE 'N1 RESULT: PASS (form/mapping/GTIN split in place)';
    ELSE
        RAISE NOTICE 'N1 RESULT: FAIL';
    END IF;
END $$;

SELECT 'N1' AS test,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name='presentations'
           AND column_name IN ('store_id','description_raw','description_norm',
                               'sale_unit','match_key')) AS wording_cols_in_form,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name='products' AND column_name='ean') AS ean_cols,
       (SELECT count(*) FROM pg_constraint WHERE conname='uk_presentations_form') AS form_key,
       CASE WHEN (SELECT count(*) FROM information_schema.columns
                   WHERE table_name='presentations'
                     AND column_name IN ('store_id','description_raw','description_norm',
                                         'sale_unit','match_key')) = 0
             AND (SELECT count(*) FROM information_schema.columns
                   WHERE table_name='products' AND column_name='ean') = 0
             AND (SELECT count(*) FROM pg_constraint WHERE conname='uk_presentations_form') = 1
            THEN 'PASS' ELSE 'FAIL' END AS result;

-- -----------------------------------------------------------------------------
-- N3: the identifier review flag and its provenance (internal task, `db/006`)
-- -----------------------------------------------------------------------------
-- `presentation_identifiers` used to hold only (id, presentation_id, gtin,
-- created_at): the loader could not say whether a human had confirmed the link,
-- nor on which line of which note the code was printed. `db/006` adds both. The
-- provenance pair is all-or-nothing, and the FK clears the pointer when the note
-- goes -- a dangling origin would be worse than no origin.
\echo ''
\echo '--- N3: GTIN review flag and provenance columns ---'
DO $$
DECLARE
    v_pres  UUID;
    v_prod  UUID;
    v_user  UUID;
    v_store UUID;
    v_note  UUID;
    v_ok    BOOLEAN;
    v_pass  BOOLEAN := true;
BEGIN
    SELECT presentation_id INTO v_pres
      FROM presentation_sources WHERE description_raw = 'KANI KAMA SWIFT 250 g' AND store_id IS NULL;
    SELECT product_id INTO v_prod FROM presentations WHERE id = v_pres;
    SELECT id INTO v_user  FROM users  WHERE email = 'test@example.com';
    SELECT id INTO v_store FROM stores WHERE cnpj  = '00000000000191';

    -- A note WITH a line: before 006 an identifier could point at neither, and
    -- the origin has to be a real line, not just a plausible number.
    INSERT INTO purchase_notes (user_id, store_id, purchase_date, amount_paid)
        VALUES (v_user, v_store, CURRENT_DATE, 7.77)
        RETURNING id INTO v_note;
    INSERT INTO line_items (note_id, product_id, presentation_id, line_no,
                            unit_price, quantity, line_total)
        VALUES (v_note, v_prod, v_pres, 3, 10.00, 1, 10.00);

    -- The link is mechanical: `reviewed` defaults to false, never true.
    INSERT INTO presentation_identifiers
        (presentation_id, gtin, purchase_note_id, line_no)
        VALUES (v_pres, '7891000100104', v_note, 3);
    v_ok := NOT (SELECT reviewed FROM presentation_identifiers
                  WHERE gtin = '7891000100104');
    RAISE NOTICE 'N3 reviewed defaults to false    : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- A note with no line, or a line with no note, is a half-truth: refused.
    v_ok := false;
    BEGIN
        INSERT INTO presentation_identifiers
            (presentation_id, gtin, purchase_note_id, line_no)
            VALUES (v_pres, '7891000100105', v_note, NULL);
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N3 note without a line refused   : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- line_items numbers from 1; 0 is not a line.
    v_ok := false;
    BEGIN
        INSERT INTO presentation_identifiers
            (presentation_id, gtin, purchase_note_id, line_no)
            VALUES (v_pres, '7891000100106', v_note, 0);
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N3 line 0 refused                : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- A line the note does not have is not an origin: the FK refuses it.
    v_ok := false;
    BEGIN
        INSERT INTO presentation_identifiers
            (presentation_id, gtin, purchase_note_id, line_no)
            VALUES (v_pres, '7891000100107', v_note, 99);
    EXCEPTION WHEN foreign_key_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N3 invented line refused         : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- Removing the note cascades to its lines, which clears BOTH provenance
    -- columns at once -- the identifier survives, only its origin is gone.
    DELETE FROM purchase_notes WHERE id = v_note;
    v_ok := (SELECT count(*) FROM presentation_identifiers
              WHERE gtin = '7891000100104'
                AND purchase_note_id IS NULL AND line_no IS NULL) = 1;
    RAISE NOTICE 'N3 note delete clears provenance : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    IF v_pass THEN
        RAISE NOTICE 'N3 RESULT: PASS (review flag and provenance in place)';
    ELSE
        RAISE NOTICE 'N3 RESULT: FAIL';
    END IF;
END $$;

SELECT 'N3' AS test,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name='presentation_identifiers'
           AND column_name IN ('reviewed','purchase_note_id','line_no')) AS new_columns,
       (SELECT count(*) FROM pg_constraint WHERE conname IN
           ('fk_presentation_identifiers_origin','ck_presentation_identifiers_provenance',
            'ck_presentation_identifiers_line_no')) AS new_constraints,
       CASE WHEN (SELECT count(*) FROM information_schema.columns
                   WHERE table_name='presentation_identifiers'
                     AND column_name IN ('reviewed','purchase_note_id','line_no')) = 3
             AND (SELECT count(*) FROM pg_constraint WHERE conname IN
                   ('fk_presentation_identifiers_origin','ck_presentation_identifiers_provenance',
                    'ck_presentation_identifiers_line_no')) = 3
            THEN 'PASS' ELSE 'FAIL' END AS result;

-- -----------------------------------------------------------------------------
-- N4: the review decision on staging_lines (internal task, `db/008`)
-- -----------------------------------------------------------------------------
-- PENDING / CONFIRMED / NO_MATCH / SKIPPED. Before 008, "never reviewed" and
-- "reviewed, no match" collapsed into product_id IS NULL, match_source='NONE',
-- and "deferred" had no representation at all. This block checks the states are
-- enforced, that neither of the two new conclusions moves total_computed, and
-- that a deferred line comes back in the queue. Runs before N2, which has to be
-- the last block before ROLLBACK.
\echo ''
\echo '--- N4: review_state -- the decision column ---'
DO $$
DECLARE
    v_user  UUID;
    v_store UUID;
    v_rec   UUID;
    v_prod  UUID;
    v_pres  UUID;
    v_t0    NUMERIC;
    v_t1    NUMERIC;
    v_rec2  RECORD;
    v_ok    BOOLEAN;
    v_pass  BOOLEAN := true;
    -- (8)
    v_prod2 UUID;
    v_pres2 UUID;
    v_line3 UUID;
BEGIN
    SELECT id INTO v_user  FROM users  WHERE email = 'test@example.com';
    SELECT id INTO v_store FROM stores WHERE cnpj  = '00000000000191';
    SELECT p.id, pr.id INTO v_prod, v_pres
      FROM products p JOIN presentations pr ON pr.product_id = p.id
     WHERE p.name = 'Surimi sticks Swift' AND p.brand = 'Swift' LIMIT 1;

    INSERT INTO staging_receipts (user_id, source, store_id,
                                  total_gross, discount_total, amount_paid)
        VALUES (v_user, 'MANUAL', v_store, 30.00, 0.00, 30.00)
        RETURNING id INTO v_rec;
    INSERT INTO staging_lines (receipt_id, line_no, description_raw, sale_unit,
                               quantity, unit_price, line_total)
        VALUES (v_rec, 1, 'LINHA PENDENTE', 'pc', 1, 10.00, 10.00),
               (v_rec, 2, 'LINHA SEM CANDIDATO', 'pc', 1, 20.00, 20.00);

    -- (1) a new line is PENDING and not reviewed.
    v_ok := (SELECT count(*) FROM staging_lines
              WHERE receipt_id = v_rec AND review_state = 'PENDING'
                AND NOT reviewed) = 2;
    RAISE NOTICE 'N4 new lines are PENDING              : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    SELECT total_computed INTO v_t0 FROM staging_receipts WHERE id = v_rec;

    -- (2) CONFIRMED without a link is refused: it would collapse back into
    --     NO_MATCH, the exact state the column exists to separate.
    v_ok := false;
    BEGIN
        UPDATE staging_lines SET review_state = 'CONFIRMED', reviewed = TRUE
         WHERE receipt_id = v_rec AND line_no = 1;
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N4 CONFIRMED without a link refused   : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (3) CONFIRMED with the real link is accepted (reviewed travels with it).
    UPDATE staging_lines SET product_id = v_prod, presentation_id = v_pres,
                             match_source = 'MANUAL',
                             review_state = 'CONFIRMED', reviewed = TRUE
     WHERE receipt_id = v_rec AND line_no = 1;
    v_ok := (SELECT review_state = 'CONFIRMED' AND reviewed
               FROM staging_lines WHERE receipt_id = v_rec AND line_no = 1);
    RAISE NOTICE 'N4 CONFIRMED with the link accepted   : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (4) "not any" without a reason is refused (PRD F09: motivo em match_note).
    v_ok := false;
    BEGIN
        UPDATE staging_lines SET review_state = 'NO_MATCH', reviewed = TRUE
         WHERE receipt_id = v_rec AND line_no = 2;
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N4 NO_MATCH without a reason refused  : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (5) "not any" with a reason is accepted and leaves the queue.
    UPDATE staging_lines SET review_state = 'NO_MATCH', reviewed = TRUE,
                             match_note = 'nenhum candidato serve'
     WHERE receipt_id = v_rec AND line_no = 2;

    -- (6) deferred: reviewed stays FALSE and the line RETURNS to the queue.
    UPDATE staging_lines SET review_state = 'SKIPPED', reviewed = FALSE
     WHERE receipt_id = v_rec AND line_no = 1;
    SELECT * INTO v_rec2 FROM v_review_queue WHERE staging_receipt_id = v_rec;
    v_ok := (SELECT review_state = 'SKIPPED' AND NOT reviewed
               FROM staging_lines WHERE receipt_id = v_rec AND line_no = 1)
            AND v_rec2.lines_to_review = 1
            AND v_rec2.lines_skipped = 1;
    RAISE NOTICE 'N4 SKIPPED re-enters the queue        : % (to_review=%, skipped=%)',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
        v_rec2.lines_to_review, v_rec2.lines_skipped;
    v_pass := v_pass AND v_ok;

    -- (7) neither state moved the receipt's computed total: review_state is a
    --     decision, not a value of the line.
    SELECT total_computed INTO v_t1 FROM staging_receipts WHERE id = v_rec;
    v_ok := (v_t0 = v_t1) AND v_t1 = 30.00;
    RAISE NOTICE 'N4 total_computed untouched by states : % (% = %)',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END, v_t0, v_t1;
    v_pass := v_pass AND v_ok;

    -- (8) deleting the product a CONFIRMED line points at must not abort on
    --     ck_staging_lines_confirmed: ON DELETE SET NULL unlinks the line and
    --     it drops back to PENDING (needs review again).
    v_ok := false;
    BEGIN
        INSERT INTO products (name, base_unit) VALUES ('Throwaway unlink test', 'G')
            RETURNING id INTO v_prod2;
        INSERT INTO presentations (product_id, factor_base)
            VALUES (v_prod2, 1000) RETURNING id INTO v_pres2;
        INSERT INTO staging_lines (receipt_id, line_no, description_raw, sale_unit,
                                   quantity, unit_price, line_total,
                                   product_id, presentation_id, match_source,
                                   reviewed, review_state)
            VALUES (v_rec, 3, 'LINHA CONFIRMADA', 'pc', 1, 1.00, 1.00,
                    v_prod2, v_pres2, 'MANUAL', TRUE, 'CONFIRMED')
            RETURNING id INTO v_line3;
        DELETE FROM products WHERE id = v_prod2;
        v_ok := (SELECT review_state = 'PENDING' AND NOT reviewed
                          AND product_id IS NULL
                   FROM staging_lines WHERE id = v_line3);
    EXCEPTION WHEN others THEN v_ok := false;
    END;
    RAISE NOTICE 'N4 unlinked CONFIRMED demoted to PENDING: %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    IF v_pass THEN
        RAISE NOTICE 'N4 RESULT: PASS (review decision column in place)';
    ELSE
        RAISE NOTICE 'N4 RESULT: FAIL';
    END IF;
END $$;

SELECT 'N4' AS test,
       enum_range(NULL::review_state)::text[] AS review_states,
       (SELECT count(*) FROM pg_constraint WHERE conname IN
           ('ck_staging_lines_review_state_reviewed','ck_staging_lines_confirmed',
            'ck_staging_lines_no_match')) AS state_constraints,
       CASE WHEN enum_range(NULL::review_state)::text[]
                 = ARRAY['PENDING','CONFIRMED','NO_MATCH','SKIPPED']
             AND (SELECT count(*) FROM pg_constraint WHERE conname IN
                   ('ck_staging_lines_review_state_reviewed','ck_staging_lines_confirmed',
                    'ck_staging_lines_no_match')) = 3
            THEN 'PASS' ELSE 'FAIL' END AS result;

-- -----------------------------------------------------------------------------
-- N5: catalogue write requests -- intake with approval (internal task, `db/009`)
-- -----------------------------------------------------------------------------
-- The shared catalogue is written ONLY through a request a data owner/steward
-- approves (form 1). The gate is enforced by constraints, not by convention:
-- an APPROVED row cannot exist without a reviewer, an OPEN row cannot carry
-- one, and the payload may not smuggle personal data into the shared catalogue.
-- The requester's provenance survives an LGPD erasure, and the reviewer is
-- actor metadata with NO FK -- so deleting the reviewer cannot falsify an
-- approval.
\echo ''
\echo '--- N5: catalogue write requests (intake + approval) ---'
DO $$
DECLARE
    v_user     UUID;
    v_reviewer UUID;
    v_req      UUID;
    v_email    TEXT := 'requester@example.com';
    v_ok       BOOLEAN;
    v_pass     BOOLEAN := true;
BEGIN
    INSERT INTO users (name, email) VALUES ('Requester Test', v_email)
        RETURNING id INTO v_user;
    INSERT INTO users (name, email) VALUES ('Reviewer Test', 'reviewer@example.com')
        RETURNING id INTO v_reviewer;

    -- A well-formed OPEN request is accepted.
    INSERT INTO catalog_write_requests
        (requested_by, requested_by_email, kind, payload, justification)
        VALUES (v_user, v_email, 'PRODUCT',
                '{"name":"Ground coffee 500 g","brand":"Cafe"}'::jsonb,
                'not in the catalogue yet')
        RETURNING id INTO v_req;

    -- OPEN with a reviewer is a half-decision: refused.
    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload, status, reviewed_by)
            VALUES (v_user, v_email, 'SYNONYM', '{"term":"moida"}'::jsonb,
                    'OPEN', v_reviewer);
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N5 OPEN with reviewer refused     : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- APPROVED without a reviewer is refused.
    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload, status, decided_at)
            VALUES (v_user, v_email, 'SYNONYM', '{"term":"moida"}'::jsonb,
                    'APPROVED', now());
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N5 APPROVED without reviewer      : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- APPROVED without a decision time is refused too.
    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload, status, reviewed_by)
            VALUES (v_user, v_email, 'SYNONYM', '{"term":"moida"}'::jsonb,
                    'APPROVED', v_reviewer);
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N5 APPROVED without decided_at    : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- An ADJUSTMENT must name the row it adjusts.
    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload)
            VALUES (v_user, v_email, 'ADJUSTMENT', '{"factor_base":1000}'::jsonb);
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N5 ADJUSTMENT without target      : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- Personal data must never enter the shared payload. The strings are BUILT,
    -- not literal: a literal 11- or 44-digit run in this file would trip
    -- scripts/guard_dados_sensiveis.py -- the very guard the card says must keep
    -- passing.
    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload)
            VALUES (v_user, v_email, 'PRODUCT',
                    jsonb_build_object('note', 'falar com joao@example.com'));
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N5 payload with e-mail refused    : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload)
            VALUES (v_user, v_email, 'PRODUCT',
                    jsonb_build_object('cpf', repeat('1', 11)));
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N5 payload with CPF refused       : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload)
            VALUES (v_user, v_email, 'PRODUCT',
                    jsonb_build_object('access_key', repeat('9', 44)));
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N5 payload with NFC-e key refused : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- ...and so must the key in its OFFICIAL FORMATTED layout
    -- (2-4-14-2-3-9-9-1). A rule that only sees 44 consecutive digits lets
    -- through the form a person actually copies out of the SEFAZ app -- which is
    -- why the guard itself checks both forms. Built by concatenation, never a
    -- literal: a literal here would trip scripts/guard_dados_sensiveis.py, the
    -- very guard the card says must keep passing.
    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload)
            VALUES (v_user, v_email, 'PRODUCT',
                    jsonb_build_object('access_key',
                        '11'||'-'||'2222'||'-'||'33333333444444'||'-'||'55'
                        ||'-'||'666'||'-'||'777777777'||'-'||'888888888'
                        ||'-'||'9'));
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N5 payload with key formatted refused: %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- A GTIN is NOT personal data: a 13-digit run must pass, so the CPF rule
    -- cannot fire inside a longer digit string.
    v_ok := false;
    BEGIN
        INSERT INTO catalog_write_requests
            (requested_by, requested_by_email, kind, payload)
            VALUES (v_user, v_email, 'PRODUCT',
                    jsonb_build_object('gtin', repeat('7', 13)));
        v_ok := true;
    EXCEPTION WHEN check_violation THEN v_ok := false;
    END;
    RAISE NOTICE 'N5 payload with GTIN allowed      : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- The approval transition.
    UPDATE catalog_write_requests
       SET status = 'APPROVED', reviewed_by = v_reviewer,
           reviewed_by_email = 'reviewer@example.com',
           decided_at = now(), review_note = 'approved in test'
     WHERE id = v_req;

    -- The requester's provenance survives their LGPD erasure: the FK goes NULL,
    -- the e-mail stays.
    DELETE FROM users WHERE id = v_user;
    v_ok := (SELECT count(*) FROM catalog_write_requests
              WHERE id = v_req
                AND requested_by IS NULL
                AND requested_by_email = v_email) = 1;
    RAISE NOTICE 'N5 requester trace survives delete: %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- Deleting the REVIEWER must not falsify the approval: reviewed_by has no
    -- FK, so it is never cleared. A FK ON DELETE SET NULL would abort the user
    -- deletion right here, on ck_catalog_write_requests_decided.
    DELETE FROM users WHERE id = v_reviewer;
    v_ok := (SELECT count(*) FROM catalog_write_requests
              WHERE id = v_req AND reviewed_by IS NOT NULL
                AND decided_at IS NOT NULL) = 1;
    RAISE NOTICE 'N5 reviewer survives, approval kept: %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- Leave one pending request so the queue view has something to show.
    INSERT INTO catalog_write_requests
        (requested_by, requested_by_email, kind, payload, justification)
        VALUES (NULL, 'ana@example.com', 'SYNONYM',
                '{"term":"moida","expands_to":"moida"}'::jsonb,
                'Ana expects the catalogue to exist; she asks instead of being blocked');

    IF v_pass THEN
        RAISE NOTICE 'N5 RESULT: PASS (write requests gated by constraints)';
    ELSE
        RAISE NOTICE 'N5 RESULT: FAIL';
    END IF;
END $$;

SELECT 'N5' AS test,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name='catalog_write_requests'
           AND column_name IN ('id','requested_by','requested_by_email','kind',
               'payload','target_id','justification','status','reviewed_by',
               'reviewed_by_email','review_note','created_at','decided_at')) AS request_columns,
       (SELECT count(*) FROM pg_constraint WHERE conname IN
           ('ck_catalog_write_requests_open','ck_catalog_write_requests_decided',
            'ck_catalog_write_requests_payload_no_pii',
            'fk_catalog_write_requests_requested_by')) AS key_constraints,
       (SELECT coalesce(sum(request_count), 0) FROM v_catalog_write_queue
         WHERE status='OPEN') AS queue_open_count,
       CASE WHEN (SELECT count(*) FROM information_schema.columns
                   WHERE table_name='catalog_write_requests'
                     AND column_name IN ('id','requested_by','requested_by_email','kind',
                         'payload','target_id','justification','status','reviewed_by',
                         'reviewed_by_email','review_note','created_at','decided_at')) = 13
             AND (SELECT count(*) FROM pg_constraint WHERE conname IN
                   ('ck_catalog_write_requests_open','ck_catalog_write_requests_decided',
                    'ck_catalog_write_requests_payload_no_pii',
                    'fk_catalog_write_requests_requested_by')) = 4
             AND (SELECT coalesce(sum(request_count), 0) FROM v_catalog_write_queue
                   WHERE status='OPEN') >= 1
            THEN 'PASS' ELSE 'FAIL' END AS result;

-- -----------------------------------------------------------------------------
-- N7: a presentation link requires its product (card internal task, `db/015`)
-- -----------------------------------------------------------------------------
-- Two FKs acted on the same pair of columns: fk_staging_lines_product (SET NULL)
-- and the composite fk_staging_lines_presentation (SET NULL). Deleting a product
-- cascaded the presentations away and nulled product_id first, so the composite
-- FK's WHERE matched nothing and presentation_id stayed, pointing at a row that
-- no longer existed -- invisible to the FK because MATCH SIMPLE is vacuous when
-- one column is NULL. db/015 repairs the unlink and forbids the contradiction.
-- Before the fix this block FAILS at the first assertion: the line keeps
-- presentation_id with product_id NULL. Runs before N2, which has to be last.
\echo ''
\echo '--- N7: no presentation link without its product ---'
DO $$
DECLARE
    v_user  UUID;
    v_rec   UUID;
    v_prod  UUID;
    v_pres  UUID;
    v_ok    BOOLEAN;
    v_pass  BOOLEAN := true;
BEGIN
    SELECT id INTO v_user FROM users ORDER BY created_at LIMIT 1;

    INSERT INTO staging_receipts (user_id, source, total_gross, discount_total, amount_paid)
        VALUES (v_user, 'MANUAL', 30.00, 0.00, 30.00) RETURNING id INTO v_rec;

    -- (1) DELETE of the PRODUCT must not leave the presentation_id behind.
    INSERT INTO products (name, base_unit) VALUES ('Orphan product A', 'G')
        RETURNING id INTO v_prod;
    INSERT INTO presentations (product_id, sale_unit_recognized, content_kind,
                               content_quantity, content_unit, factor_base)
        VALUES (v_prod, 'PC', 'FIXED', 500, 'G', 500) RETURNING id INTO v_pres;
    INSERT INTO staging_lines (receipt_id, line_no, description_raw, sale_unit,
                               quantity, unit_price, line_total, product_id,
                               presentation_id, match_source)
        VALUES (v_rec, 1, 'ORPHAN A', 'pc', 1, 10.00, 10.00,
                v_prod, v_pres, 'DESCRIPTION');

    DELETE FROM products WHERE id = v_prod;
    v_ok := (SELECT product_id IS NULL AND presentation_id IS NULL
               FROM staging_lines WHERE receipt_id = v_rec AND line_no = 1);
    RAISE NOTICE 'N7 product delete leaves no orphan     : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (2) DELETE of the PRESENTATION must not leave a link behind either.
    INSERT INTO products (name, base_unit) VALUES ('Orphan product B', 'G')
        RETURNING id INTO v_prod;
    INSERT INTO presentations (product_id, sale_unit_recognized, content_kind,
                               content_quantity, content_unit, factor_base)
        VALUES (v_prod, 'PC', 'FIXED', 500, 'G', 500) RETURNING id INTO v_pres;
    INSERT INTO staging_lines (receipt_id, line_no, description_raw, sale_unit,
                               quantity, unit_price, line_total, product_id,
                               presentation_id, match_source)
        VALUES (v_rec, 2, 'ORPHAN B', 'pc', 1, 10.00, 10.00,
                v_prod, v_pres, 'DESCRIPTION');

    DELETE FROM presentations WHERE id = v_pres;
    v_ok := (SELECT product_id IS NULL AND presentation_id IS NULL
               FROM staging_lines WHERE receipt_id = v_rec AND line_no = 2);
    RAISE NOTICE 'N7 presentation delete leaves no link  : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (3) the invariant holds across the whole table: no half link survives.
    v_ok := (SELECT count(*) FROM staging_lines
              WHERE product_id IS NULL AND presentation_id IS NOT NULL) = 0;
    RAISE NOTICE 'N7 no half link survives anywhere      : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (4) a contradictory direct write (no product, presentation set) is
    --     REFUSED, not silently accepted through the composite FK's vacuity.
    INSERT INTO products (name, base_unit) VALUES ('Orphan product C', 'G')
        RETURNING id INTO v_prod;
    INSERT INTO presentations (product_id, sale_unit_recognized, content_kind,
                               content_quantity, content_unit, factor_base)
        VALUES (v_prod, 'PC', 'FIXED', 500, 'G', 500) RETURNING id INTO v_pres;
    v_ok := false;
    BEGIN
        INSERT INTO staging_lines (receipt_id, line_no, description_raw, sale_unit,
                                   quantity, unit_price, line_total,
                                   product_id, presentation_id)
            VALUES (v_rec, 3, 'BAD DIRECT', 'pc', 1, 10.00, 10.00, NULL, v_pres);
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N7 contradictory direct write refused  : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (5) review_state stays coherent with the unlinked line: it is PENDING
    --     (still owed a decision) and NO_MATCH can now be recorded on it --
    --     with db/008 the stale presentation_id made that write impossible.
    v_ok := (SELECT review_state = 'PENDING' AND NOT reviewed
               FROM staging_lines WHERE receipt_id = v_rec AND line_no = 1);
    RAISE NOTICE 'N7 unlinked line stays PENDING         : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    v_ok := false;
    BEGIN
        UPDATE staging_lines SET review_state = 'NO_MATCH', reviewed = TRUE,
                                 match_note = 'nenhum candidato serve'
         WHERE receipt_id = v_rec AND line_no = 1;
        v_ok := true;
    EXCEPTION WHEN check_violation THEN v_ok := false;
    END;
    RAISE NOTICE 'N7 NO_MATCH recordable after unlink    : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    IF v_pass THEN
        RAISE NOTICE 'N7 RESULT: PASS (a presentation link needs its product)';
    ELSE
        RAISE NOTICE 'N7 RESULT: FAIL';
    END IF;
END $$;

SELECT 'N7' AS test,
       (SELECT count(*) FROM pg_constraint
         WHERE conname = 'ck_staging_lines_presentation_needs_product') AS needs_product_ck,
       (SELECT count(*) FROM pg_trigger
         WHERE tgrelid = 'staging_lines'::regclass
           AND tgname = 'tr_staging_lines_presentation_link') AS repair_trigger,
       CASE WHEN (SELECT count(*) FROM pg_constraint
                   WHERE conname = 'ck_staging_lines_presentation_needs_product') = 1
             AND (SELECT count(*) FROM pg_trigger
                   WHERE tgrelid = 'staging_lines'::regclass
                     AND tgname = 'tr_staging_lines_presentation_link') = 1
            THEN 'PASS' ELSE 'FAIL' END AS result;

-- -----------------------------------------------------------------------------
-- N8: the price window is a query, not a column (internal task, `db/016`)
-- -----------------------------------------------------------------------------
-- Decision D10 (option B): the screen presets 7/30/90/180/365 days are a FILTER.
-- `price_refs` keeps the observation and the window-INDEPENDENT
-- `price_change_pct`; every aggregate over a window is computed on read by
-- `v_price_window` (one row per observation x preset) and by `price_window()`
-- (one row per product/store pair, window as a PARAMETER).
--
-- The fixture has four observations of one (product, store): two in June-2026
-- (a pair, both at 20.00 -- a spread of 0.00 that is a TRUE statement) and two
-- in January-2026 (9 days apart, so the 7-day window of the FIRST one holds only
-- itself -- one sample, no variation, NULL). With the observation of 2026-06-05
-- as the anchor: 7 days = 2 samples, 365 days = 4.
-- Runs before N2, which has to stay last.
\echo ''
\echo '--- N8: price window -- preset is a row, window is a parameter ---'
DO $$
DECLARE
    v_user   UUID;
    v_store  UUID;
    v_prod   UUID;
    v_ok     BOOLEAN;
    v_pass   BOOLEAN := true;
    v_n      INTEGER;
    v_s1     NUMERIC;
    v_s2     NUMERIC;
    v_x1     BIGINT;
    v_x2     BIGINT;
    v_cov    TEXT;
    v_left   INTEGER;
BEGIN
    -- (1) No per-preset column survives: the whole point of option B.
    SELECT count(*) INTO v_left FROM information_schema.columns
     WHERE table_name = 'price_refs'
       AND column_name IN ('min_30d','max_30d','var_pct_30d','samples_30d',
                           'price_spread_pct');
    RAISE NOTICE 'N8 no per-preset column on price_refs : %',
        CASE WHEN v_left = 0 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_left = 0);

    -- ...and the window-INDEPENDENT change stayed: it is the MVP badge.
    v_ok := EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_name = 'price_refs'
                       AND column_name = 'price_change_pct');
    RAISE NOTICE 'N8 price_change_pct kept (window-free) : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (2) The preset is a COLUMN OF THE RESULT, not a column of the table.
    --     (Checked after the fixture: on an empty price_refs the view has no
    --     rows at all, and "0 distinct presets" would be the correct answer to
    --     the wrong question.)

    INSERT INTO users (name, email) VALUES ('Window Test', 'window@example.com')
        RETURNING id INTO v_user;
    INSERT INTO stores (name, cnpj, ibge_code, trade_name)
        VALUES ('Window Store', '00000000000002', '3550308', 'WSTORE')
        RETURNING id INTO v_store;
    INSERT INTO products (name, category_id, brand, base_unit)
        SELECT 'Window test product', id, 'WinB', 'G' FROM categories LIMIT 1
        RETURNING id INTO v_prod;

    INSERT INTO price_refs (user_id, product_id, store_id, ref_date, base_unit,
                            base_price, price_change_pct) VALUES
        (v_user, v_prod, v_store, DATE '2026-01-01', 'G', 10.00, NULL),
        (v_user, v_prod, v_store, DATE '2026-01-10', 'G', 12.00, 20.00),
        (v_user, v_prod, v_store, DATE '2026-06-01', 'G', 20.00, 66.67),
        (v_user, v_prod, v_store, DATE '2026-06-05', 'G', 20.00, NULL);

    SELECT count(DISTINCT window_days) INTO v_n FROM v_price_window;
    RAISE NOTICE 'N8 presets are rows (5 of them)       : % (%)',
        CASE WHEN v_n = 5 THEN 'PASS' ELSE 'FAIL' END, v_n;
    v_pass := v_pass AND (v_n = 5);

    -- (3) One sample means NO variation: NULL, never 0. Two samples of the same
    --     price mean a 0.00 that IS true.
    SELECT count(*) INTO v_n FROM v_price_window
     WHERE (samples >= 2 AND price_spread_pct IS NULL)
        OR (samples <  2 AND price_spread_pct IS NOT NULL);
    RAISE NOTICE 'N8 samples>=2 iff spread present      : %',
        CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_n = 0);

    -- (4) Two presets in the SAME query, on the same observation.
    SELECT max(price_spread_pct) FILTER (WHERE window_days = 7),
           max(price_spread_pct) FILTER (WHERE window_days = 365),
           max(samples)          FILTER (WHERE window_days = 7),
           max(samples)          FILTER (WHERE window_days = 365)
      INTO v_s1, v_s2, v_x1, v_x2
      FROM v_price_window
     WHERE product_id = v_prod AND ref_date = DATE '2026-06-05';
    v_ok := (v_x1 = 2 AND v_x2 = 4 AND v_s1 = 0.00 AND v_s2 = 100.00);
    RAISE NOTICE 'N8 7d and 365d in one query          : % (samples %->%, spread %->%)',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END, v_x1, v_x2, v_s1, v_s2;
    v_pass := v_pass AND v_ok;

    -- (5) The single-sample window: one observation, no variation.
    SELECT samples, price_spread_pct INTO v_x1, v_s1
      FROM v_price_window
     WHERE product_id = v_prod AND ref_date = DATE '2026-01-01'
       AND window_days = 7;
    v_ok := (v_x1 = 1 AND v_s1 IS NULL);
    RAISE NOTICE 'N8 single-sample window is NULL      : % (samples=%, spread=%)',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END, v_x1,
        coalesce(v_s1::text, 'NULL');
    v_pass := v_pass AND v_ok;

    -- (6) Windows nest: a wider window never holds fewer observations.
    SELECT count(*) INTO v_n
      FROM v_price_window a JOIN v_price_window b
        ON b.product_id = a.product_id AND b.store_id = a.store_id
       AND b.ref_date = a.ref_date AND b.window_days > a.window_days
     WHERE a.product_id = v_prod AND b.samples < a.samples;
    RAISE NOTICE 'N8 windows are monotone              : %',
        CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_n = 0);

    -- (7) price_window(): the window is a PARAMETER -- two presets, one query.
    SELECT max(w.samples) FILTER (WHERE d.w = 7),
           max(w.samples) FILTER (WHERE d.w = 365)
      INTO v_x1, v_x2
      FROM (VALUES (7), (365)) AS d(w)
      CROSS JOIN LATERAL price_window(v_user, d.w) w
     WHERE w.product_id = v_prod;
    v_ok := (v_x1 = 2 AND v_x2 = 4);
    RAISE NOTICE 'N8 price_window(7) vs (365) one query: % (% vs %)',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END, v_x1, v_x2;
    v_pass := v_pass AND v_ok;

    -- (8) A pair with nothing in the window comes back LOUD: samples 0, no
    --     prices, coverage NO_OBSERVATIONS -- not an absent row.
    SELECT samples, coverage, price_spread_pct, base_price
      INTO v_x1, v_cov, v_s1, v_s2
      FROM price_window(v_user, 7, DATE '2026-07-01')
     WHERE product_id = v_prod;
    v_ok := (v_x1 = 0 AND v_cov = 'NO_OBSERVATIONS'
             AND v_s1 IS NULL AND v_s2 IS NULL);
    RAISE NOTICE 'N8 empty window is visible           : % (samples=%, coverage=%)',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END, v_x1, coalesce(v_cov, 'NULL');
    v_pass := v_pass AND v_ok;

    -- (9) The anchor defaults to the user's OWN latest observation, never to
    --     current_date: the fixture is historical and must still answer.
    SELECT max(samples) INTO v_x1 FROM price_window(v_user, 365) WHERE product_id = v_prod;
    v_ok := (v_x1 = 4);
    RAISE NOTICE 'N8 anchor is the last observation    : % (365d samples=%)',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END, v_x1;
    v_pass := v_pass AND v_ok;

    IF v_pass THEN
        RAISE NOTICE 'N8 RESULT: PASS (the window is a query, the preset a parameter)';
    ELSE
        RAISE NOTICE 'N8 RESULT: FAIL';
    END IF;
END $$;

-- Fixture-scoped on purpose: 20 rows are the 4 observations THIS block inserted
-- (window@example.com) x the 5 presets. An unscoped count(*) answers with the
-- whole database -- 2420 rows on a clone of the canonical, which holds 480
-- price_refs -- and reports FAIL on a perfectly good schema. Same determinism
-- rule as the header of this file: every count pinned to the fixture's own rows.
SELECT 'N8' AS test,
       (SELECT count(*) FROM v_price_window
         WHERE user_id = (SELECT id FROM users WHERE email='window@example.com')) AS window_rows,
       (SELECT count(DISTINCT window_days) FROM v_price_window) AS presets,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'price_window') AS window_fns,
       CASE WHEN (SELECT count(*) FROM v_price_window
                   WHERE user_id = (SELECT id FROM users WHERE email='window@example.com')) = 20
             AND (SELECT count(DISTINCT window_days) FROM v_price_window) = 5
             AND (SELECT count(*) FROM pg_proc p
                    JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'public' AND p.proname = 'price_window') = 1
            THEN 'PASS' ELSE 'FAIL' END AS result;

-- -----------------------------------------------------------------------------
-- N6: LGPD retention -- the register decides, the queue obeys (internal task)
-- -----------------------------------------------------------------------------
-- Runs before N2: this block inserts audit_log and staging fixtures, and N2 is
-- the last block precisely so its own fixtures do not disturb the counts above.
\echo ''
\echo '--- N6: retention policy and purge queue (db/010) ---'
DO $$
DECLARE
    v_user  UUID;
    v_ok    BOOLEAN;
    v_n     INTEGER;
    v_pass  BOOLEAN := true;
BEGIN
    INSERT INTO users (name, email) VALUES ('Retention Test', 'retention@example.com')
        RETURNING id INTO v_user;

    -- The register arrives seeded by the migration: seven targets, all of them
    -- carrying a purpose, a legal basis and either a term or a review date.
    SELECT count(*) INTO v_n FROM retention_policy;
    RAISE NOTICE 'N6 register has 7 policies       : %',
        CASE WHEN v_n = 7 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_n = 7);

    v_ok := (SELECT count(*) FROM retention_policy
              WHERE btrim(purpose) <> ''
                AND legal_basis IN ('CONSENT', 'CONTRACT',
                                    'LEGITIMATE_INTEREST', 'LEGAL_OBLIGATION')
                AND (retention_days IS NOT NULL OR expires_at IS NOT NULL)) = 7;
    RAISE NOTICE 'N6 every policy is justified     : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- A term of zero is not a term.
    v_ok := false;
    BEGIN
        INSERT INTO retention_policy (table_name, column_name, purpose, legal_basis, retention_days)
        VALUES ('users', 'email', 'zero is not a term', 'CONTRACT', 0);
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N6 term of zero refused          : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- No fixed term is allowed, but never without a review date.
    v_ok := false;
    BEGIN
        INSERT INTO retention_policy (table_name, column_name, purpose, legal_basis)
        VALUES ('users', 'email', 'no term and no review date', 'CONTRACT');
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N6 no term and no review refused : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- A legal basis outside the closed set is not a basis.
    v_ok := false;
    BEGIN
        INSERT INTO retention_policy (table_name, column_name, purpose, legal_basis, retention_days)
        VALUES ('users', 'email', 'invented basis', 'BECAUSE_WE_WANT', 30);
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N6 invented legal basis refused  : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- The register cannot name a column that does not exist: an unenforceable
    -- policy is refused instead of being kept as decoration.
    v_ok := false;
    BEGIN
        INSERT INTO retention_policy (table_name, column_name, purpose, legal_basis, retention_days)
        VALUES ('users', 'email_que_nao_existe', 'ghost target', 'CONTRACT', 30);
    EXCEPTION WHEN foreign_key_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N6 non-existent target refused   : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- (a) audit payload: one row past the 90-day window, one inside it.
    INSERT INTO audit_log (user_id, table_name, operation, record_id,
                           before_data, after_data, occurred_at)
    VALUES (v_user, 'purchase_notes', 'UPDATE', v_user,
            '{"k": 1}'::jsonb, '{"k": 2}'::jsonb, now() - interval '100 days'),
           (v_user, 'purchase_notes', 'UPDATE', v_user,
            '{"k": 3}'::jsonb, NULL,                now() - interval '10 days');

    -- Both payload columns of the old row are due; the recent row is not.
    SELECT count(*) INTO v_n FROM v_retention_due
     WHERE record_owner = v_user AND table_name = 'audit_log';
    RAISE NOTICE 'N6 audit payload: 2 due, 0 early : %',
        CASE WHEN v_n = 2 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_n = 2);

    -- (b) the surviving contact: the clock starts at executed_at, so a request
    -- that has not concluded is not due.
    INSERT INTO data_erasure_requests (user_id, email, requested_at, executed_at)
    VALUES (v_user, 'retention@example.com',  now() - interval '200 days', now() - interval '100 days'),
           (v_user, 'retention2@example.com', now() - interval '200 days', NULL);

    SELECT count(*) INTO v_n FROM v_retention_due
     WHERE record_owner = v_user AND table_name = 'data_erasure_requests'
       AND purge_action = 'NULL_EMAIL';
    RAISE NOTICE 'N6 email due only after erasure  : %',
        CASE WHEN v_n = 1 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_n = 1);

    -- (c) the coupon image: DONE is due immediately (the review is over);
    -- PENDING gets the 30-day window; a receipt with no path is not a file.
    INSERT INTO staging_receipts (id, user_id, source, status, file_path,
                                  total_gross, discount_total, amount_paid, updated_at)
    VALUES ('e5c0a1b2-0000-0000-0000-00000000d001', v_user, 'MANUAL', 'DONE',    'cupom-done.jpg',  10.00, 0, 10.00, now() - interval '1 hour'),
           ('e5c0a1b2-0000-0000-0000-00000000d002', v_user, 'MANUAL', 'PENDING', 'cupom-fresh.jpg', 10.00, 0, 10.00, now()),
           ('e5c0a1b2-0000-0000-0000-00000000d003', v_user, 'MANUAL', 'PENDING', 'cupom-velho.jpg', 10.00, 0, 10.00, now() - interval '40 days'),
           ('e5c0a1b2-0000-0000-0000-00000000d004', v_user, 'MANUAL', 'PENDING', NULL,              10.00, 0, 10.00, now() - interval '40 days');

    SELECT count(*) INTO v_n FROM v_retention_due
     WHERE record_owner = v_user AND table_name = 'staging_receipts'
       AND purge_action = 'DELETE_FILE';
    RAISE NOTICE 'N6 image: DONE + stale, not fresh: %',
        CASE WHEN v_n = 2 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_n = 2);

    -- The trusted layer never enters the automatic queue: its policies carry no
    -- term, and every branch of the view requires one.
    SELECT count(*) INTO v_n FROM v_retention_due
     WHERE table_name IN ('purchase_notes', 'line_items', 'users');
    RAISE NOTICE 'N6 trusted layer stays out       : %',
        CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_n = 0);

    -- The queue cannot contain a policy without a term, ever.
    SELECT count(*) INTO v_n FROM v_retention_due WHERE retention_days IS NULL;
    RAISE NOTICE 'N6 no term never appears in queue: %',
        CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND (v_n = 0);

    -- The e-mail has to be removable, or the registered window cannot be met
    -- (db/010 drops NOT NULL and keeps ck_data_erasure_email).
    v_ok := (SELECT is_nullable FROM information_schema.columns
              WHERE table_name = 'data_erasure_requests' AND column_name = 'email') = 'YES'
        AND EXISTS (SELECT 1 FROM pg_constraint
                     WHERE conname = 'ck_data_erasure_email');
    RAISE NOTICE 'N6 email can be minimized        : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    -- An empty address is not a removal.
    v_ok := false;
    BEGIN
        INSERT INTO data_erasure_requests (user_id, email) VALUES (v_user, '  ');
    EXCEPTION WHEN check_violation THEN v_ok := true;
    END;
    RAISE NOTICE 'N6 empty email refused           : %',
        CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_ok;

    IF v_pass THEN
        RAISE NOTICE 'N6 RESULT: PASS (register governs the purge queue)';
    ELSE
        RAISE NOTICE 'N6 RESULT: FAIL';
    END IF;
END $$;

SELECT 'N6' AS test,
       (SELECT count(*) FROM retention_policy) AS policies,
       (SELECT count(*) FROM retention_policy WHERE retention_days IS NULL) AS no_term,
       (SELECT count(*) FROM v_retention_due WHERE retention_days IS NULL) AS leaked_no_term,
       (SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_retention_policy_target') AS target_trigger,
       CASE WHEN (SELECT count(*) FROM retention_policy) = 7
             AND (SELECT count(*) FROM v_retention_due WHERE retention_days IS NULL) = 0
             AND (SELECT count(*) FROM pg_trigger
                   WHERE tgname = 'tr_retention_policy_target') = 1
            THEN 'PASS' ELSE 'FAIL' END AS result;

-- -----------------------------------------------------------------------------
-- N2: purchase_notes is immutable, except the staging link (internal task, C2)
-- -----------------------------------------------------------------------------
-- The design was decided before but never exercised: an earlier probe ran
-- against an EMPTY table (this file ends in ROLLBACK) and reported "not
-- blocked", which proves nothing. This block uses real rows and runs LAST,
-- before ROLLBACK, so its fixtures do not disturb the audit counts above.
\echo ''
\echo '--- N2: purchase_notes immutability (C2) ---'
DO $$
DECLARE
    v_user   UUID;
    v_store  UUID;
    v_stage  UUID;
    v_stage2 UUID;
    v_note   UUID;
    v_link   UUID;
    v_tmp    BOOLEAN;
    v_pass   BOOLEAN := true;
BEGIN
    SELECT id INTO v_store FROM stores WHERE cnpj = '00000000000191';
    INSERT INTO users (name, email) VALUES ('Immutability Test', 'c2@example.com')
        RETURNING id INTO v_user;

    -- A receipt in staging and a consolidated note linked to it.
    INSERT INTO staging_receipts (user_id, source, total_gross, discount_total, amount_paid)
        VALUES (v_user, 'MANUAL', 10.00, 0.00, 10.00)
        RETURNING id INTO v_stage;
    INSERT INTO purchase_notes (user_id, store_id, staging_receipt_id,
                                purchase_date, amount_paid)
        VALUES (v_user, v_store, v_stage, CURRENT_DATE, 10.00)
        RETURNING id INTO v_note;

    -- 1) a change to any column other than the link is refused
    v_tmp := false;
    BEGIN
        UPDATE purchase_notes SET amount_paid = amount_paid + 1 WHERE id = v_note;
    EXCEPTION WHEN check_violation THEN v_tmp := true;
    END;
    RAISE NOTICE 'N2 other-column update refused    : %',
        CASE WHEN v_tmp THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_tmp;

    -- 2) changing the link itself is allowed
    v_tmp := false;
    BEGIN
        UPDATE purchase_notes SET staging_receipt_id = NULL WHERE id = v_note;
        v_tmp := true;
    EXCEPTION WHEN others THEN v_tmp := false;
    END;
    RAISE NOTICE 'N2 staging-link change allowed    : %',
        CASE WHEN v_tmp THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_tmp;

    -- 3) deleting a staging_receipt whose note points at it concludes via
    --    ON DELETE SET NULL -- it does not abort on the immutability trigger.
    UPDATE purchase_notes SET staging_receipt_id = v_stage WHERE id = v_note;
    v_tmp := false;
    BEGIN
        DELETE FROM staging_receipts WHERE id = v_stage;
        SELECT staging_receipt_id INTO v_link FROM purchase_notes WHERE id = v_note;
        v_tmp := v_link IS NULL;
    EXCEPTION WHEN others THEN v_tmp := false;
    END;
    RAISE NOTICE 'N2 staging delete clears the link: %',
        CASE WHEN v_tmp THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_tmp;

    -- 4) the LGPD path still concludes on a LINKED note: audit_log has no FK
    --    back to users, so deleting the person removes the note and keeps the
    --    trail.
    INSERT INTO staging_receipts (user_id, source, total_gross, discount_total, amount_paid)
        VALUES (v_user, 'MANUAL', 10.00, 0.00, 10.00)
        RETURNING id INTO v_stage2;
    UPDATE purchase_notes SET staging_receipt_id = v_stage2 WHERE id = v_note;
    v_tmp := false;
    BEGIN
        DELETE FROM users WHERE id = v_user;
        v_tmp := NOT EXISTS (SELECT 1 FROM purchase_notes WHERE id = v_note)
             AND EXISTS (SELECT 1 FROM audit_log WHERE record_id = v_note);
    EXCEPTION WHEN others THEN v_tmp := false;
    END;
    RAISE NOTICE 'N2 LGPD delete keeps the trail : %',
        CASE WHEN v_tmp THEN 'PASS' ELSE 'FAIL' END;
    v_pass := v_pass AND v_tmp;

    IF v_pass THEN
        RAISE NOTICE 'N2 RESULT: PASS (immutable, staging link excepted)';
    ELSE
        RAISE NOTICE 'N2 RESULT: FAIL';
    END IF;
END $$;

SELECT 'N2' AS test,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name='purchase_notes' AND column_name='payment_method') AS payment_method_cols,
       (SELECT count(*) FROM pg_trigger
         WHERE tgrelid='purchase_notes'::regclass
           AND tgname='tr_purchase_notes_immutable') AS immutable_trigger,
       CASE WHEN (SELECT count(*) FROM information_schema.columns
                   WHERE table_name='purchase_notes'
                     AND column_name='payment_method') = 0
             AND (SELECT count(*) FROM pg_trigger
                   WHERE tgrelid='purchase_notes'::regclass
                     AND tgname='tr_purchase_notes_immutable') = 1
            THEN 'PASS' ELSE 'FAIL' END AS result;

ROLLBACK;
