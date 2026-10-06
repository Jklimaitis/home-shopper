-- =============================================================================
-- home_shopper -- seed: the six scope categories and their declared attributes
-- PostgreSQL 16
--
-- internal task, revised by internal task.
--
-- REVISION BY internal task (2026-10-05): one declared attribute was REMOVED from
--   Laticínios, Mercearia, Bebidas and Padaria, per decision D2 of Jonas: the MVP
--   does not hyper-specify the per-category criteria -- they can be widened in
--   future sprints. The seed went from 14 declarations to 10 (one dropped per
--   category, in those four). The DDL in db/007 is unchanged; only the DATA
--   shrank. The attribute removed is the one PRD §4.3 still lists for those four
--   categories; widening the list later is DATA (INSERT INTO category_attributes),
--   not a migration.
--
-- STATUS: PROPOSAL. NOT APPLIED to the canonical database (home_shopper-db) and
--   NOT merged. Depends on db/007_category_attributes_and_category_rules.sql,
--   which creates the two tables this file fills.
--
-- WHY THIS IS NOT IN db/ (and not named db/00N)
--   CI applies `db/*.sql` in order and then runs tests/smoke_test.sql. That test
--   inserts ONE category and reads it back with the scalar subquery
--   `(SELECT id FROM categories)`:

--       INSERT INTO categories (name) VALUES ('Meat and cold cuts');
--       INSERT INTO products (...) VALUES ('Chicken leg Swift',
--                                          (SELECT id FROM categories), ...);

--   With six seeded rows that subquery returns more than one row and the test
--   errors -- a seed must not be able to break the domain test. A seed is DATA,
--   not schema, so it stays outside the db/ glob and is applied by hand after
--   the go:
--
--     docker exec -i home_shopper-db psql -U home_shopper -d home_shopper \
--         -v ON_ERROR_STOP=1 -f - < seeds/2026-10-05-categories-and-attributes.sql
--
-- SOURCES
--   * the six categories -- PRD.md §6.2.2 and ADR-0001 "Escopo ratificado" item 1.
--     Limpeza / Higiene / Pet are OUT of this cycle: ADR-0001 records that adding
--     them later is DATA, not a migration -- so they are not seeded here. (The
--     2026-10-03 review names Limpeza and Higiene as main categories; that is a
--     scope widening still to be ratified, see the proposal doc §7.)
--   * the declared attributes -- PRD.md §4.3 and the ACCEPTED spec
--     docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md.
--     `brand` is NOT seeded: it lives in products.brand (spec R5).
--     `formulation` (padaria) is NOT seeded: the spec marks it PROPOSTA, not
--     grounded in §3.2/§4.2.
--     One attribute that PRD §4.3 still lists is NOT seeded: decision D2 of
--     Jonas (2026-10-05) removed it from the MVP scope, so Laticínios,
--     Mercearia, Bebidas and Padaria are each one declaration short of the PRD
--     list. Widening the list later is DATA (INSERT INTO category_attributes),
--     not a migration. (The attribute key is deliberately not spelled out here:
--     internal task requires this file to have zero matches for it.)
--
-- WHY parent_id IS NULL FOR ALL SIX
--   The six are top-level. The parentheticals in PRD §6.2.2 -- "(leite, iogurte,
--   queijo)", "(enlatados, massas, etc.)" -- are illustrative EXAMPLES, not
--   required children. Seeding subcategories would put invented names into the
--   global `categories` namespace and leave them with no declared attributes
--   (every attribute would read "not applies"). The hierarchy stays available
--   (categories.parent_id) and unused until there is a grounded reason to use it.
--
-- The category ids are FIXED so anything referencing a category -- and parent_id
-- itself -- is stable across runs. The seed is idempotent: re-running changes
-- nothing (matched on the normalised name).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The six scope categories
-- -----------------------------------------------------------------------------
INSERT INTO categories (id, name, parent_id)
SELECT v.id, v.name, NULL
FROM (VALUES
    ('9f1c0000-0000-4000-8000-000000000001'::uuid, 'Laticínios'),
    ('9f1c0000-0000-4000-8000-000000000002'::uuid, 'Carnes'),
    ('9f1c0000-0000-4000-8000-000000000003'::uuid, 'Mercearia'),
    ('9f1c0000-0000-4000-8000-000000000004'::uuid, 'Bebidas'),
    ('9f1c0000-0000-4000-8000-000000000005'::uuid, 'Hortifruti'),
    ('9f1c0000-0000-4000-8000-000000000006'::uuid, 'Padaria')
) AS v(id, name)
WHERE NOT EXISTS (
    SELECT 1
      FROM categories c
     WHERE lower(btrim(c.name)) = lower(btrim(v.name))
);

-- -----------------------------------------------------------------------------
-- 2. The declared attributes of each category
-- -----------------------------------------------------------------------------
-- These rows ARE the "authoritative list" the three-state semantics needs: an
-- attribute with no product_attributes row and a declaration here means
-- UNKNOWN (PENDENTE when the other side informs it); no declaration means
-- "not applies" (ignored). brand is absent on purpose (products.brand).
INSERT INTO category_attributes (category_id, attribute, value_kind)
SELECT c.id, v.attribute, v.value_kind
FROM (VALUES
    ('Laticínios', 'fat_content',  'TEXT'),
    ('Laticínios', 'lactose_free', 'BOOLEAN'),
    ('Carnes',     'species',      'TEXT'),
    ('Carnes',     'cut',          'TEXT'),
    ('Carnes',     'seasoning',    'TEXT'),
    ('Mercearia',  'product_type', 'TEXT'),
    ('Mercearia',  'variant',      'TEXT'),
    ('Bebidas',    'type',         'TEXT'),
    ('Hortifruti', 'variety',      'TEXT'),
    ('Padaria',    'type',         'TEXT')
) AS v(category_name, attribute, value_kind)
JOIN categories c
  ON lower(btrim(c.name)) = lower(btrim(v.category_name))
WHERE NOT EXISTS (
    SELECT 1
      FROM category_attributes ca
     WHERE ca.category_id = c.id
       AND ca.attribute   = v.attribute
);

-- -----------------------------------------------------------------------------
-- 3. Self-check -- the seed refuses to end in a half-loaded state
-- -----------------------------------------------------------------------------
-- Makes the seed assert its own result instead of leaving a silent gap: the six
-- categories must exist and all ten declarations must be present.
DO $$
DECLARE
    v_categories   INTEGER;
    v_attributes   INTEGER;
BEGIN
    SELECT count(*) INTO v_categories
      FROM categories
     WHERE lower(btrim(name)) IN
           ('laticínios', 'carnes', 'mercearia', 'bebidas', 'hortifruti', 'padaria');

    SELECT count(*) INTO v_attributes
      FROM category_attributes ca
      JOIN categories c ON c.id = ca.category_id
     WHERE lower(btrim(c.name)) IN
           ('laticínios', 'carnes', 'mercearia', 'bebidas', 'hortifruti', 'padaria');

    IF v_categories <> 6 THEN
        RAISE EXCEPTION 'category seed incomplete: % of 6 categories present', v_categories;
    END IF;
    IF v_attributes <> 10 THEN
        RAISE EXCEPTION 'attribute seed incomplete: % of 10 declarations present', v_attributes;
    END IF;
END $$;

COMMIT;
