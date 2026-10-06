-- =============================================================================
-- home_shopper -- part 7: category/product attributes and the approved
-- categories rules
-- PostgreSQL 16
--
-- internal task.
--
-- STATUS: PROPOSAL. NOT APPLIED to the canonical database (home_shopper-db) and
--   NOT merged. It exists so the design can be reviewed before any "go" from
--   Jonas. The classification of every gap (L1..L9) -- including the ones that
--   are NOT a table -- is in
--   <internal review>.
--
-- WHY A NEW FILE AND NOT AN EDIT OF 001-006
--   001-006 are the applied bootstrap. Editing them would make the canonical
--   database and a fresh one diverge -- the exact drift db/005 and db/006 exist
--   to prevent. A new file carries BOTH databases through the same code path.
--   CI applies `db/*.sql` in order, so this file is exercised against a
--   throwaway database by CI; that is not the canonical database.
--
-- WHAT IT CONTAINS
--   L1   category_attributes + product_attributes -- the EAV the ACCEPTED
--        category-equivalence spec requires: "Semântica de três estados por
--        atributo" (docs/superpowers/specs/2026-10-01-product-equivalence-by-
--        category.md), sourced from ADR-0001 L101, target internal task-A.
--   L3b  the `categories` rules approved by Jonas on 2026-10-03 but never
--        applied (<internal review>, section
--        "categories"). Structural, so it belongs with the DDL.
--
-- The DATA half of L1 and L3 (the six categories and their declared attributes)
-- lives in seeds/2026-10-05-categories-and-attributes.sql, NOT here -- see the
-- header of that file for why a seed must stay out of the db/ glob.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- L1. category_attributes -- the authoritative list of attributes per category
-- -----------------------------------------------------------------------------
-- The whole reason this table must exist is the three-state semantics the spec
-- fixes:
--   known        -> a row in product_attributes, with a value
--   unknown      -> NO row, AND the attribute IS declared for the category
--   not applies  -> NO row, AND the attribute is NOT declared for the category
--
-- Without the declaration list, "unknown" and "not applies" are the same bytes,
-- and the spec's acceptance criterion #13 ("os três estados são distinguíveis")
-- cannot be met. The list is authoritative: an attribute declared for a category
-- that does not apply to one product of that category produces a false PENDENTE
-- -- a known open point, not hidden here.
--
-- `brand` is deliberately ABSENT: it lives in products.brand (spec R5, "um fato,
-- um lugar" from db/001_schema.sql). A second home would be a second source of
-- truth for the same fact.
--
-- `is_required` is ABSENT on purpose: the technical ruling (6th round) removed
-- it. Applicability comes from the attribute EXISTING for the category; a second
-- flag would be the second source of truth just rejected.
CREATE TABLE category_attributes (
    id          UUID        NOT NULL DEFAULT gen_random_uuid(),
    category_id UUID        NOT NULL,
    -- snake_case key: fat_content, lactose_free, species, ...
    attribute   TEXT        NOT NULL,
    -- Declared metadata, NOT a second value: the value itself lives in
    -- product_attributes. It tells the review UI (spec UX §4) how to render a
    -- candidate's value -- 'BOOLEAN' for lactose_free-style flags, 'TEXT'
    -- otherwise. The XOR in product_attributes only guarantees exactly one value
    -- column is set; that the column MATCHES this kind is a modelling rule the
    -- spec does not yet require at the DB level (see the proposal doc, §6).
    value_kind  TEXT        NOT NULL DEFAULT 'TEXT',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_category_attributes PRIMARY KEY (id),
    -- One declaration per attribute per category.
    CONSTRAINT uk_category_attributes_category_attribute
        UNIQUE (category_id, attribute),
    CONSTRAINT fk_category_attributes_category FOREIGN KEY (category_id)
        REFERENCES categories(id) ON DELETE CASCADE,
    -- The attribute key is a controlled vocabulary, not free text. The CHECK is
    -- shape-only: the LIST is data (the seed), not a schema enum, because the
    -- list of a category is expected to grow and is authoritative per category.
    CONSTRAINT ck_category_attributes_attribute
        CHECK (attribute ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT ck_category_attributes_value_kind
        CHECK (value_kind IN ('TEXT', 'BOOLEAN'))
);

-- Note: uk_category_attributes_category_attribute is also the TARGET of the
-- composite FK below. That composite FK is what makes it impossible to store a
-- product value for an attribute the category never declared -- the difference
-- between "unknown" and "not applies" is then enforced by the database, not by
-- the application remembering to check.

-- Target of the composite FK from product_attributes BELOW. products.id is
-- already unique on its own; the PAIR is required because an FK must name the
-- exact column list it references, and it must exist BEFORE the FK is declared.
-- Redundant as a key, necessary as a FK target -- and it is a key, not a value,
-- so it is not a second source of truth.
ALTER TABLE products
    ADD CONSTRAINT uk_products_id_category UNIQUE (id, category_id);

-- -----------------------------------------------------------------------------
-- L1. product_attributes -- the KNOWN value of a declared attribute, per product
-- -----------------------------------------------------------------------------
-- One row = one known value. Absence of the row is the unknown / not-applies
-- state, read against category_attributes -- the spec is explicit: "desconhecido
-- é representado por ausência de linha, não por linha vazia". That is exactly
-- why the XOR below requires exactly one value and refuses both-NULL: an empty
-- row would be a value that is simultaneously absent and present.
--
-- category_id is carried here (denormalised) for ONE reason: it is the only way
-- to let the database guarantee that the attribute is declared for the category
-- the product actually belongs to. fk_product_attributes_product keeps it EQUAL
-- to products.category_id, so it is not a second source of truth -- it is the
-- same fact, enforced.
--
-- Consequence, accepted: a product with category_id NULL can hold no attributes.
-- That is correct -- with no category there is no authoritative attribute list,
-- so nothing is declared and nothing can be "unknown".
--
-- ON UPDATE RESTRICT on fk_product_attributes_product is deliberate.
-- Reclassifying a product may invalidate its attributes (an attribute declared
-- for the old category need not exist in the new one). RESTRICT forces that to
-- be handled explicitly instead of silently propagating a now-meaningless value
-- or letting the category_attributes FK abort the reclassification mid-statement.
CREATE TABLE product_attributes (
    id             UUID        NOT NULL DEFAULT gen_random_uuid(),
    product_id     UUID        NOT NULL,
    category_id    UUID        NOT NULL,
    attribute      TEXT        NOT NULL,
    value_text     TEXT,
    value_boolean  BOOLEAN,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_product_attributes PRIMARY KEY (id),
    -- One value per product per attribute. A second row would be a second value
    -- for one fact.
    CONSTRAINT uk_product_attributes_product_attribute
        UNIQUE (product_id, attribute),
    -- Keeps category_id equal to products.category_id.
    CONSTRAINT fk_product_attributes_product FOREIGN KEY (product_id, category_id)
        REFERENCES products(id, category_id) ON DELETE CASCADE ON UPDATE RESTRICT,
    -- The attribute must be declared for that category.
    CONSTRAINT fk_product_attributes_category_attribute
        FOREIGN KEY (category_id, attribute)
        REFERENCES category_attributes(category_id, attribute) ON DELETE CASCADE,
    -- Exactly one of the two value columns. Both NULL -> empty row, refused.
    -- Both set -> two values for one fact, refused.
    CONSTRAINT ck_product_attributes_exactly_one_value
        CHECK ((value_text IS NULL) <> (value_boolean IS NULL)),
    CONSTRAINT ck_product_attributes_value_text
        CHECK (value_text IS NULL OR btrim(value_text) <> '')
);

-- -----------------------------------------------------------------------------
-- L3b. categories -- the rules Jonas approved on 2026-10-03, still not applied
-- -----------------------------------------------------------------------------
-- Source: <internal review>, section "categories".
-- The review approved the RULES and stated they were not applied to the schema.
-- They are structure, so they are proposed here:
--   * uniqueness ignores case and surrounding blanks, KEEPS accents;
--   * non-blank name, in a NAMED check;
--   * parent_id indexed;
--   * deleting a category is refused while products or subcategories point at
--     it (the current ON DELETE SET NULL is what the review says must go).
ALTER TABLE categories
    DROP CONSTRAINT uk_categories_name,
    DROP CONSTRAINT fk_categories_parent;

-- Uniqueness on the normalised name. lower() + btrim() only: the review is
-- explicit that accents are NOT removed -- 'Laticínios' keeps its í.
CREATE UNIQUE INDEX uq_categories_name_norm
    ON categories (lower(btrim(name)));

ALTER TABLE categories
    ADD CONSTRAINT ck_categories_name_not_blank
        CHECK (btrim(name) <> ''),
    -- A category cannot be its own parent. A multi-level cycle (A -> B -> A) is
    -- NOT expressible in a CHECK and is left open -- the review lists it as an
    -- approved rule with no mechanism; the honest shape is a trigger, which is
    -- not a table and is therefore out of this card (see the proposal doc §6).
    ADD CONSTRAINT ck_categories_parent_not_self
        CHECK (parent_id IS DISTINCT FROM id),
    -- RESTRICT, not SET NULL: a category with live products or children must be
    -- reorganised before it can go.
    ADD CONSTRAINT fk_categories_parent FOREIGN KEY (parent_id)
        REFERENCES categories(id) ON DELETE RESTRICT;

CREATE INDEX idx_categories_parent ON categories (parent_id);

-- products: the same approval applied to the other side ("bloquear exclusão
-- enquanto houver produtos ... vinculados"). RESTRICT here also keeps the
-- composite FK from product_attributes coherent: with SET NULL, deleting a
-- category would try to null products.category_id while product_attributes still
-- referenced the (id, category_id) pair, and the delete would abort on the
-- product_attributes FK -- an ordering-dependent failure. RESTRICT removes the
-- interaction by refusing the delete up front.
ALTER TABLE products
    DROP CONSTRAINT fk_products_category;
ALTER TABLE products
    ADD CONSTRAINT fk_products_category FOREIGN KEY (category_id)
        REFERENCES categories(id) ON DELETE RESTRICT;

-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------
-- product_attributes is the only new table with updated_at. There is no
-- audit trigger here on purpose: product_attributes is catalogue data, and
-- db/003 keeps the catalogue out of the purchase-audit log so the log does not
-- fill with noise. category_attributes has no updated_at, so no touch trigger.
CREATE TRIGGER tr_product_attributes_touch
    BEFORE UPDATE ON product_attributes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;
