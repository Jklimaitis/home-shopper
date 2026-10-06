-- =============================================================================
-- home_shopper -- part 9: write requests against the global catalogue
-- PostgreSQL 16
--
-- internal task.
--
-- STATUS OF THE DECISION (RATIFIED)
--   The model this file implements -- form 1: "the catalogue is written only by
--   a data owner/steward, and a common user opens a REQUEST that must be
--   approved" -- was RATIFIED by the owner (Jonas) on 2026-10-05. The decision
--   card is `internal task` (internal task), now done; the written record is
--   `docs/decisions/2026-10-05-escrita-catalogo-global.md`. The alternative
--   (form 2, a private overlay per user) stays discarded in writing by
--   ADR-0004 ("Cada pessoa teria seu proprio products. Descartado: duplicaria a
--   identidade do mesmo item em N cadastros..."), which is why the design below
--   assumes form 1. Integration goes through a PR, never straight to main.
--
-- WHY A NEW MIGRATION AND NOT AN EDIT OF 001-008
--   001-008 are applied and published: the canonical database ran them, and
--   everyone who applies `db/*.sql` in order has to reach the same final state.
--   Editing them would make the canonical database and a fresh one diverge. A new
--   file carries BOTH databases through the same code path.
--
-- WHAT THIS FILE ADDS
--   * `catalog_write_requests` -- the intake/approval ticket for the SHARED
--     catalogue (products, presentations, synonyms, adjustments).
--   * `v_catalog_write_queue` -- pending requests grouped by status and kind.
--   * A COMMENT on `synonyms.scope` fixing its meaning (NULL = global,
--     otherwise a user_id) WITHOUT adding an FK to `users` yet, because what a
--     user deletion should do to a private synonym is an open decision (card
--     D3-follow), not something this card may settle by accident.
--
-- THE HONEST COST (do not sell this as free)
--   With a single real user (the owner; PRD 9 says this is not a SaaS), the
--   approver is the requester, so the gate is CELEBRATORY until a second real
--   user exists. This structure buys contamination control and a path for a
--   non-owner (persona 2.2, Ana) to contribute; it does NOT by itself remove the
--   recurring review cost recorded as risk 13.9.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. catalog_write_requests -- the intake/approval ticket
-- -----------------------------------------------------------------------------
-- A common user never writes the shared catalogue directly. They open a row
-- here; a data owner/steward reviews it and moves it to APPROVED or REJECTED.
-- `kind` says WHAT is being requested; `payload` carries the fields the approver
-- needs; `target_id` points at an existing catalogue row when the request is an
-- adjustment rather than a creation.
CREATE TABLE catalog_write_requests (
    id                 UUID        NOT NULL DEFAULT gen_random_uuid(),
    -- Who asked. ON DELETE SET NULL so the ticket survives the person's LGPD
    -- erasure (the same shape already used elsewhere in this schema); the
    -- e-mail below keeps the provenance readable once the user row is gone.
    requested_by       UUID,
    requested_by_email TEXT        NOT NULL,
    kind               TEXT        NOT NULL,
    -- The proposed values. A JSONB document, because the four kinds carry
    -- different fields and a strict shape per kind would need four tables.
    payload            JSONB       NOT NULL,
    -- The existing catalogue row an ADJUSTMENT targets. Deliberately NOT a
    -- foreign key: the target is polymorphic (product, presentation or synonym
    -- depending on `kind`) and no single FK can express that. The kind-specific
    -- check below is what keeps the pointer meaningful.
    target_id          UUID,
    justification      TEXT,
    status             TEXT        NOT NULL DEFAULT 'OPEN',
    -- Reviewer identity is ACTOR METADATA, exactly like `audit_log.user_id`
    -- (ADR-0004 §5), and carries NO foreign key ON PURPOSE: see the note on
    -- ck_catalog_write_requests_decided below.
    reviewed_by        UUID,
    reviewed_by_email  TEXT,
    review_note        TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at         TIMESTAMPTZ,

    CONSTRAINT pk_catalog_write_requests PRIMARY KEY (id),

    CONSTRAINT fk_catalog_write_requests_requested_by
        FOREIGN KEY (requested_by) REFERENCES users (id) ON DELETE SET NULL,

    CONSTRAINT ck_catalog_write_requests_kind
        CHECK (kind IN ('PRODUCT', 'PRESENTATION', 'SYNONYM', 'ADJUSTMENT')),
    CONSTRAINT ck_catalog_write_requests_status
        CHECK (status IN ('OPEN', 'APPROVED', 'REJECTED')),

    -- OPEN means "nobody decided anything yet": no reviewer, no decision time.
    CONSTRAINT ck_catalog_write_requests_open
        CHECK (status <> 'OPEN'
               OR (reviewed_by IS NULL AND decided_at IS NULL)),

    -- APPROVED or REJECTED is a DECISION: it needs a named reviewer and a
    -- timestamp. Nothing clears `reviewed_by`, so this can never be falsified
    -- after the fact.
    --
    -- WHY `reviewed_by` HAS NO FK (and why that is the point)
    --   A FK to users(id) ON DELETE SET NULL would make the LGPD erasure path
    --   ABORT: deleting the reviewer would try to NULL this column on an
    --   APPROVED row, the check below would fire inside the same statement, and
    --   `DELETE FROM users` would fail. That is the exact class of bug already
    --   reproduced twice in this repo -- audit_log.user_id (ADR-0004 §5) and the
    --   dangling provenance pointer of `db/006` -- both fixed by removing the
    --   FK, not by weakening the invariant. The reviewer's e-mail is kept in
    --   `reviewed_by_email` so the node stays readable once the user is gone.
    CONSTRAINT ck_catalog_write_requests_decided
        CHECK (status = 'OPEN'
               OR (reviewed_by IS NOT NULL AND decided_at IS NOT NULL)),

    -- An adjustment adjusts something: it must name its target. Creations may
    -- leave target_id NULL.
    CONSTRAINT ck_catalog_write_requests_target
        CHECK (kind <> 'ADJUSTMENT' OR target_id IS NOT NULL),

    -- The trace that survives erasure must actually identify someone.
    CONSTRAINT ck_catalog_write_requests_requester_email
        CHECK (btrim(requested_by_email) <> ''),

    -- Personal data never enters `payload`: the payload is what gets PUBLISHED
    -- into the shared catalogue once approved, so an e-mail, a CPF or an NFC-e
    -- access key inside it would leak into everyone's catalogue.
    --
    -- This check is NOT a copy of scripts/guard_dados_sensiveis.py: it is a
    -- SUPERSET of it. It flags the same four patterns the guard flags -- both
    -- forms of the NFC-e access key and both forms of the CPF -- and ADDS
    -- e-mail, which the guard does not look for at all. Both key forms matter:
    -- a rule that only sees 44 consecutive digits lets through the key written
    -- in the official 2-4-14-2-3-9-9-1 layout, which is how a person copies it
    -- out of the SEFAZ app -- the asymmetry the guard's own docstring warns
    -- against, and the payload is exactly what becomes shared catalogue.
    --
    -- PostgreSQL 16 ARE has no look-around, so the formatted key's boundaries
    -- are expressed by alternation -- `(^|[^0-9-])` ... `([^0-9-]|$)` -- where
    -- the guard uses `(?<![\d-])` / `(?![\d-])`. For the pure-digit runs, \y
    -- (word boundary) keeps the 11-digit CPF rule from firing inside a longer
    -- GTIN (an 8/12/13/14-digit run), the same role the guard's digit
    -- look-arounds play.
    CONSTRAINT ck_catalog_write_requests_payload_no_pii
        CHECK (payload::text !~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
           AND payload::text !~ '\y[0-9]{11}\y'
           AND payload::text !~ '[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}'
           AND payload::text !~ '\y[0-9]{44}\y'
           AND payload::text !~ '(^|[^0-9-])[0-9]{2}-[0-9]{4}-[0-9]{14}-[0-9]{2}-[0-9]{3}-[0-9]{9}-[0-9]{9}-[0-9]([^0-9-]|$)')
);

COMMENT ON TABLE catalog_write_requests IS
    'Intake/approval tickets for the SHARED catalogue (form 1: a common user '
    'requests, a data owner/steward approves). The catalogue stays global and '
    'single -- there is no per-user base and no overlay.';

COMMENT ON COLUMN catalog_write_requests.requested_by IS
    'Requester. ON DELETE SET NULL so the ticket outlives the person; '
    'requested_by_email carries the provenance after the user row is gone.';

COMMENT ON COLUMN catalog_write_requests.payload IS
    'Proposed values, eventually published into the shared catalogue. Must '
    'never carry personal data (e-mail, CPF, NFC-e access key) -- enforced by '
    'ck_catalog_write_requests_payload_no_pii.';

COMMENT ON COLUMN catalog_write_requests.reviewed_by IS
    'Reviewer. ACTOR METADATA with no FK to users, exactly like '
    'audit_log.user_id: an APPROVED row must keep its reviewer, so the column '
    'may not be cleared by a user deletion.';

-- -----------------------------------------------------------------------------
-- 2. v_catalog_write_queue -- the approval queue, by status and kind
-- -----------------------------------------------------------------------------
-- Pending (and historical) requests grouped by status, with the count broken
-- down by kind. This is what a steward opens to see "how many PRODUCT requests
-- are waiting".
CREATE VIEW v_catalog_write_queue AS
SELECT
    cwr.status,
    cwr.kind,
    count(*)                    AS request_count,
    min(cwr.created_at)         AS oldest_request_at,
    max(cwr.decided_at)         AS last_decision_at
FROM catalog_write_requests cwr
GROUP BY cwr.status, cwr.kind;

COMMENT ON VIEW v_catalog_write_queue IS
    'Approval queue: catalog_write_requests grouped by status, with the count '
    'per kind.';

-- -----------------------------------------------------------------------------
-- 3. synonyms.scope -- fix the meaning, defer the FK
-- -----------------------------------------------------------------------------
-- `scope` already exists (001) with UNIQUE NULLS NOT DISTINCT (term, scope):
--   scope IS NULL    -> GLOBAL synonym, usable by everyone.
--   scope = user_id  -> PRIVATE synonym, scoped to one user (TEXT, holds the
--                       user's UUID as text).
--
-- NO FK to users is created here. Whether deleting a user should DELETE the
-- private synonyms or KEEP them is an open decision (card D3-follow); adding an
-- FK now would settle it by accident and choose a cascade the owner has not
-- chosen. The column comment exists so the meaning is not re-derived from the
-- NULL every time someone reads the table.
COMMENT ON COLUMN synonyms.scope IS
    'NULL = global synonym (usable by any user). Otherwise a user_id as text: '
    'a PRIVATE synonym scoped to that user. No FK to users on purpose -- what a '
    'user deletion does to a private synonym is an open decision (D3-follow).';

-- -----------------------------------------------------------------------------
-- 4. Indexes
-- -----------------------------------------------------------------------------
CREATE INDEX idx_catalog_write_requests_queue
    ON catalog_write_requests (status, kind);
CREATE INDEX idx_catalog_write_requests_requested_by
    ON catalog_write_requests (requested_by);
CREATE INDEX idx_catalog_write_requests_open
    ON catalog_write_requests (created_at) WHERE status = 'OPEN';

COMMIT;
