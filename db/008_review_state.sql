-- =============================================================================
-- home_shopper -- part 8: the review decision on staging_lines
-- PostgreSQL 16
--
-- internal task. Implements decision D1 of Jonas (2026-10-05): OPTION 2 of the
-- three routes listed in PRD 13.7 / UX spec 6 -- a dedicated review-decision
-- column carrying the three explicit states (confirmed / not-any / deferred).
--
-- WHY THIS IS A NEW MIGRATION AND NOT AN EDIT OF 002 OR 004
--   002 (staging_lines) and 004 (v_review_queue) are already applied and
--   published: the canonical database ran them, and everyone who applies
--   `db/*.sql` in order has to reach the same final state. Editing them would
--   make the canonical database and a fresh one diverge. A new file carries
--   both databases through the same code path. The number is 008 because 007
--   is taken by internal task; the two migrations do not touch each other.
--
-- THE GAP THIS CLOSES (UX spec 6, PRD F10)
--   * "never reviewed" and "reviewed, no match" both lived in
--     product_id IS NULL, match_source='NONE'. The difference existed only in
--     `reviewed`, and without `match_note` the screen could not tell the two
--     apart when it reopened the note.
--   * "deferred" (pular) was not representable at all: any write would take
--     the line out of `lines_to_review` and treat it as resolved.
--   `discarded` is REJECTED for this purpose: compute_receipt_divergence()
--   (003) sums WHERE NOT discarded, so using it for a review state would
--   change the receipt's `total_computed`.
--
-- WHAT CHANGES
--   * new enum `review_state`: PENDING / CONFIRMED / NO_MATCH / SKIPPED
--   * staging_lines.review_state, NOT NULL DEFAULT 'PENDING'
--   * the coherence rule tying review_state to the legacy `reviewed` flag
--   * the per-state rules (CONFIRMED needs the link; NO_MATCH needs no link
--     and a reason; PENDING and SKIPPED are not decisions)
--   * a BEFORE UPDATE trigger: when the product/presentation link is cleared
--     (ON DELETE SET NULL -- a deleted product), a CONFIRMED decision cannot
--     survive without the thing it confirmed, so the line goes back to PENDING
--     instead of aborting the product delete.
--   * v_review_queue gains `lines_skipped` and expresses `lines_to_review`
--     through review_state (same number, self-documenting).
--
-- STATE SEMANTICS
--   PENDING    never reviewed by a human. reviewed = FALSE. The line stays in
--              the review queue. This includes a line the matcher linked
--              automatically and nobody has confirmed yet.
--   CONFIRMED  a human confirmed the link. product_id and presentation_id
--              NOT NULL, reviewed = TRUE. Leaves the queue.
--   NO_MATCH   a human decided no candidate fits. No link, reviewed = TRUE,
--              `match_note` carries the reason. Leaves the queue.
--   SKIPPED    a human saw the line and deferred it. reviewed = FALSE, so it
--              comes back in the queue on reopen -- deferral, not a decision
--              (UX spec 5; ADR-0002 "Permitir salvar o progresso e retomar a
--              revisao").
--   `reviewed` is not dropped: it is the name the UX spec (5) and PRD F09
--   already use, and it is what v_review_queue read. Keeping it as the legacy
--   mirror, tied to review_state by a CHECK, avoids two sources of truth
--   while leaving today's readers untouched.
--
-- WHY THE CARD'S match_source = 'MANUAL' IS NOT ENFORCED
--   The card proposed CONFIRMED to require match_source='MANUAL'. Read against
--   the DDL it does not hold: match_source is documented in 001 as "How a
--   staging line found its canonical product" -- the PROVENANCE of the link,
--   not the review decision. PRD F09 says the confirm screen WRITES 'MANUAL';
--   that is a rule for the screen, not an invariant of the row. Enforcing it
--   would forbid confirming an automatically proposed candidate (BARCODE /
--   DESCRIPTION / ALIAS) without rewriting the provenance that explains why the
--   link was proposed -- destroying the learning signal the column exists for.
--   CONFIRMED therefore requires the LINK, and leaves match_source free to
--   record whatever found it.
--
-- NO DATA IS LOST. The ALTER only adds a column; every existing row keeps its
--   id and its values. The state is derived from columns that already exist.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The new enum
-- -----------------------------------------------------------------------------
-- PENDING first: it is the DEFAULT and the honest "nothing decided yet" value.
CREATE TYPE review_state AS ENUM ('PENDING', 'CONFIRMED', 'NO_MATCH', 'SKIPPED');

-- -----------------------------------------------------------------------------
-- 2. The column
-- -----------------------------------------------------------------------------
-- NOT NULL DEFAULT 'PENDING': every existing line is, honestly, undecided until
-- the migration in section 4 classifies it.
ALTER TABLE staging_lines
    ADD COLUMN review_state review_state NOT NULL DEFAULT 'PENDING';

-- -----------------------------------------------------------------------------
-- 3. Guard: refuse to migrate rows the new states cannot express
-- -----------------------------------------------------------------------------
-- A row that was reviewed must land in CONFIRMED or NO_MATCH. If it was
-- reviewed but has neither a complete link nor a reason (match_note), there is
-- no honest state for it: inventing a reason or half a link is worse than
-- stopping. staging_lines is empty in the canonical database, so this passes
-- there; on any other database it names the rows instead of coercing them.
DO $$
DECLARE
    v_bad    INTEGER;
    v_sample TEXT;
BEGIN
    SELECT count(*) INTO v_bad
      FROM staging_lines
     WHERE reviewed
       AND NOT (
              (product_id IS NOT NULL AND presentation_id IS NOT NULL)
           OR (product_id IS NULL AND presentation_id IS NULL
               AND coalesce(btrim(match_note), '') <> '')
       );

    IF v_bad > 0 THEN
        SELECT string_agg(id::text, ', ' ORDER BY line_no) INTO v_sample
          FROM (SELECT id, line_no
                  FROM staging_lines
                 WHERE reviewed
                   AND NOT (
                          (product_id IS NOT NULL AND presentation_id IS NOT NULL)
                       OR (product_id IS NULL AND presentation_id IS NULL
                           AND coalesce(btrim(match_note), '') <> '')
                   )
                 ORDER BY line_no
                 LIMIT 5) s;
        RAISE EXCEPTION
            'review_state: % reviewed line(s) cannot be expressed as CONFIRMED '
            'or NO_MATCH (half a link, or no match_note); resolve them first. '
            'First ids: %', v_bad, v_sample
            USING ERRCODE = '23514';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Migrate the existing rows (idempotent)
-- -----------------------------------------------------------------------------
-- The mapping the card fixed, read off the columns that already exist:
--   reviewed AND linked      -> CONFIRMED
--   reviewed AND not linked  -> NO_MATCH
--   everything else          -> PENDING (the default)
-- The WHERE makes it idempotent: a row already classified is never revisited,
-- and a row that is legitimately PENDING maps to PENDING again.
UPDATE staging_lines
   SET review_state = CASE
           WHEN NOT reviewed           THEN 'PENDING'::review_state
           WHEN product_id IS NOT NULL THEN 'CONFIRMED'::review_state
           ELSE                             'NO_MATCH'::review_state
       END
 WHERE review_state = 'PENDING';

-- -----------------------------------------------------------------------------
-- 5. The constraints, every one of them named
-- -----------------------------------------------------------------------------
ALTER TABLE staging_lines
    -- `reviewed` is not a second source of truth: it is the legacy mirror of
    -- the decision, and this ties it to the column that now owns the decision.
    -- A "reviewed" line is exactly one carrying a decision; PENDING and
    -- SKIPPED are not decisions.
    ADD CONSTRAINT ck_staging_lines_review_state_reviewed
        CHECK (reviewed = (review_state IN ('CONFIRMED', 'NO_MATCH'))),
    -- A confirmation is a claim about a LINK: without product and presentation
    -- it would be indistinguishable from NO_MATCH -- the exact collapse this
    -- migration exists to remove. The composite FK already guarantees the
    -- presentation belongs to the product; this guarantees there IS one.
    ADD CONSTRAINT ck_staging_lines_confirmed
        CHECK (review_state <> 'CONFIRMED'
               OR (product_id IS NOT NULL AND presentation_id IS NOT NULL)),
    -- Rejecting every candidate is a decision with a REASON (PRD F09). The
    -- link must be genuinely absent -- a leftover link would make the state a
    -- lie -- and match_note carries the why.
    ADD CONSTRAINT ck_staging_lines_no_match
        CHECK (review_state <> 'NO_MATCH'
               OR (product_id IS NULL AND presentation_id IS NULL
                   AND coalesce(btrim(match_note), '') <> ''));

-- -----------------------------------------------------------------------------
-- 6. Keep a CONFIRMED decision honest when its link disappears
-- -----------------------------------------------------------------------------
-- fk_staging_lines_product and the composite presentation FK are ON DELETE SET
-- NULL: deleting a product (or a presentation) clears the link on every staging
-- line that pointed at it. ck_staging_lines_confirmed forbids a confirmed line
-- without a link, so WITHOUT this trigger the DELETE would abort on a CHECK
-- violation -- the same shape of bug the composite FK in 006 was designed to
-- avoid. A confirmation cannot survive the disappearance of what it confirmed,
-- so the line goes back to PENDING and is queued for review again.
--
-- The condition looks at OLD on purpose: only a confirmation that HAD a link
-- and lost it is demoted. A write that tries to mark CONFIRMED a line that was
-- never linked is NOT repaired here -- it is left to ck_staging_lines_confirmed
-- so the mistake fails loudly instead of being silently turned into PENDING.
-- BEFORE UPDATE, so the corrected NEW passes the CHECKs.
CREATE OR REPLACE FUNCTION demote_unlinked_confirmed_line() RETURNS TRIGGER AS $$
BEGIN
    IF OLD.review_state = 'CONFIRMED'
       AND OLD.product_id IS NOT NULL
       AND OLD.presentation_id IS NOT NULL
       AND (NEW.product_id IS NULL OR NEW.presentation_id IS NULL) THEN
        NEW.review_state := 'PENDING';
        NEW.reviewed     := FALSE;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_staging_lines_review_state_unlink
    BEFORE UPDATE ON staging_lines
    FOR EACH ROW EXECUTE FUNCTION demote_unlinked_confirmed_line();

-- -----------------------------------------------------------------------------
-- 7. Index for the queue's "still owed a decision" set
-- -----------------------------------------------------------------------------
-- v_review_queue counts the lines still owed a decision (PENDING + SKIPPED).
-- idx_staging_lines_unmatched (004) covers product_id IS NULL; this one answers
-- the state question per receipt.
CREATE INDEX idx_staging_lines_review_pending
    ON staging_lines (receipt_id)
    WHERE review_state IN ('PENDING', 'SKIPPED');

-- -----------------------------------------------------------------------------
-- 8. v_review_queue: say how many lines are deferred vs never seen
-- -----------------------------------------------------------------------------
-- Same columns, same order, plus `lines_skipped`. `lines_to_review` keeps
-- counting both PENDING and SKIPPED -- a deferred line is still owed a
-- decision, so the note is not complete (ADR-0002 "Consolidacao parcial"); the
-- new count is what lets the screen say "vista e adiada" instead of "nunca
-- vista" (PRD F10).
CREATE OR REPLACE VIEW v_review_queue AS
SELECT
    sr.id AS staging_receipt_id,
    sr.user_id,
    sr.source,
    sr.status,
    sr.total_gross,
    sr.discount_total,
    sr.amount_paid,
    sr.total_computed,
    sr.divergence_cents,
    s.name AS store_name,
    count(sl.id) FILTER (WHERE sl.product_id IS NULL AND NOT sl.discarded)
        AS unmatched_lines,
    count(sl.id) FILTER (WHERE sl.review_state IN ('PENDING', 'SKIPPED')
                           AND NOT sl.discarded)
        AS lines_to_review,
    count(sl.id) AS total_lines,
    count(sl.id) FILTER (WHERE sl.review_state = 'SKIPPED' AND NOT sl.discarded)
        AS lines_skipped
FROM staging_receipts sr
LEFT JOIN stores s ON s.id = sr.store_id
-- LEFT JOIN, not JOIN: a receipt with no lines at all (ingestion failure,
-- or an upload the parser could not open) has to show up. With an inner
-- join it vanishes, and that receipt is exactly the one the user needs in
-- order to understand what happened.
LEFT JOIN staging_lines sl ON sl.receipt_id = sr.id
WHERE sr.status IN ('PENDING', 'IN_REVIEW')
GROUP BY sr.id, sr.user_id, sr.source, sr.status, sr.total_gross,
         sr.discount_total, sr.amount_paid, sr.total_computed,
         sr.divergence_cents, s.name
ORDER BY abs(sr.divergence_cents) DESC NULLS LAST,
         count(sl.id) FILTER (WHERE sl.product_id IS NULL) DESC;

COMMIT;
