-- =============================================================================
-- home_shopper -- part 3: triggers
-- PostgreSQL 16
--
-- Naming: tr_<table>_<what it does>
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- updated_at maintenance
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_users_touch
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER tr_products_touch
    BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER tr_staging_receipts_touch
    BEFORE UPDATE ON staging_receipts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Accounting checksum
-- -----------------------------------------------------------------------------
-- A receipt (R$ 550,93 gross, R$ 6,00 discount, R$ 544,93 paid)
-- proved the formula must be SUM(line_total), not
-- SUM(quantity * unit_price):
--
-- The tax authority rounds THE LINE, not the product.
--   1,446 kg x 39,90 = 57,6954  --> stored as 57,70
-- Summing raw products and comparing against rounded line totals reports
-- a false divergence on any receipt with a by-weight item.
--
-- The final comparison also uses a TOLERANCE, never exact equality.
--
-- The trigger lives on staging_lines (that is what changes) but writes to
-- staging_receipts (the aggregate), so it updates the parent by key.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION compute_receipt_divergence() RETURNS TRIGGER AS $$
DECLARE
    v_receipt UUID;
    v_sum     NUMERIC(14,2);
BEGIN
    -- On DELETE, NEW is null: fall back to OLD.
    v_receipt := coalesce(NEW.receipt_id, OLD.receipt_id);

    -- Discarded lines are excluded: an item rejected during review (OCR
    -- error, invalid line) must not keep composing the sum, or the real
    -- divergence stays invisible while the review queue counts it as
    -- resolved.
    SELECT coalesce(sum(line_total), 0) INTO v_sum
      FROM staging_lines
     WHERE receipt_id = v_receipt
       AND NOT discarded;

    UPDATE staging_receipts
       SET total_computed   = round(v_sum, 2),
           divergence_cents = CASE
               WHEN total_gross IS NULL THEN NULL
               ELSE round((total_gross - v_sum) * 100)::INTEGER
           END,
           updated_at = now()
     WHERE id = v_receipt;

    RETURN coalesce(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_staging_lines_checksum
    AFTER INSERT OR UPDATE OR DELETE ON staging_lines
    FOR EACH ROW EXECUTE FUNCTION compute_receipt_divergence();

-- -----------------------------------------------------------------------------
-- Base price: re-express the price in the product's comparison unit
-- -----------------------------------------------------------------------------
--   base_price = unit_price / factor_base
--
-- Examples (base unit G):
--   Beef mince 1kg, presentation pc -> factor 1000
--     29,90 / 1000 = 0,029900 per g
--   Beef tripe sold by weight, presentation kg -> factor 1000
--     39,90 / 1000 = 0,039900 per g
--   Crab stick 250 g, presentation pc -> factor 250
--     10,90 / 250  = 0,043600 per g
-- Now all three are comparable. Without this, the dashboard would report
-- that the 250 g pack costs more than the kilogram, which is absurd.
--
-- Note the by-weight case: sale_unit 'kg' means SOLD BY WEIGHT, not
-- "price per kg". The factor is the PRICE REFERENCE (1 kg = 1000 g); the
-- weight actually bought (1,446) belongs to line_items.quantity.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION compute_base_price() RETURNS TRIGGER AS $$
DECLARE
    v_factor NUMERIC(14,6);
BEGIN
    SELECT p.factor_base, pr.base_unit
      INTO v_factor, NEW.base_unit
      FROM products pr
      JOIN presentations p ON p.product_id = pr.id AND p.id = NEW.presentation_id
     WHERE pr.id = NEW.product_id;

    IF v_factor IS NULL THEN
        RAISE EXCEPTION
            'presentation_id is required: without the conversion factor the '
            'price cannot be expressed in the base unit (product_id=%)',
            NEW.product_id
            USING ERRCODE = '23514';
    END IF;

    NEW.base_price := round(NEW.unit_price / v_factor, 8);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_line_items_base_price
    BEFORE INSERT OR UPDATE ON line_items
    FOR EACH ROW EXECUTE FUNCTION compute_base_price();

-- -----------------------------------------------------------------------------
-- Audit trail
-- -----------------------------------------------------------------------------
-- Only on tables carrying purchase data. Catalogue tables stay out of it
-- so the log does not fill with noise.
CREATE OR REPLACE FUNCTION write_audit_entry() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (user_id, table_name, operation, record_id, before_data)
        VALUES (current_setting('app.user_id', true)::UUID,
                TG_TABLE_NAME, 'DELETE', OLD.id, to_jsonb(OLD));
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (user_id, table_name, operation, record_id,
                               before_data, after_data)
        VALUES (current_setting('app.user_id', true)::UUID,
                TG_TABLE_NAME, 'UPDATE', NEW.id, to_jsonb(OLD), to_jsonb(NEW));
    ELSE
        INSERT INTO audit_log (user_id, table_name, operation, record_id, after_data)
        VALUES (current_setting('app.user_id', true)::UUID,
                TG_TABLE_NAME, 'INSERT', NEW.id, to_jsonb(NEW));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_purchase_notes_audit
    AFTER INSERT OR UPDATE OR DELETE ON purchase_notes
    FOR EACH ROW EXECUTE FUNCTION write_audit_entry();

CREATE TRIGGER tr_line_items_audit
    AFTER INSERT OR UPDATE OR DELETE ON line_items
    FOR EACH ROW EXECUTE FUNCTION write_audit_entry();

COMMIT;
