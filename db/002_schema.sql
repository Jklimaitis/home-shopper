-- =============================================================================
-- home_shopper -- part 2: staging, trusted layer, analytics, triggers
-- PostgreSQL 16
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- STAGING -- extracted data, NOT yet trusted
-- -----------------------------------------------------------------------------
-- Flow: upload/QR/import --> staging_receipts + staging_lines
--       --> [human review] --> purchase_notes + line_items (trusted)
--       --> analytics
--
-- The receipts showed why human review is mandatory rather than
-- optional: across 42 line items, ZERO had an EAN, 39 of 42 carried a
-- parseable size in the description, and the ones that did not were
-- exactly the by-weight items -- the ones where the unit conversion
-- matters most. The automatic path resolves the bulk; review handles
-- the tail.
-- -----------------------------------------------------------------------------
CREATE TABLE staging_receipts (
    id               UUID                  NOT NULL DEFAULT gen_random_uuid(),
    user_id          UUID                  NOT NULL,
    source           ingestion_source      NOT NULL,
    -- Access key (44 digits), the SEFAZ URL, the upload id. NULL when
    -- the receipt was typed in by hand.
    source_ref       TEXT,
    -- Lowercased copy of source_ref, for the idempotency index.
    source_ref_norm  TEXT GENERATED ALWAYS AS
        (lower(coalesce(source_ref, ''))) STORED,
    store_id         UUID,
    status           consolidation_status  NOT NULL DEFAULT 'PENDING',
    -- Path to the coupon image on disk. Zero bytes in the database.
    file_path        TEXT,
    -- The receipt shows THREE different numbers:
    --   "Total 550.93 | Discount 6.00 | Amount paid 544.93"
    -- and the 13 line totals of a receipt summed to 550.93 -- the
    -- GROSS. The 6.00 discount lives in the totals, not in the lines.
    --
    -- That is why the checksum compares against total_gross and not
    -- against amount_paid: comparing with the net would report a
    -- 600-cent divergence on every discounted receipt, a guaranteed
    -- false positive.
    total_gross      NUMERIC(12,2),
    discount_total   NUMERIC(12,2)         NOT NULL DEFAULT 0,
    amount_paid      NUMERIC(12,2),
    -- Sum of the lines, computed by the trigger.
    total_computed   NUMERIC(12,2),
    divergence_cents INTEGER,
    -- Diagnostics from the async job.
    error_message    TEXT,
    attempts         INTEGER                NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ           NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ           NOT NULL DEFAULT now(),

    CONSTRAINT pk_staging_receipts PRIMARY KEY (id),
    CONSTRAINT fk_staging_receipts_user  FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_staging_receipts_store FOREIGN KEY (store_id)
        REFERENCES stores(id) ON DELETE SET NULL,
    CONSTRAINT ck_staging_receipts_discount CHECK (discount_total >= 0),
    CONSTRAINT ck_staging_receipts_attempts  CHECK (attempts >= 0)
);

CREATE TABLE staging_lines (
    id              UUID                  NOT NULL DEFAULT gen_random_uuid(),
    receipt_id      UUID                  NOT NULL,
    line_no         SMALLINT              NOT NULL,
    -- Exactly as it came off the receipt.
    description_raw TEXT                  NOT NULL,
    -- The store's internal 7-digit code. Search aid during capture only;
    -- it is the EMITTER's number, so it never becomes a matching key
    -- (see presentations for why).
    store_code      TEXT,
    -- Unit as printed: "UN", "PC", "KG", "CX".
    sale_unit       TEXT                  NOT NULL,
    quantity        NUMERIC(12,3)         NOT NULL,
    unit_price      NUMERIC(12,4)         NOT NULL,
    discount_line   NUMERIC(12,2)         NOT NULL DEFAULT 0,
    line_total      NUMERIC(12,2)         NOT NULL,
    -- Filled in by the normalisation job. NULL means no match.
    product_id      UUID,
    presentation_id UUID,
    match_source    match_source          NOT NULL DEFAULT 'NONE',
    -- Audit trail for the learning loop: why it matched, or why not.
    match_note      TEXT,
    reviewed        BOOLEAN               NOT NULL DEFAULT FALSE,
    discarded       BOOLEAN               NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ           NOT NULL DEFAULT now(),

    CONSTRAINT pk_staging_lines PRIMARY KEY (id),
    CONSTRAINT uk_staging_lines_receipt_line UNIQUE (receipt_id, line_no),
    CONSTRAINT fk_staging_lines_receipt FOREIGN KEY (receipt_id)
        REFERENCES staging_receipts(id) ON DELETE CASCADE,
    CONSTRAINT fk_staging_lines_product FOREIGN KEY (product_id)
        REFERENCES products(id) ON DELETE SET NULL,
    -- Composite FK: the presentation must belong to the stated product.
    -- Staging is where the matcher errs, so this coherence is enforced by
    -- the database rather than left to the job that runs before review.
    CONSTRAINT fk_staging_lines_presentation FOREIGN KEY (presentation_id, product_id)
        REFERENCES presentations(id, product_id) ON DELETE SET NULL,
    CONSTRAINT ck_staging_lines_quantity   CHECK (quantity >= 0),
    CONSTRAINT ck_staging_lines_unit_price CHECK (unit_price >= 0),
    CONSTRAINT ck_staging_lines_discount   CHECK (discount_line >= 0),
    CONSTRAINT ck_staging_lines_total      CHECK (line_total >= 0),
    CONSTRAINT ck_staging_lines_sale_unit  CHECK (sale_unit ~ '^[A-Za-z]{1,4}$')
);

-- -----------------------------------------------------------------------------
-- TRUSTED LAYER -- reviewed and consolidated
-- -----------------------------------------------------------------------------
CREATE TABLE purchase_notes (
    id              UUID        NOT NULL DEFAULT gen_random_uuid(),
    user_id         UUID        NOT NULL,
    store_id        UUID        NOT NULL,
    staging_receipt_id UUID,
    -- NFC-e access key: 44 digits. NULL when typed by hand.
    -- TEXT, not CHAR(44): the CHECK below is what enforces the 44 digits,
    -- and CHAR's blank-padding semantics buy nothing here (13 keys
    -- are all exactly 44 digits; a 43-digit insert is rejected either way).
    access_key      TEXT,
    purchase_date   DATE        NOT NULL,
    amount_paid     NUMERIC(12,2) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_purchase_notes PRIMARY KEY (id),
    CONSTRAINT fk_purchase_notes_user  FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_purchase_notes_store FOREIGN KEY (store_id)
        REFERENCES stores(id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_notes_staging FOREIGN KEY (staging_receipt_id)
        REFERENCES staging_receipts(id) ON DELETE SET NULL,
    CONSTRAINT ck_purchase_notes_amount  CHECK (amount_paid > 0),
    -- 44 digits is the exact width of an NFC-e access key.
    CONSTRAINT ck_purchase_notes_key     CHECK (access_key IS NULL OR access_key ~ '^[0-9]{44}$')
);

CREATE TABLE line_items (
    id             UUID          NOT NULL DEFAULT gen_random_uuid(),
    note_id        UUID          NOT NULL,
    product_id     UUID          NOT NULL,
    -- Which presentation (sale unit) was charged on this line. NOT NULL:
    -- without it there is no conversion basis, and the trigger raises
    -- rather than silently storing a price that cannot be compared.
    presentation_id UUID         NOT NULL,
    line_no        SMALLINT      NOT NULL,
    unit_price     NUMERIC(12,4) NOT NULL,
    quantity       NUMERIC(12,3) NOT NULL,
    discount_line  NUMERIC(12,2) NOT NULL DEFAULT 0,
    line_total     NUMERIC(12,2) NOT NULL,
    -- Price re-expressed in the product's base unit. Derived by trigger.
    base_price     NUMERIC(14,8) NOT NULL,
    base_unit      base_unit     NOT NULL,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT pk_line_items PRIMARY KEY (id),
    CONSTRAINT uk_line_items_note_line UNIQUE (note_id, line_no),
    CONSTRAINT fk_line_items_note  FOREIGN KEY (note_id)
        REFERENCES purchase_notes(id) ON DELETE CASCADE,
    CONSTRAINT fk_line_items_product FOREIGN KEY (product_id)
        REFERENCES products(id) ON DELETE RESTRICT,
    -- Composite FK: guarantees in the database that the presentation
    -- belongs to the stated product.
    CONSTRAINT fk_line_items_presentation FOREIGN KEY (presentation_id, product_id)
        REFERENCES presentations(id, product_id) ON DELETE RESTRICT,
    CONSTRAINT ck_line_items_unit_price CHECK (unit_price >= 0),
    CONSTRAINT ck_line_items_quantity   CHECK (quantity > 0),
    CONSTRAINT ck_line_items_discount   CHECK (discount_line >= 0),
    CONSTRAINT ck_line_items_total      CHECK (line_total >= 0),
    CONSTRAINT ck_line_items_base_price CHECK (base_price >= 0)
);

-- -----------------------------------------------------------------------------
-- ANALYTICS
-- -----------------------------------------------------------------------------
-- price_refs is populated by a job, not by a trigger. That is deliberate:
-- aggregating to (user, product, store, day) is a BUSINESS DECISION, and
-- hiding it inside a trigger nobody reads would be the wrong place for it.
--
-- The rule lives in v_price_aggregation: quantity-WEIGHTED average, not
-- min() and not a plain average. For two purchases of the same item on
-- the same day at R$ 39,90 and R$ 44,90:
--   plain average = 0.04240   (treats both as equally significant)
--   weighted      = what the shopper actually paid
--   min()         = 0.03990   INFLATES the drop and fires a false alert
-- min() is the worst of the three: a wrong marketing alert is worse than
-- no alert.
CREATE TABLE price_refs (
    id           UUID          NOT NULL DEFAULT gen_random_uuid(),
    -- A reference price is observed by WHO bought it. Without user_id,
    -- two shoppers buying the same item in the same store would collide
    -- on the unique key and one would see the other's price.
    user_id      UUID          NOT NULL,
    product_id   UUID          NOT NULL,
    store_id     UUID          NOT NULL,
    ref_date     DATE          NOT NULL,
    base_price   NUMERIC(14,8) NOT NULL,
    -- Unit the base_price is expressed in. Stored because without it a
    -- min() or max() cannot tell whether it is comparing like with like.
    base_unit    base_unit     NOT NULL,
    min_30d      NUMERIC(14,8),
    max_30d      NUMERIC(14,8),
    var_pct_30d  NUMERIC(8,2),
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT pk_price_refs PRIMARY KEY (id),
    CONSTRAINT uk_price_refs_user_product_store_date
        UNIQUE (user_id, product_id, store_id, ref_date),
    CONSTRAINT fk_price_refs_user    FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_price_refs_product FOREIGN KEY (product_id)
        REFERENCES products(id) ON DELETE CASCADE,
    CONSTRAINT fk_price_refs_store   FOREIGN KEY (store_id)
        REFERENCES stores(id) ON DELETE CASCADE
);

-- The aggregation itself, isolated from storage. The job runs
-- INSERT ... SELECT FROM v_price_aggregation ON CONFLICT DO UPDATE.
CREATE VIEW v_price_aggregation AS
SELECT
    n.user_id,
    i.product_id,
    n.store_id,
    n.purchase_date AS ref_date,
    i.base_unit,
    round(
        sum(i.base_price * i.quantity) / nullif(sum(i.quantity), 0), 8
    ) AS weighted_price,
    min(i.base_price) AS price_min,
    max(i.base_price) AS price_max,
    count(*)          AS purchase_count
FROM line_items i
JOIN purchase_notes n ON n.id = i.note_id
GROUP BY n.user_id, i.product_id, n.store_id, n.purchase_date, i.base_unit;

CREATE TABLE price_alerts (
    id          UUID        NOT NULL DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL,
    product_id  UUID        NOT NULL,
    -- SET NULL, not CASCADE. An alert is the record that a message was
    -- delivered to the user. Recomputing price_refs -- the natural
    -- behaviour of a job -- would take the alert with it, and a job
    -- retry would deliver the same message twice. product_id is already
    -- here, so the alert still identifies the product.
    price_ref_id UUID,
    alert_type   TEXT        NOT NULL,
    var_pct      NUMERIC(8,2) NOT NULL,
    message      TEXT,
    read         BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_price_alerts PRIMARY KEY (id),
    CONSTRAINT fk_price_alerts_user    FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_price_alerts_product FOREIGN KEY (product_id)
        REFERENCES products(id) ON DELETE CASCADE,
    CONSTRAINT fk_price_alerts_price_ref FOREIGN KEY (price_ref_id)
        REFERENCES price_refs(id) ON DELETE SET NULL,
    CONSTRAINT ck_price_alerts_type
        CHECK (alert_type IN ('PRICE_DROP', 'PRICE_RISE', 'BEST_PRICE'))
);

-- -----------------------------------------------------------------------------
-- LGPD AND AUDIT
-- -----------------------------------------------------------------------------

-- Record of a data-subject erasure (LGPD art. 18). Written BEFORE the
-- delete, so the proof survives the data.
-- Order of operations:
--   1) INSERT INTO data_erasure_requests
--   2) DELETE FROM users  (cascades to notes, staging, alerts)
-- The catalogue (products, stores, presentations) survives: it is not
-- personal data.
CREATE TABLE data_erasure_requests (
    id            UUID        NOT NULL DEFAULT gen_random_uuid(),
    user_id       UUID        NOT NULL,
    email         TEXT        NOT NULL,
    notes_removed INTEGER     NOT NULL DEFAULT 0,
    items_removed INTEGER     NOT NULL DEFAULT 0,
    requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    executed_at   TIMESTAMPTZ,
    reason        TEXT,

    CONSTRAINT pk_data_erasure_requests PRIMARY KEY (id),
    -- No FK to users, on purpose: this row must survive the DELETE it
    -- documents. Same argument as price_alerts.
    CONSTRAINT ck_data_erasure_notes CHECK (notes_removed >= 0),
    CONSTRAINT ck_data_erasure_items CHECK (items_removed >= 0)
);

-- user_id has NO FK, on purpose.
-- If audit_log.user_id referenced users(id), deleting the user would
-- abort: the CASCADE from purchase_notes/line_items fires the audit
-- trigger INSIDE the same transaction that has not yet removed the user
-- row. Reproduced: 'insert or update on table "audit_log" violates
-- foreign key constraint'. LGPD erasure would be impossible to execute.
--
-- user_id here is ACTOR METADATA, not business data, and a record of
-- something having happened must outlive whoever did it.
CREATE TABLE audit_log (
    id          BIGSERIAL   NOT NULL,
    user_id     UUID,
    table_name  TEXT        NOT NULL,
    operation   TEXT        NOT NULL,
    record_id   UUID,
    before_data JSONB,
    after_data  JSONB,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_audit_log PRIMARY KEY (id),
    CONSTRAINT ck_audit_log_operation
        CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE'))
);

COMMIT;
