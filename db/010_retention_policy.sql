-- =============================================================================
-- home_shopper -- part 10: LGPD retention, purge queue and the register
-- PostgreSQL 16
--
-- internal task. LGPD (Lei 13.709/2018) under the small-agent regime
-- (Resolucao CD/ANPD no 2, de 27/01/2022). ADR-0005 left this open: it recorded
-- the erasure path and the residue it leaves, and its "what this document does
-- not decide" section names the retention terms as the open question.
--
-- WHY A TABLE AND NOT A PARAGRAPH IN A DOCUMENT
--   LGPD art. 6, X (prestacao de contas) puts the burden on the controller to
--   DEMONSTRATE that the measure is effective, and art. 37 requires a record of
--   the processing operations. A retention term that lives only in prose is not
--   demonstrable: nobody can query it, no job reads it, and nothing fails when a
--   new column arrives with no term at all. The choice has to be DATA, with the
--   purpose (art. 6, I) and the legal basis (art. 7) next to it, so the purge
--   queue is derived from the register instead of from hardcoded windows.
--
-- PONTO HONESTO: THE LAW DOES NOT FIX THESE TERMS
--   The LGPD fixes no retention period for a purchase note, a coupon image or an
--   audit payload. What it fixes is the END: art. 15 says the treatment ends
--   when the purpose is reached, when the period ends, when the subject asks, or
--   when the ANPD determines; art. 16 says the data SHALL BE ELIMINATED after
--   that, and allows conservation only under four hypotheses (legal/regulatory
--   obligation; research, anonymised; transfer to a third party; exclusive use of
--   the controller, no third-party access, anonymised).
--   So every retention_days below is a CONTROLLER CHOICE justified by one of
--   those hypotheses -- never a legal deadline. That distinction is the reason
--   `legal_basis` (why the data exists) is a separate column from
--   `retention_days` (how long we decided to keep it).
--
-- WHY NULL retention_days IS ALLOWED, BUT NOT ALONE
--   A fixed term is impossible for data that must live as long as the service
--   does (the access key that makes the note comparable, the account e-mail).
--   The honest answer there is not an invented term: it is "no fixed term, with
--   a registered review date". ck_retention_policy_review enforces exactly that
--   -- a policy with no term and no review date is refused, because nothing
--   would ever bring it back for a second look.
--
-- WHY THE TARGET MUST EXIST (tr_retention_policy_target)
--   A register that can name a column that does not exist is decoration. The
--   trigger makes an unenforceable policy row impossible: a renamed or dropped
--   column turns into a loud failure instead of a silently useless policy.
--
-- THE SEED ROWS ARE THE REGISTER ITSELF, NOT BUSINESS DATA
--   README: "that loop applies schema, not data". These INSERTs are the policy
--   -- seven rows written by the controller, reviewable in the diff, identical in
--   every environment. No receipt, no user and no purchase is seeded here.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- retention_policy: WHY each personal field exists and UNTIL WHEN
-- -----------------------------------------------------------------------------
CREATE TABLE retention_policy (
    id             UUID        NOT NULL DEFAULT gen_random_uuid(),
    -- The target column. Column-granular on purpose: within audit_log only the
    -- JSONB payload carries personal data, while table_name / operation /
    -- record_id / occurred_at are anonymous metadata. A table-level policy
    -- could not express that, and would either purge too much or too little.
    table_name     TEXT        NOT NULL,
    column_name    TEXT        NOT NULL,
    -- art. 6, I (finalidade): the specific purpose, in words. "Necessity" is
    -- only demonstrable against a stated purpose.
    purpose        TEXT        NOT NULL,
    -- art. 7 (legal basis of the treatment). Closed set -- see the CHECK below:
    -- an open TEXT column would accept "whatever" and stop being a basis.
    legal_basis    TEXT        NOT NULL,
    -- Chosen window, counted from the reference timestamp of each target
    -- (audit_log.occurred_at, data_erasure_requests.executed_at,
    -- staging_receipts.updated_at). NULL = no fixed term; see the review CHECK.
    retention_days INTEGER,
    -- When this POLICY must be reviewed. Required when there is no fixed term
    -- (ck_retention_policy_review); optional otherwise, and used as the annual
    -- revision reminder for the rows that cannot expire on their own.
    expires_at     TIMESTAMPTZ,
    -- Last time the purge job actually removed something for this policy.
    -- Written only when at least one record was purged, so a second run of the
    -- job is genuinely a no-op -- on the data AND on this column.
    last_purged_at TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_retention_policy PRIMARY KEY (id),
    -- One policy per target. Two rows for one column would mean two different
    -- answers to "until when", which is not a policy.
    CONSTRAINT uk_retention_policy_target UNIQUE (table_name, column_name),
    -- The identifiers are used to build the purge and the report lookups, so
    -- their shape is constrained (see scripts/purge_expired.py: the same regex
    -- is re-validated in Python before any identifier reaches SQL).
    CONSTRAINT ck_retention_policy_table_name
        CHECK (table_name ~ '^[a-z_][a-z0-9_]*$'),
    CONSTRAINT ck_retention_policy_column_name
        CHECK (column_name ~ '^[a-z_][a-z0-9_]*$'),
    CONSTRAINT ck_retention_policy_purpose CHECK (btrim(purpose) <> ''),
    -- art. 7: the bases this project actually relies on. Not every one of the
    -- ten is a plausible basis for a supermarket price monitor, and an unknown
    -- string is a basis nobody can audit.
    --   CONSENT             art. 7, I
    --   CONTRACT            art. 7, V  (execution of the service the user asked for)
    --   LEGITIMATE_INTEREST art. 7, IX (security / fraud prevention)
    --   LEGAL_OBLIGATION    art. 7, II (art. 37 register, art. 19 reply)
    CONSTRAINT ck_retention_policy_basis CHECK (legal_basis IN
        ('CONSENT', 'CONTRACT', 'LEGITIMATE_INTEREST', 'LEGAL_OBLIGATION')),
    -- A window of zero or a negative window is not a retention term.
    CONSTRAINT ck_retention_policy_days
        CHECK (retention_days IS NULL OR retention_days > 0),
    -- No fixed term is allowed -- but only together with a review date.
    CONSTRAINT ck_retention_policy_review
        CHECK (retention_days IS NOT NULL OR expires_at IS NOT NULL)
);

COMMENT ON COLUMN retention_policy.retention_days IS
    'Controller choice, not a legal deadline: the LGPD fixes the end of the '
    'treatment (art. 15) and the conservation hypotheses (art. 16), never a '
    'number of days. NULL = no fixed term, and expires_at is then required.';
COMMENT ON COLUMN retention_policy.expires_at IS
    'Date the registered policy must be reviewed. Required for rows without a '
    'fixed term (ck_retention_policy_review); used as the annual revision '
    'reminder for purchase_notes, line_items and users.email.';
COMMENT ON COLUMN retention_policy.last_purged_at IS
    'Last purge that removed at least one record. The purge job does not touch '
    'it on a no-op run, so re-running the job is provably idempotent.';

-- -----------------------------------------------------------------------------
-- The target must be a real column
-- -----------------------------------------------------------------------------
-- A policy row that names a column which does not exist would never purge
-- anything and would never complain. The check runs on INSERT and on any change
-- of the identifiers; 23503 (foreign_key_violation) because that is exactly the
-- failure: a reference to a target that is not there.
CREATE OR REPLACE FUNCTION check_retention_policy_target() RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.columns c
         WHERE c.table_schema = 'public'
           AND c.table_name   = NEW.table_name
           AND c.column_name  = NEW.column_name
    ) THEN
        RAISE EXCEPTION
            'retention_policy names a target that does not exist: %.% is not '
            'a column of public (art. 6, X: an unenforceable policy is not a '
            'measure)',
            NEW.table_name, NEW.column_name
            USING ERRCODE = '23503';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_retention_policy_target
    BEFORE INSERT OR UPDATE OF table_name, column_name ON retention_policy
    FOR EACH ROW EXECUTE FUNCTION check_retention_policy_target();

-- -----------------------------------------------------------------------------
-- The one schema change this policy needs
-- -----------------------------------------------------------------------------
-- `data_erasure_requests.email` was `NOT NULL` (db/002): at the moment the
-- request is written the contact is always known, and the column is what makes
-- the record answerable (art. 19). But the retention window below ends with that
-- value going away, and a `NOT NULL` column cannot be minimized -- the choice
-- would be between keeping the address forever and deleting the proof of the
-- erasure (art. 37). Neither is acceptable, so the column becomes NULLABLE and
-- the policy guarantees presence DURING the window:
--   * the application must still require a contact when it records the request;
--   * the purge job sets it to NULL only after `executed_at` + retention_days;
--   * ck_data_erasure_email forbids the empty string, which is not a removal.
-- NULL here is the honest "no value": the request, its dates and its counts
-- survive, and nothing identifies the subject any more.
ALTER TABLE data_erasure_requests
    ALTER COLUMN email DROP NOT NULL;

ALTER TABLE data_erasure_requests
    ADD CONSTRAINT ck_data_erasure_email
        CHECK (email IS NULL OR btrim(email) <> '');

COMMENT ON COLUMN data_erasure_requests.email IS
    'Contact of the data subject. Required when the request is recorded; set to '
    'NULL by scripts/purge_expired.py after the registered window '
    '(retention_policy: data_erasure_requests.email) -- the record itself is '
    'kept, the address is not.';

-- -----------------------------------------------------------------------------
-- The register: one row per personal field that survives in this schema
-- -----------------------------------------------------------------------------
-- Reference timestamps used by the windows, and why:
--   audit_log.occurred_at            -- when the change was logged
--   data_erasure_requests.executed_at-- when the erasure concluded
--   staging_receipts.updated_at      -- the last state change of the receipt
INSERT INTO retention_policy
    (table_name, column_name, purpose, legal_basis, retention_days, expires_at)
VALUES
    -- The coupon image is the most dangerous artifact in the system: it shows
    -- the buyer CPF, the address and the basket, and it is a PIXEL -- no query
    -- finds the CPF in it (ADR-0005 section 2). Two-tier window: once the
    -- receipt is DONE the review is over and there is no reason to keep the
    -- image (see v_retention_due: DONE is due immediately); while it is still
    -- PENDING / IN_REVIEW / DISCARDED the image is the evidence the review is
    -- made of, and it gets the 30-day window.
    ('staging_receipts', 'file_path',
     'coupon image kept only while the receipt is under review, so a human can '
     'check an ambiguous line against the source; the file shows the buyer CPF, '
     'address and basket',
     'LEGITIMATE_INTEREST', 30, NULL),

    -- The audit payload is the only part of audit_log that can carry personal
    -- data. art. 16, IV allows conservation for the controller's exclusive use
    -- only if the data is anonymised and unreachable by third parties -- so the
    -- term ends with ANONYMISATION (payload discarded), not with the deletion of
    -- the log row. What survives is table_name, operation, record_id and
    -- occurred_at: the trail, without the second copy of the personal data.
    ('audit_log', 'before_data',
     'before-image of a change to a purchase note or line, kept for support and '
     'for the erasure trail; discarded (set to NULL) after the window because '
     'art. 16, IV only allows conservation of anonymised data',
     'LEGITIMATE_INTEREST', 90, NULL),
    ('audit_log', 'after_data',
     'after-image of a change to a purchase note or line, same purpose and same '
     'window as before_data',
     'LEGITIMATE_INTEREST', 90, NULL),

    -- The e-mail is the only personal field of data_erasure_requests to survive
    -- the DELETE it documents. It exists to answer the subject (art. 19) and to
    -- keep the register of the operation (art. 37); once replied and registered,
    -- there is no basis left to keep the address, so the value goes to NULL.
    ('data_erasure_requests', 'email',
     'contact of the data subject, kept to answer the erasure request and to '
     'identify the record of the operation; nulled once the window closes',
     'LEGAL_OBLIGATION', 90, NULL),

    -- No fixed term below. These are the data the PRODUCT is made of: while the
    -- user wants to compare prices across stores, the note identity and the
    -- purchase lines ARE the purpose (art. 15, I -- necessity is judged against
    -- the purpose, and the purpose is still being served). Deleting them early
    -- would break the comparison instead of protecting anyone, so the honest
    -- register is "no term, reviewed annually" -- expires_at is what brings them
    -- back for a second look.
    ('purchase_notes', 'access_key',
     'NFC-e access key: the natural identity of the note, needed to compare '
     'prices across stores and to keep re-ingestion idempotent',
     'CONTRACT', NULL, now() + interval '1 year'),
    ('line_items', 'unit_price',
     'the purchased line: what was bought, in what quantity and for how much; '
     'the purchase history the comparison is built from',
     'CONTRACT', NULL, now() + interval '1 year'),
    ('users', 'email',
     'account contact and login identifier, kept while the account exists',
     'CONTRACT', NULL, now() + interval '1 year');

-- -----------------------------------------------------------------------------
-- v_retention_due: what is past its window, per registered policy
-- -----------------------------------------------------------------------------
-- The purge queue. The grain is (policy, record, column): one audit row whose
-- BOTH payload columns are past the window appears twice, once per column, which
-- is what an operator wants to see -- before_data and after_data are separate
-- entries in the register and separate statements in the job.
--
-- Every approved target is a JOIN against retention_policy, so the queue is
-- derived from the register and not from windows hardcoded here: drop the policy
-- row and the queue stops proposing that purge. The targets that must NEVER be
-- purged automatically (purchase_notes, line_items, users.email) are absent from
-- the queue, and they cannot leak into it by accident: they carry a NULL
-- retention_days, and every branch requires a non-NULL window.
--
-- WHY now() IS CORRECT HERE, unlike in compare_baskets (db/004)
--   compare_baskets refuses CURRENT_DATE because a REPORT that answers a
--   different question tomorrow is not reproducible, and it takes the as-of date
--   as a parameter. This view is the opposite artifact: it answers "what is past
--   its window right now", which is exactly what a purge queue must answer, and
--   a parameterised version would let the caller purge against a window that
--   never existed. The tests control the fixture timestamps instead of the
--   clock.
--
-- target_value is the stored value the purge acts on, and it is filled ONLY for
-- the filesystem target: the coupon path is needed to delete the file. The
-- e-mail is deliberately NOT echoed here -- a compliance report must not become
-- a second copy of the personal data it reports about.
CREATE VIEW v_retention_due AS
SELECT
    d.policy_id,
    d.table_name,
    d.column_name,
    d.record_id,
    d.record_owner,
    d.target_value,
    d.reference_at,
    d.due_at,
    floor(extract(epoch FROM (now() - d.due_at)) / 86400)::INTEGER AS overdue_days,
    d.retention_days,
    d.purge_action
FROM (
    -- (a) audit_log payload, per column
    SELECT
        rp.id          AS policy_id,
        rp.table_name,
        rp.column_name,
        a.id::TEXT     AS record_id,
        a.user_id      AS record_owner,
        NULL::TEXT     AS target_value,
        a.occurred_at  AS reference_at,
        a.occurred_at + make_interval(days => rp.retention_days) AS due_at,
        rp.retention_days,
        'ANONYMIZE_PAYLOAD'::TEXT AS purge_action
    FROM audit_log a
    JOIN retention_policy rp
      ON rp.table_name  = 'audit_log'
     AND rp.column_name = 'before_data'
    WHERE rp.retention_days IS NOT NULL
      AND a.before_data IS NOT NULL
      AND a.occurred_at <= now() - make_interval(days => rp.retention_days)

    UNION ALL

    SELECT
        rp.id, rp.table_name, rp.column_name,
        a.id::TEXT, a.user_id, NULL::TEXT,
        a.occurred_at,
        a.occurred_at + make_interval(days => rp.retention_days),
        rp.retention_days,
        'ANONYMIZE_PAYLOAD'::TEXT
    FROM audit_log a
    JOIN retention_policy rp
      ON rp.table_name  = 'audit_log'
     AND rp.column_name = 'after_data'
    WHERE rp.retention_days IS NOT NULL
      AND a.after_data IS NOT NULL
      AND a.occurred_at <= now() - make_interval(days => rp.retention_days)

    UNION ALL

    -- (b) the surviving contact of an executed erasure request
    SELECT
        rp.id, rp.table_name, rp.column_name,
        r.id::TEXT, r.user_id, NULL::TEXT,
        r.executed_at,
        r.executed_at + make_interval(days => rp.retention_days),
        rp.retention_days,
        'NULL_EMAIL'::TEXT
    FROM data_erasure_requests r
    JOIN retention_policy rp
      ON rp.table_name  = 'data_erasure_requests'
     AND rp.column_name = 'email'
    -- executed_at IS NULL means the erasure has not concluded: the clock has
    -- not started, so there is nothing to expire.
    WHERE rp.retention_days IS NOT NULL
      AND r.email IS NOT NULL
      AND r.executed_at IS NOT NULL
      AND r.executed_at <= now() - make_interval(days => rp.retention_days)

    UNION ALL

    -- (c) the coupon image: due IMMEDIATELY once the receipt is DONE (the
    -- review is over), otherwise after the window counted from the last state
    -- change of the receipt.
    SELECT
        rp.id, rp.table_name, rp.column_name,
        sr.id::TEXT, sr.user_id, sr.file_path,
        sr.updated_at,
        CASE
            WHEN sr.status = 'DONE' THEN sr.updated_at
            ELSE sr.updated_at + make_interval(days => rp.retention_days)
        END,
        rp.retention_days,
        'DELETE_FILE'::TEXT
    FROM staging_receipts sr
    JOIN retention_policy rp
      ON rp.table_name  = 'staging_receipts'
     AND rp.column_name = 'file_path'
    WHERE rp.retention_days IS NOT NULL
      AND sr.file_path IS NOT NULL
      AND (sr.status = 'DONE'
           OR sr.updated_at <= now() - make_interval(days => rp.retention_days))
) AS d;

COMMENT ON VIEW v_retention_due IS
    'Purge queue derived from retention_policy: what is past its registered '
    'window right now, per policy and record. Policies with a NULL '
    'retention_days never appear (no fixed term to expire), which is what keeps '
    'the trusted layer out of the automatic purge.';

COMMIT;
