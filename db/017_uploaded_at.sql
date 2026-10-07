-- =============================================================================
-- home_shopper -- migration: add uploaded_at to purchase_notes
-- PostgreSQL 16
--
-- internal task (card internal task).
--
-- WHY THIS EXISTS
--   purchase_date for 11 of 15 notes was extracted from the access key (AAMM),
--   which only encodes month/year — not the exact day. The other 4 notes have
--   the exact date from the receipt header.
--
--   uploaded_at records when the user registered the note in the system.
--   It is always exact and provides a second temporal reference:
--     - purchase_date = when the user bought (approximate for 11 notes)
--     - uploaded_at   = when the user registered (always exact)
--
--   For MVP, month/year is sufficient for price trend analysis. The exact day
--   is only critical for "price dropped today" alerts, which is a future
--   requirement.
--
-- IDEMPOTENCY
--   The column is added with a DEFAULT of now() for existing rows, so
--   re-running this migration is a no-op (IF NOT EXISTS).
-- =============================================================================

BEGIN;

ALTER TABLE purchase_notes
    ADD COLUMN IF NOT EXISTS uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now();

COMMENT ON COLUMN purchase_notes.uploaded_at IS
    'Timestamp when the user registered the note. Always exact. '
    'purchase_date may be approximate (month/year only) for notes '
    'whose date was extracted from the access key.';

COMMIT;
