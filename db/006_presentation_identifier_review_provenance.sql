-- =============================================================================
-- home_shopper -- part 6: review flag and provenance on presentation_identifiers
-- PostgreSQL 16
--
-- internal task. internal task loaded 129 observed GTINs into
-- presentation_identifiers and correctly refused to invent the two things the
-- table had nowhere to hold: whether a human confirmed the link, and WHERE the
-- code was declared. Jonas authorised the DDL on 2026-10-05 ("vale acrescentar
-- as colunas").
--
-- WHY THIS IS A NEW MIGRATION AND NOT AN EDIT OF 005
--   005 is already applied and published: the canonical database ran it, and
--   everyone who applies `db/*.sql` in order has to reach the same final state.
--   Editing 005 would make the canonical database and a fresh one diverge -- the
--   exact drift 005 exists to prevent. A new file carries BOTH databases through
--   the same code path.
--
-- WHY THE COLUMNS AND NOT A CHILD TABLE
--   Provenance is multi-valued in principle -- one GTIN observed on N lines --
--   and the loader computes the whole set. The scope here is the one Jonas
--   authorised: review + provenance columns ON presentation_identifiers. So
--   purchase_note_id / line_no hold the origin only when it is a SINGLE
--   unambiguous (note, line): 86 of the 129 identifiers today. For the other 43
--   the origin is genuinely multi-valued (2 to 8 literal pairs, 21 of them
--   spanning more than one note) and both columns stay NULL rather than store an
--   arbitrary pick -- the full set stays in the loader and the gap is declared.
--   If the whole N-origin set must be durable, the honest shape is a child table
--   `presentation_identifier_origins (identifier_id, purchase_note_id, line_no)`;
--   that is a decision above this card's scope and is left to the coordinator.
--
-- WHAT CHANGES
--   * reviewed BOOLEAN NOT NULL DEFAULT false -- the same criterion already used
--     by presentation_sources.reviewed: the loader's link is MECHANICAL, so it
--     is false; only a human confirmation may set it true. The loader never
--     resets it back to false on re-run.
--   * purchase_note_id UUID NULL -- which purchase note the code was declared
--     on. NULL when the origin cannot be pinned to one note.
--   * line_no SMALLINT NULL -- the line within that note. SMALLINT, not INTEGER:
--     it is the same field as line_items.line_no (SMALLINT), so provenance stays
--     numerically consistent with the line it names.
--   * ck_presentation_identifiers_provenance -- the pair is all-or-nothing: a
--     note without a line, or a line without a note, is a half-truth.
--   * ck_presentation_identifiers_line_no -- a real line number is positive
--     (line_items numbers from 1).
--   * fk_presentation_identifiers_origin -- the origin must be a REAL line of a
--     real note.
--
-- WHY THE FK POINTS AT line_items AND NOT AT purchase_notes
--   The proposal was a single-column FK to purchase_notes. Measured against the
--   pair check it does not hold: ON DELETE SET NULL clears purchase_note_id but
--   leaves line_no behind, so the row instantly violates
--   ck_presentation_identifiers_provenance and the DELETE aborts -- the LGPD
--   path that removes a user (and cascades to their notes) would start failing.
--   The two columns describe ONE origin, so they have to travel through ONE
--   foreign key. `line_items` already carries UNIQUE (note_id, line_no), and
--   fk_line_items_note is ON DELETE CASCADE, so a composite FK
--   (purchase_note_id, line_no) -> line_items (note_id, line_no) gives exactly
--   what is wanted:
--     * the referenced line really exists, which transitively proves the note
--       (line_items.note_id -> purchase_notes is itself enforced);
--     * deleting the note cascades to its lines, which sets BOTH provenance
--       columns NULL in one step -- no half-truth, no dangling pointer.
--   The all-or-nothing CHECK keeps the FK's own MATCH SIMPLE hole closed: with
--   one column NULL the FK would not be checked, and the CHECK forbids exactly
--   that state.
--
-- NO DATA IS LOST AND NO GTIN CHANGES. The ALTER only widens the table; the 129
--   existing rows keep their id, presentation_id and gtin untouched, and are
--   backfilled by re-running the loader (which is idempotent).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The review flag and the two provenance columns
-- -----------------------------------------------------------------------------
ALTER TABLE presentation_identifiers
    -- Mechanical link vs human-confirmed, exactly as presentation_sources
    -- already distinguishes the two. DEFAULT false is the honest value: every
    -- row the loader writes is an unconfirmed link.
    ADD COLUMN reviewed        BOOLEAN  NOT NULL DEFAULT false,
    -- The literal origin: the note and the line the code was printed on. Both
    -- NULL when the origin is not a single unambiguous pair.
    ADD COLUMN purchase_note_id UUID     NULL,
    ADD COLUMN line_no         SMALLINT NULL;

-- -----------------------------------------------------------------------------
-- 2. The constraints, every one of them named
-- -----------------------------------------------------------------------------
ALTER TABLE presentation_identifiers
    -- All-or-nothing: the note and the line travel together or not at all.
    ADD CONSTRAINT ck_presentation_identifiers_provenance
        CHECK ((purchase_note_id IS NULL) = (line_no IS NULL)),
    -- line_items numbers its lines from 1; 0 or a negative is not a line.
    ADD CONSTRAINT ck_presentation_identifiers_line_no
        CHECK (line_no IS NULL OR line_no > 0),
    -- One foreign key over the pair, so ON DELETE SET NULL clears both columns
    -- at once and the origin can never dangle.
    ADD CONSTRAINT fk_presentation_identifiers_origin
        FOREIGN KEY (purchase_note_id, line_no)
        REFERENCES line_items (note_id, line_no)
        ON DELETE SET NULL;

-- -----------------------------------------------------------------------------
-- 3. Index for the provenance lookup (which identifiers came from this note)
-- -----------------------------------------------------------------------------
CREATE INDEX idx_presentation_identifiers_note
    ON presentation_identifiers (purchase_note_id);

COMMIT;
