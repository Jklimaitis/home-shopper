-- =============================================================================
-- home_shopper -- part 5: the presentation FORM / SOURCE split
-- PostgreSQL 16
--
-- internal task. Implements the decisions registered in
--   docs/decisions/2026-10-05-apresentacoes-conteudo-unidade-embalagem.md  (segment 1)
--   docs/decisions/2026-10-05-apresentacoes-forma-mapeamento-gtin.md       (J1-J4)
--   <internal review>        (colunas/unicidade/FKs)
--
-- WHY THIS IS A MIGRATION AND NOT AN EDIT OF 001-004
--   001-004 are the bootstrap that produced the deployed schema. Everyone who
--   applies `db/*.sql` in order (the CI does exactly that) has to reach the same
--   final state as the canonical database, and the canonical database already
--   holds 393 presentations. A migration file is the one artefact that carries
--   both databases -- a fresh one and the loaded one -- through the same code
--   path, so there is no second copy of the DDL to drift.
--
-- WHAT CHANGES
--   * presentations becomes the COMMERCIAL FORM: product, content, packaging,
--     factor and the recognised sale unit. It stops holding the store's wording.
--   * presentation_sources (new) is the per-store MAPPING: raw text, verbatim
--     sale unit and the match key, pointing at the form.
--   * presentation_identifiers (new) holds N GTINs per presentation; the
--     single, always-NULL products.ean goes away (J2).
--   * ck_presentations_sale_unit and ck_staging_lines_sale_unit stop demanding
--     1-4 letters: a raw receipt label like `CX 10`, `c/N` or `FRASCO` is a
--     fiscal fact, not a schema error (segment 1, decision 2; review Ponto B).
--
-- NO DATA IS LOST. Every wording that lived in presentations moves to
--   presentation_sources. The only rows removed are the DUPLICATE FORMS Ponto A
--   forbids (`cenoura kg` at three stores was three presentations with the same
--   product and the same factor_base). Their text survives as three source rows
--   and their line_items are re-pointed at the surviving form -- same factor,
--   so base_price is untouched (the trigger is disabled for the re-point).
--
--   On a fresh/empty database the data block matches nothing and is a no-op;
--   the DDL is what both databases get.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. New enums
-- -----------------------------------------------------------------------------
-- content_kind (segment 1, decision 1): FIXED / VARIABLE / UNKNOWN.
--   UNKNOWN is an honest "not interpreted yet" -- never zero, never invented.
CREATE TYPE content_kind AS ENUM ('FIXED', 'VARIABLE', 'UNKNOWN');

-- container_type (segment 1, decision 3): the individual container.
CREATE TYPE container_type AS ENUM ('cx', 'pc', 'pct', 'sc', 'lt', 'un');

-- sale_unit_recognized (segment 1, decision 2; J4): the CONTROLLED vocabulary
--   the raw label is recognised into. The raw label itself is preserved
--   verbatim in presentation_sources.sale_unit. Case does not change the unit
--   (ADR-0001 rule 11): `UN`/`un` and `KG`/`kg` are the same unit.
--   Only labels the loader can confirm are members. Anything else stays NULL
--   and goes to review -- `BJ`, `FRC`, `LT` do not become a meaning by spell.
CREATE TYPE sale_unit_recognized AS ENUM
    ('UN', 'KG', 'G', 'ML', 'L', 'PC', 'CX', 'PCT', 'SC', 'LT', 'FD', 'DZ');

-- -----------------------------------------------------------------------------
-- 2. presentation_sources -- the per-store mapping (J1)
-- -----------------------------------------------------------------------------
CREATE TABLE presentation_sources (
    id                 UUID        NOT NULL DEFAULT gen_random_uuid(),
    presentation_id    UUID        NOT NULL,
    -- NULL = a wording usable in any store. Today no such row exists.
    store_id           UUID,
    -- Verbatim, as printed on the receipt. Only requirement: not empty.
    sale_unit          TEXT        NOT NULL,
    -- Verbatim, no substitutions (Ponto C).
    description_raw    TEXT        NOT NULL,
    -- The ONE derived search representation (Ponto C), supplied by the loader.
    description_search TEXT        NOT NULL,
    -- The match key, derived from the search representation. The ORDER matters:
    -- lower() BEFORE regexp_replace. Inverted, the regex strips every uppercase
    -- letter (receipts are uppercase) and only the number survives:
    --   'COXA DE FRANGO SWIFT 1 kg' -> '    1 kg'
    -- and two different products collided on the same key on a receipt.
    match_key          TEXT        GENERATED ALWAYS AS
        (regexp_replace(lower(description_search), '[^a-z0-9]+', ' ', 'g')) STORED,
    -- How the link was confirmed. Reuses the enum that already exists.
    match_source       match_source,
    -- Has a human confirmed that this wording points at this form?
    reviewed           BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_presentation_sources PRIMARY KEY (id),
    -- NULLS NOT DISTINCT: store_id NULL means "global wording", the case a
    -- plain UNIQUE stops protecting. One wording per store -> one form; several
    -- wordings -> one form is the whole point of the split (Ponto A).
    CONSTRAINT uk_presentation_sources_store_key
        UNIQUE NULLS NOT DISTINCT (store_id, match_key),
    -- The store owns the MAPPING, not the form: deleting a store no longer
    -- deletes the commercial form (the gain recorded in review §5).
    CONSTRAINT fk_presentation_sources_presentation FOREIGN KEY (presentation_id)
        REFERENCES presentations(id) ON DELETE CASCADE,
    CONSTRAINT fk_presentation_sources_store FOREIGN KEY (store_id)
        REFERENCES stores(id) ON DELETE CASCADE,
    -- Moved from presentations: only non-empty, no 1-4 letter shape.
    CONSTRAINT ck_presentation_sources_sale_unit CHECK (btrim(sale_unit) <> ''),
    CONSTRAINT ck_presentation_sources_description CHECK (btrim(description_raw) <> '')
);

-- -----------------------------------------------------------------------------
-- 3. presentation_identifiers -- N GTINs per presentation (J2)
-- -----------------------------------------------------------------------------
CREATE TABLE presentation_identifiers (
    id              UUID        NOT NULL DEFAULT gen_random_uuid(),
    presentation_id UUID        NOT NULL,
    -- GTIN-8/12/13/14. The check digit is NOT expressible in regex; it is
    -- verified at load/review time, never inferred.
    gtin            TEXT        NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_presentation_identifiers PRIMARY KEY (id),
    -- Global: one GTIN identifies ONE commercial item, unlike a store code.
    CONSTRAINT uk_presentation_identifiers_gtin UNIQUE (gtin),
    CONSTRAINT fk_presentation_identifiers_presentation FOREIGN KEY (presentation_id)
        REFERENCES presentations(id) ON DELETE CASCADE,
    CONSTRAINT ck_presentation_identifiers_gtin CHECK (gtin ~ '^[0-9]{8,14}$')
);

-- -----------------------------------------------------------------------------
-- 4. presentations becomes the commercial form
-- -----------------------------------------------------------------------------
ALTER TABLE presentations
    -- NOT NULL + DEFAULT in one step (J3): the 393 existing rows become UNKNOWN,
    -- which is the honest value for "not interpreted yet".
    ADD COLUMN content_kind         content_kind  NOT NULL DEFAULT 'UNKNOWN',
    -- ONE pair content_quantity/content_unit, defined once (content_unit reuses
    -- the existing base_unit enum: UN/G/ML).
    ADD COLUMN content_quantity     NUMERIC(14,6),
    ADD COLUMN content_unit         base_unit,
    ADD COLUMN container_type       container_type,
    ADD COLUMN multipack_quantity   INTEGER,
    ADD COLUMN sale_unit_recognized sale_unit_recognized,
    ADD COLUMN updated_at           TIMESTAMPTZ   NOT NULL DEFAULT now();

-- Recognise the raw label into the controlled vocabulary for the values that
-- carry no ambiguity. Everything else stays NULL (funnel to review).
UPDATE presentations
   SET sale_unit_recognized = upper(btrim(sale_unit))::sale_unit_recognized
 WHERE upper(btrim(sale_unit)) IN
       ('UN', 'KG', 'G', 'ML', 'L', 'PC', 'CX', 'PCT', 'SC', 'LT', 'FD', 'DZ');

-- Move the store's wording out of the form and into the mapping. No-op when the
-- database is empty.
INSERT INTO presentation_sources
    (presentation_id, store_id, sale_unit, description_raw, description_search,
     match_source, reviewed, created_at, updated_at)
SELECT id, store_id, sale_unit, description_raw, description_norm,
       NULL, FALSE, created_at, created_at
FROM presentations;

-- -----------------------------------------------------------------------------
-- 5. Collapse duplicate forms (Ponto A)
-- -----------------------------------------------------------------------------
-- A form is the tuple uk_presentations_form guards. Two rows with the same
-- tuple ARE the same form; keeping both would violate the key the decision
-- demands and would keep the very duplication Ponto A forbids. One row per
-- tuple survives; every source and line item is re-pointed at it.
CREATE TEMP TABLE tmp_pres_form_survivor ON COMMIT DROP AS
SELECT product_id,
       sale_unit_recognized, content_kind, content_quantity, content_unit,
       container_type, multipack_quantity,
       min(id::text)::uuid AS survivor_id
FROM presentations
GROUP BY product_id, sale_unit_recognized, content_kind, content_quantity,
         content_unit, container_type, multipack_quantity;

-- Guard: collapsing must never hide a divergent factor. If two forms of one
-- tuple disagree on factor_base, stop -- that is a domain conflict, not a
-- mechanical duplicate.
DO $$
DECLARE v_bad INTEGER;
BEGIN
    SELECT count(*) INTO v_bad
      FROM (SELECT 1
              FROM presentations
             GROUP BY product_id, sale_unit_recognized, content_kind,
                      content_quantity, content_unit, container_type,
                      multipack_quantity
            HAVING count(DISTINCT factor_base) > 1) AS conflict;
    IF v_bad > 0 THEN
        RAISE EXCEPTION
            'duplicate forms with divergent factor_base in % group(s): resolve before migrating',
            v_bad;
    END IF;
END $$;

UPDATE presentation_sources s
   SET presentation_id = m.survivor_id
  FROM presentations p
  JOIN tmp_pres_form_survivor m
    ON m.product_id            = p.product_id
   AND m.sale_unit_recognized IS NOT DISTINCT FROM p.sale_unit_recognized
   AND m.content_kind          = p.content_kind
   AND m.content_quantity     IS NOT DISTINCT FROM p.content_quantity
   AND m.content_unit         IS NOT DISTINCT FROM p.content_unit
   AND m.container_type       IS NOT DISTINCT FROM p.container_type
   AND m.multipack_quantity   IS NOT DISTINCT FROM p.multipack_quantity
 WHERE s.presentation_id = p.id
   AND p.id <> m.survivor_id;

-- Re-point the charges. base_price is frozen history (review §6): the trigger
-- that recomputes it is disabled for the move so the value is left EXACTLY as
-- stored -- the factors are equal by the guard above, so nothing would change,
-- but "nunca recomputar base_price histórico" is a rule, not a coincidence.
ALTER TABLE line_items DISABLE TRIGGER tr_line_items_base_price;
UPDATE line_items li
   SET presentation_id = m.survivor_id
  FROM presentations p
  JOIN tmp_pres_form_survivor m
    ON m.product_id            = p.product_id
   AND m.sale_unit_recognized IS NOT DISTINCT FROM p.sale_unit_recognized
   AND m.content_kind          = p.content_kind
   AND m.content_quantity     IS NOT DISTINCT FROM p.content_quantity
   AND m.content_unit         IS NOT DISTINCT FROM p.content_unit
   AND m.container_type       IS NOT DISTINCT FROM p.container_type
   AND m.multipack_quantity   IS NOT DISTINCT FROM p.multipack_quantity
 WHERE li.presentation_id = p.id
   AND p.id <> m.survivor_id;
ALTER TABLE line_items ENABLE TRIGGER tr_line_items_base_price;

UPDATE staging_lines sl
   SET presentation_id = m.survivor_id
  FROM presentations p
  JOIN tmp_pres_form_survivor m
    ON m.product_id            = p.product_id
   AND m.sale_unit_recognized IS NOT DISTINCT FROM p.sale_unit_recognized
   AND m.content_kind          = p.content_kind
   AND m.content_quantity     IS NOT DISTINCT FROM p.content_quantity
   AND m.content_unit         IS NOT DISTINCT FROM p.content_unit
   AND m.container_type       IS NOT DISTINCT FROM p.container_type
   AND m.multipack_quantity   IS NOT DISTINCT FROM p.multipack_quantity
 WHERE sl.presentation_id = p.id
   AND p.id <> m.survivor_id;

DELETE FROM presentations p
 USING tmp_pres_form_survivor m
 WHERE p.id <> m.survivor_id
   AND m.product_id            = p.product_id
   AND m.sale_unit_recognized IS NOT DISTINCT FROM p.sale_unit_recognized
   AND m.content_kind          = p.content_kind
   AND m.content_quantity     IS NOT DISTINCT FROM p.content_quantity
   AND m.content_unit         IS NOT DISTINCT FROM p.content_unit
   AND m.container_type       IS NOT DISTINCT FROM p.container_type
   AND m.multipack_quantity   IS NOT DISTINCT FROM p.multipack_quantity;

-- -----------------------------------------------------------------------------
-- 6. Drop what moved out of presentations
-- -----------------------------------------------------------------------------
ALTER TABLE presentations
    DROP CONSTRAINT uk_presentations_product_key_store,
    DROP CONSTRAINT ck_presentations_sale_unit,
    DROP CONSTRAINT fk_presentations_store,
    -- match_key is a generated column and depends on description_norm, so it
    -- must be dropped BEFORE the column it derives from.
    DROP COLUMN match_key,
    DROP COLUMN description_raw,
    DROP COLUMN description_norm,
    DROP COLUMN sale_unit,
    DROP COLUMN store_id;
-- The indexes on the dropped columns (idx_presentations_key,
-- idx_presentations_store, idx_presentations_unit) go away with their columns.

-- -----------------------------------------------------------------------------
-- 7. New constraints on the form
-- -----------------------------------------------------------------------------
ALTER TABLE presentations
    -- The FORM is independent of store: no store_id in the key.
    -- NULLS NOT DISTINCT treats content_quantity NULL as a value, so
    -- UNKNOWN/VARIABLE do not produce duplicate rows.
    ADD CONSTRAINT uk_presentations_form UNIQUE NULLS NOT DISTINCT
        (product_id, sale_unit_recognized, content_kind, content_quantity,
         content_unit, container_type, multipack_quantity),
    -- Quantity is non-null IF AND ONLY IF the content is FIXED.
    ADD CONSTRAINT ck_presentations_content CHECK (
        (content_kind = 'FIXED'     AND content_quantity IS NOT NULL)
     OR (content_kind <> 'FIXED'    AND content_quantity IS NULL)),
    -- A "multipack of 1" is not a multipack.
    ADD CONSTRAINT ck_presentations_multipack CHECK (
        multipack_quantity IS NULL OR multipack_quantity > 1);

-- -----------------------------------------------------------------------------
-- 8. J2: products.ean goes away
-- -----------------------------------------------------------------------------
-- ean was a single column at the wrong level (product), NULL in all 384 rows,
-- and cannot express "presentations of one product carry different GTINs".
-- The GTIN now lives in presentation_identifiers.
DROP INDEX uq_products_ean;
ALTER TABLE products DROP COLUMN ean;

-- -----------------------------------------------------------------------------
-- 9. The sale-unit constraint on staging_lines is loosened with its twin
-- -----------------------------------------------------------------------------
-- The same legacy regex lived here. A captured line may legitimately carry
-- `CX 10` or `c/N` (multipack extraction) and must reach review instead of
-- being rejected at capture. staging_lines is empty today; the fix is shared.
ALTER TABLE staging_lines DROP CONSTRAINT ck_staging_lines_sale_unit;
ALTER TABLE staging_lines ADD CONSTRAINT ck_staging_lines_sale_unit
    CHECK (btrim(sale_unit) <> '');

-- -----------------------------------------------------------------------------
-- 10. Triggers (they depend on the columns added above, so they live here)
-- -----------------------------------------------------------------------------
CREATE TRIGGER tr_presentations_touch
    BEFORE UPDATE ON presentations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER tr_presentation_sources_touch
    BEFORE UPDATE ON presentation_sources
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The form had ZERO triggers: a correction of factor_base was invisible
-- (review §6, verified). A correction must leave a trace. Only a real change of
-- the form-defining fields is logged -- inserting the catalogue or touching
-- updated_at is not an audit event.
CREATE OR REPLACE FUNCTION write_presentation_audit_entry() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND (
           NEW.factor_base          IS DISTINCT FROM OLD.factor_base
        OR NEW.content_kind         IS DISTINCT FROM OLD.content_kind
        OR NEW.content_quantity     IS DISTINCT FROM OLD.content_quantity
        OR NEW.content_unit         IS DISTINCT FROM OLD.content_unit
        OR NEW.container_type       IS DISTINCT FROM OLD.container_type
        OR NEW.multipack_quantity   IS DISTINCT FROM OLD.multipack_quantity
        OR NEW.sale_unit_recognized IS DISTINCT FROM OLD.sale_unit_recognized
    ) THEN
        INSERT INTO audit_log
            (user_id, table_name, operation, record_id, before_data, after_data)
        VALUES (current_setting('app.user_id', true)::UUID,
                TG_TABLE_NAME, 'UPDATE', NEW.id, to_jsonb(OLD), to_jsonb(NEW));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_presentations_audit
    AFTER UPDATE ON presentations
    FOR EACH ROW EXECUTE FUNCTION write_presentation_audit_entry();

-- -----------------------------------------------------------------------------
-- 11. Indexes for the new tables
-- -----------------------------------------------------------------------------
CREATE INDEX idx_presentation_sources_presentation
    ON presentation_sources (presentation_id);
CREATE INDEX idx_presentation_sources_store
    ON presentation_sources (store_id) WHERE store_id IS NOT NULL;
CREATE INDEX idx_presentation_sources_key
    ON presentation_sources (match_key);
CREATE INDEX idx_presentation_identifiers_presentation
    ON presentation_identifiers (presentation_id);

COMMIT;
