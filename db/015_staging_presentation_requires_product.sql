-- =============================================================================
-- home_shopper -- part 15: a staging line may not keep a presentation link
--                  without the product that link belongs to
-- PostgreSQL 16
--
-- Card internal task. Finding F-1 of the internal task review (`internal task`,
-- `db/008`): after a product is deleted, `staging_lines.presentation_id` keeps
-- pointing at a `presentations` row that no longer exists. NOT a db/008
-- regression -- it reproduces on `db/001..006` alone.
--
-- WHY THIS IS A NEW MIGRATION AND NOT AN EDIT OF 001, 002 OR 006
--   `002` (staging_lines) and `001` (presentations) are already applied and
--   published: the canonical database ran them and everyone who applies
--   `db/*.sql` in order has to reach the same final state. Editing them would
--   make the canonical database and a fresh one diverge. A new file carries
--   both through the same code path. The number is 015 because 007..013 were
--   taken by the integration branch (internal task) and 014 by the price-variation
--   migration, merged to `main` as `661e9ba` (<internal PR>) after this file was first
--   numbered. This migration does not depend on any of them and stacks on 008
--   (internal task). Renumbering history: 009 -> 014 (internal task, 009 was taken by
--   db/009_catalog_write_requests.sql), then 014 -> 015 (2026-10-06, 014 taken by
--   db/014_price_variation_columns.sql). See
--   docs/decisions/2026-10-06-renumeracao-db014-db015.md.
--
-- THE BUG (reproduced, not supposed)
--   Two foreign keys act on the same pair of columns:
--     fk_staging_lines_product        (product_id)                  ON DELETE SET NULL
--     fk_staging_lines_presentation   (presentation_id, product_id) ON DELETE SET NULL
--   and fk_presentations_product is ON DELETE CASCADE, so deleting a product
--   also deletes its presentations. The single-column SET NULL fires first and
--   sets product_id = NULL; by the time the composite FK's action runs, its
--   WHERE (presentation_id, product_id) = (...) matches no row, so
--   presentation_id is never cleared. Under MATCH SIMPLE the composite FK is
--   then vacuously satisfied (one NULL column disables the check), so the
--   database cannot see the orphan it just created.
--
--   Measured consequence with db/008 in place:
--     * the orphaned line sits at review_state='PENDING' with product_id NULL
--       and a presentation_id that resolves to zero rows;
--     * ck_staging_lines_no_match demands presentation_id IS NULL, so recording
--       "no candidate fits" is REFUSED unless the screen also clears the stale
--       presentation_id;
--     * re-linking the line to a new product that keeps the stale
--       presentation_id is REJECTED by the composite FK.
--
-- WHY A TRIGGER AND NOT A COLUMN-LIST SET NULL
--   PostgreSQL 15+ allows ON DELETE SET NULL (presentation_id), which would stop
--   the composite FK from nulling product_id too. It does NOT fix this bug: when
--   the product's CASCADE deletes the presentation, the single-column FK can
--   still run first, and the composite FK still fails to match on a row whose
--   product_id is already NULL. The fix has to react to the actual transition
--   `product_id` -> NULL, whichever key caused it, and that is a trigger.
--
-- THE INVARIANT THIS ESTABLISHES
--   A presentation link is meaningful only under a product: the composite FK
--   guarantees the presentation belongs to the product, and this migration adds
--   the missing half -- presentation_id may not be set while product_id is NULL.
--   Together they make an orphan impossible, on every write path:
--     * INSERT  -- a contradictory (product_id NULL, presentation_id set) row is
--                  REFUSED by the new CHECK, loudly, instead of leaking through
--                  the composite FK's MATCH SIMPLE vacuity;
--     * UPDATE  -- the same CHECK. A genuine unlink of the product (its deletion
--                  fires the FK's SET NULL as an UPDATE) is repaired by the
--                  BEFORE UPDATE trigger, so the DELETE concludes instead of
--                  aborting on the CHECK.
--   The trigger looks at OLD on purpose, like db/008's: only a line that HAD a
--   product and lost it is repaired. A direct write that tries to create the
--   contradiction is left to the CHECK so the mistake fails loudly rather than
--   being silently coerced.
--
-- IDEMPOTENT. The guard and the cleanup are no-ops on a second run; the trigger
--   and the CHECK are dropped-if-exists and recreated. No data is lost: the
--   cleanup only clears a pointer to a presentation that is already gone, and
--   the line stays in its review state (PENDING / SKIPPED both remain valid
--   without a link).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Guard: a reviewed line cannot hold half a link
-- -----------------------------------------------------------------------------
-- A reviewed line is CONFIRMED (full link) or NO_MATCH (no link and a reason):
-- db/008's CHECKs forbid anything else, so a reviewed row with product_id NULL
-- and presentation_id set should already be impossible. If one exists the
-- database was written around those constraints, and quietly nulling the
-- presentation would hide it: name the rows and stop, the same way section 3 of
-- db/008 does.
DO $$
DECLARE
    v_bad    INTEGER;
    v_sample TEXT;
BEGIN
    SELECT count(*) INTO v_bad
      FROM staging_lines
     WHERE reviewed
       AND product_id IS NULL
       AND presentation_id IS NOT NULL;

    IF v_bad > 0 THEN
        SELECT string_agg(id::text, ', ' ORDER BY line_no) INTO v_sample
          FROM (SELECT id, line_no
                  FROM staging_lines
                 WHERE reviewed
                   AND product_id IS NULL
                   AND presentation_id IS NOT NULL
                 ORDER BY line_no
                 LIMIT 5) s;
        RAISE EXCEPTION
            'db/015: % reviewed line(s) keep a presentation link with no product '
            '(a half link no review state can express); resolve them first. '
            'First ids: %', v_bad, v_sample
            USING ERRCODE = '23514';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Clean up the orphans that already exist (idempotent)
-- -----------------------------------------------------------------------------
-- Any line with product_id NULL and presentation_id set is an orphan: the
-- composite FK never validated that pair. The presentation is gone (or, on a
-- database written around the FK, meaningless), so clearing the pointer is the
-- only honest repair -- and it keeps the line in PENDING/SKIPPED, which both
-- allow a line without a link. The rows are named before they are touched, so
-- the cleanup is visible rather than silent.
DO $$
DECLARE
    v_orph   INTEGER;
    v_sample TEXT;
BEGIN
    SELECT count(*) INTO v_orph
      FROM staging_lines
     WHERE product_id IS NULL
       AND presentation_id IS NOT NULL;

    IF v_orph > 0 THEN
        SELECT string_agg(id::text, ', ' ORDER BY line_no) INTO v_sample
          FROM (SELECT id, line_no
                  FROM staging_lines
                 WHERE product_id IS NULL
                   AND presentation_id IS NOT NULL
                 ORDER BY line_no
                 LIMIT 5) s;
        RAISE NOTICE
            'db/015: clearing the orphaned presentation_id of % staging line(s) '
            'whose product is gone. First ids: %', v_orph, v_sample;
    END IF;
END $$;

UPDATE staging_lines
   SET presentation_id = NULL
 WHERE product_id IS NULL
   AND presentation_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 3. Close the write path: repair the unlink, then enforce the invariant
-- -----------------------------------------------------------------------------
-- BEFORE UPDATE so the corrected NEW passes the CHECK below. The condition is
-- the genuine transition (had a product, lost it): that is exactly what the
-- FK's ON DELETE SET NULL performs, whether the product was deleted directly or
-- its presentations cascaded away. An outright contradictory write never
-- reaches here as a repair -- it falls through to the CHECK and fails loudly.
CREATE OR REPLACE FUNCTION clear_orphaned_presentation_link() RETURNS TRIGGER AS $$
BEGIN
    IF OLD.product_id IS NOT NULL AND NEW.product_id IS NULL THEN
        NEW.presentation_id := NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_staging_lines_presentation_link ON staging_lines;
CREATE TRIGGER tr_staging_lines_presentation_link
    BEFORE UPDATE ON staging_lines
    FOR EACH ROW EXECUTE FUNCTION clear_orphaned_presentation_link();

-- The declarative half of the invariant. With the trigger in place it holds on
-- every UPDATE; it is also what makes a contradictory INSERT fail loudly instead
-- of slipping past the composite FK's MATCH SIMPLE vacuity. ADD CONSTRAINT
-- validates the existing rows, which section 2 already made compliant.
ALTER TABLE staging_lines
    DROP CONSTRAINT IF EXISTS ck_staging_lines_presentation_needs_product;
ALTER TABLE staging_lines
    ADD CONSTRAINT ck_staging_lines_presentation_needs_product
        CHECK (presentation_id IS NULL OR product_id IS NOT NULL);

COMMIT;
