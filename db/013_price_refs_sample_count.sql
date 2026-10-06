-- =============================================================================
-- home_shopper -- part 7: sample count on price_refs
-- PostgreSQL 16
--
-- internal task. The batch that populates price_refs (scripts/load_price_refs.py)
-- computes min_30d / max_30d over a 30-day window per (user, product, store,
-- base_unit). ADR-0003 leaves one thing open: the NUMBER OF SAMPLES a window
-- needs before min_30d / max_30d may drive an alert ("alertar sobre uma unica
-- compra e ficcao", ADR-0003 Consequencias; PRD 6.4). That number is a product
-- decision (internal task), not this card's.
--
-- WHAT THIS ADDS AND WHY IT IS A COLUMN
--   samples_30d = how many aggregated (day) price points the window held -- the
--   count of values min_30d / max_30d were taken over. It must be written BY the
--   batch, because the window is relative to each row's ref_date: once the row
--   is stored, the count cannot be recovered from price_refs alone without
--   re-deriving the whole window. Without it the minimum-sample threshold cannot
--   be applied at alert time -- the job would have min/max and no way to know
--   whether they rest on one purchase or twelve.
--
--   A view was the alternative. It would recompute the window from
--   v_price_aggregation on every read -- the per-query cost price_refs exists to
--   avoid -- and price_refs is populated by job precisely so the analytics read
--   is cheap. The count is a property of the observation, so it belongs on it.
--
-- WHY THIS IS A NEW MIGRATION AND NOT AN EDIT OF 002
--   002 is already applied and published: the canonical database ran it, and a
--   fresh `db/*.sql` in order has to reach the same final state. Editing 002 to
--   add the column AND shipping this file would make a fresh database fail with
--   "column samples_30d already exists". A new file carries both databases
--   (empty canonical today, any future rebuild) through the same code path. This
--   is the same rule db/006 followed for presentation_identifiers.
--
-- WHY NOT NULL AND WHY DEFAULT 1
--   The batch is the only writer of price_refs (ADR-0003 5: "populado por job,
--   nao por trigger") and it always writes the measured count, which is >= 1
--   because the window includes the row's own ref_date. DEFAULT 1 exists only so
--   the ALTER is safe on any database that already holds rows; it does not
--   substitute for the measurement and is overwritten on the next batch run.
--   NULL is not allowed: an absent count is exactly the state that makes the
--   minimum undecidable, and the whole point of the column is to resolve it.
-- =============================================================================

BEGIN;

ALTER TABLE price_refs
    ADD COLUMN samples_30d INTEGER NOT NULL DEFAULT 1;

ALTER TABLE price_refs
    -- A window always holds at least the row's own observation; 0 is not a
    -- count the batch can produce.
    ADD CONSTRAINT ck_price_refs_samples_30d CHECK (samples_30d >= 1);

COMMENT ON COLUMN price_refs.samples_30d IS
    'Aggregated (day) price points in the 30-day window ending at ref_date. '
    'Written by scripts/load_price_refs.py so the alert job can apply the '
    'minimum-sample threshold ADR-0003 leaves open.';

COMMIT;
