-- =============================================================================
-- home_shopper -- supermarket price monitor
-- Bootstrap schema, part 1: strong entities and the product catalogue
-- PostgreSQL 16
--
-- CONVENTIONS (see docs/DECISIONS.md for the reasoning behind each)
--   * snake_case, lowercase, English identifiers
--   * Tables in the PLURAL (Django/Rails/Laravel convention)
--   * Every constraint is NAMED:
--       pk_<table>              primary key
--       fk_<child>_<parent>     foreign key
--       uk_<table>_<columns>    uniqueness
--       ck_<table>_<rule>       check
--     A named constraint is what makes an error message actionable.
--     Postgres would otherwise emit "line_items_total_check", which says
--     nothing about which business rule was violated.
--   * 3NF: every column depends on the key, the whole key, nothing but
--     the key.
--
-- NON-NEGOTIABLE RULES
--   1. Money is NUMERIC, never float.
--   2. Prices are only comparable after being re-expressed in the
--      product's base unit (see presentations.factor_base).
--   3. Extracted data (staging) never writes straight to the trusted
--      layer. It passes through human review first.
--   4. user_id on every business table: multi-tenancy and LGPD.
--   5. No BLOB. Coupon images live on disk; only a path is stored.
--
-- EVIDENCE
--   Grounded in the NFC-e receipt format (42 line items) of a single
--   store. Anonymised fixture: fixtures/.
--
-- Creation order follows the dependency hierarchy: strong entities
-- first, then weak ones, then associative tables.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- -----------------------------------------------------------------------------
-- ENUMS
-- -----------------------------------------------------------------------------
CREATE TYPE ingestion_source AS ENUM
    ('MANUAL', 'QRCODE', 'SEFAZ', 'OCR', 'IMPORT');

-- Base unit of COMPARISON. Always the SMALLEST unit of the product's
-- dimension -- an invariant of the schema, not a suggestion:
--
--   mass    -> G    (flour in g, beef in g)
--   volume  -> ML   (milk in ml, oil in ml)
--   count   -> UN   (tissues, batteries -- indivisible)
--
-- 'KG' and 'L' deliberately DO NOT EXIST. If they did, a MIN or MAX
-- across '0.0299 in G' and '29.9 in KG' would compare the same magnitude
-- in different scales: a thousandfold error, silent, with no type error
-- because both are NUMERIC.
CREATE TYPE base_unit AS ENUM ('UN', 'G', 'ML');

CREATE TYPE consolidation_status AS ENUM
    ('PENDING', 'IN_REVIEW', 'DONE', 'DISCARDED');

-- How a staging line found its canonical product. Doubles as the
-- learning signal for improving the synonym table.
CREATE TYPE match_source AS ENUM
    ('BARCODE', 'DESCRIPTION', 'ALIAS', 'MANUAL', 'NONE');

-- -----------------------------------------------------------------------------
-- STRONG ENTITIES
-- -----------------------------------------------------------------------------

CREATE TABLE users (
    id          UUID        NOT NULL DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    email       TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_users       PRIMARY KEY (id),
    CONSTRAINT uk_users_email UNIQUE (email)
);

CREATE TABLE stores (
    id         UUID        NOT NULL DEFAULT gen_random_uuid(),
    name       TEXT        NOT NULL,
    -- Brazilian taxpayer id: 14 digits, unformatted.
    cnpj       CHAR(14)    NOT NULL,
    -- IBGE municipality code. Region-level matching needs it; the trade
    -- name does not.
    ibge_code  CHAR(7),
    trade_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_stores      PRIMARY KEY (id),
    CONSTRAINT uk_stores_cnpj UNIQUE (cnpj),
    CONSTRAINT ck_stores_cnpj CHECK (cnpj ~ '^[0-9]{14}$'),
    -- 7 digits is the IBGE municipality code width.
    CONSTRAINT ck_stores_ibge CHECK (ibge_code IS NULL OR ibge_code ~ '^[0-9]{7}$')
);

CREATE TABLE categories (
    id         UUID        NOT NULL DEFAULT gen_random_uuid(),
    name       TEXT        NOT NULL,
    -- Self-reference: subcategories hang off their parent.
    parent_id  UUID,

    CONSTRAINT pk_categories        PRIMARY KEY (id),
    CONSTRAINT uk_categories_name   UNIQUE (name),
    CONSTRAINT fk_categories_parent FOREIGN KEY (parent_id)
        REFERENCES categories(id) ON DELETE SET NULL
);

-- -----------------------------------------------------------------------------
-- Product catalogue
-- -----------------------------------------------------------------------------
-- A product is the identity of WHAT was bought. It is a GLOBAL
-- catalogue, shared across users by design -- see docs/DECISIONS.md
-- (ADR-004) for why this is not a tenant leak.
--
-- A product is NOT the receipt description and NOT the store's internal
-- code. Both change; the product does not.
-- -----------------------------------------------------------------------------
CREATE TABLE products (
    id           UUID        NOT NULL DEFAULT gen_random_uuid(),
    name         TEXT        NOT NULL,
    category_id  UUID,
    brand        TEXT,
    -- Global Trade Item Number. Absent in 0 of 42 real line items, so it
    -- is opportunistic, never the key.
    ean          TEXT,
    -- Smallest unit this product is compared in. The conversion factor
    -- lives in presentations.factor_base, NOT here: the unit of PURCHASE
    -- changes between stores, the comparison base does not.
    base_unit    base_unit   NOT NULL DEFAULT 'UN',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_products PRIMARY KEY (id),
    -- NULLS NOT DISTINCT: without it, "CUPIM COMBO" with brand NULL can
    -- exist N times, because Postgres treats NULLs as distinct in UNIQUE.
    -- products is the logical key of presentations, line_items and
    -- price_refs, so each duplicate carries a different factor and the
    -- dashboard ends up comparing incomparable prices.
    CONSTRAINT uk_products_name_brand
        UNIQUE NULLS NOT DISTINCT (name, brand),
    CONSTRAINT fk_products_category FOREIGN KEY (category_id)
        REFERENCES categories(id) ON DELETE SET NULL
);

-- -----------------------------------------------------------------------------
-- Synonyms: partial word -> canonical word
-- -----------------------------------------------------------------------------
-- The receipts showed why this is needed: the same product appears under
-- a different name in every store.
--
--   'CARNE MOIDA COMBO 1kg'   (receipt A, R$ 29,90)
--   'MOIDA COMBO 1KG'         (receipt B, R$ 27,90)
--
-- Normalising text cannot bridge that: no string rule turns one into the
-- other. Equivalence is a LEARNED FACT, and a learned fact lives in a
-- table, not in code.
--
-- Difference in relation to presentations: a synonym links
-- WORD -> WORD. A presentation links FULL DESCRIPTION -> PRODUCT.
-- Different granularities, both necessary.
-- -----------------------------------------------------------------------------
CREATE TABLE synonyms (
    id          UUID        NOT NULL DEFAULT gen_random_uuid(),
    term        TEXT        NOT NULL,
    expands_to  TEXT        NOT NULL,
    -- NULL = global. Frequent enough that UNIQUE must treat it as a value.
    scope       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_synonyms               PRIMARY KEY (id),
    CONSTRAINT uk_synonyms_term_scope
        UNIQUE NULLS NOT DISTINCT (term, scope)
);

-- -----------------------------------------------------------------------------
-- Presentations: the lookup table AND the unit conversion, in one
-- -----------------------------------------------------------------------------
-- The truncated receipt description ("LEITE UHT HERC CX 12UN") already
-- carries how many base units the pack holds. Splitting the alias from the
-- conversion factor into two tables would duplicate the data and let the
-- two drift apart. Here they stay together by construction.
--
-- There is deliberately NO store-internal product code here. The 7-digit
-- code printed on the receipt belongs to the EMITTER: the same cut of beef
-- carries a different code at every CNPJ, and this project exists to
-- compare BETWEEN stores. A matching key that changes between the stores
-- you want to compare is not a key -- it is confident noise. The code
-- stays in staging_lines, where it speeds up matching during capture, and
-- is not propagated.
--
-- Consequence accepted: two stores need two presentations of the same
-- product, one per store's wording. That is the honest cost. What
-- separates stores is how they name things, not a number each invents.
-- -----------------------------------------------------------------------------
CREATE TABLE presentations (
    id               UUID         NOT NULL DEFAULT gen_random_uuid(),
    product_id       UUID         NOT NULL,
    -- Unit as written on the receipt: "UN", "CX", "KG", "PC".
    sale_unit        TEXT         NOT NULL,
    -- How many base units there are in 1 sale_unit.
    --   1 UN of milk = 1000 ML  => 1000
    --   1 CX of 12 UN = 12000 ML => 12000
    factor_base      NUMERIC(14,6) NOT NULL,
    -- Raw description as printed, kept for audit.
    description_raw  TEXT         NOT NULL,
    -- Lowercased, accent-stripped version: what the search matches on.
    description_norm TEXT         NOT NULL,
    -- Matching key.
    -- The ORDER of the functions matters: lower() BEFORE regexp_replace.
    -- Inverted, the regex [^a-z0-9 ] strips every UPPERCASE letter
    -- (receipt descriptions are uppercase) and only the number survives:
    --   'COXA DE FRANGO SWIFT 1 kg' -> '    1 kg'
    -- In the real note, COXA DE FRANGO and MOELA FRANGO -- two different
    -- products -- collided on that key.
    -- '[^a-z0-9]+' -> ' ' collapses runs so '1 kg', '1kg' and '1  kg'
    -- all produce the same key.
    match_key        TEXT         GENERATED ALWAYS AS
        (regexp_replace(lower(description_norm), '[^a-z0-9]+', ' ', 'g')) STORED,
    -- NULL = global wording, usable in any store.
    store_id         UUID,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT pk_presentations PRIMARY KEY (id),
    -- NULLS NOT DISTINCT: store_id NULL means "global", which is the most
    -- frequent case and exactly where a plain UNIQUE stops protecting
    -- anything.
    CONSTRAINT uk_presentations_product_key_store
        UNIQUE NULLS NOT DISTINCT (product_id, match_key, store_id),
    -- Target of the composite FK from line_items and staging_lines: makes
    -- the database itself guarantee the presentation belongs to the stated
    -- product. Without it, coherence would depend only on a trigger, and
    -- staging -- where the matcher errs -- accepted the inconsistent pair.
    CONSTRAINT uk_presentations_id_product UNIQUE (id, product_id),

    CONSTRAINT fk_presentations_product FOREIGN KEY (product_id)
        REFERENCES products(id) ON DELETE CASCADE,
    CONSTRAINT fk_presentations_store   FOREIGN KEY (store_id)
        REFERENCES stores(id) ON DELETE CASCADE,
    CONSTRAINT ck_presentations_factor    CHECK (factor_base > 0),
    CONSTRAINT ck_presentations_sale_unit CHECK (sale_unit ~ '^[A-Za-z]{1,4}$')
);

COMMIT;
