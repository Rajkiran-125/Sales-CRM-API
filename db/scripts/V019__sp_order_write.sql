-- =============================================================================
-- V019  Sales CRM - orders, write side                                (2026-10-13)
--
--   Re-creates sp_opportunity_close to auto-create a sales_order on WON (BR-OR-01).
--   sp_order_event     Record an order status event (BR-OR-02).
--   sp_invoice_create  Raise an invoice; first invoice sets order-to-book (BR-OR-03).
--   sp_invoice_update  Edit an existing invoice.
--   sp_payment_create  Record a received or released payment; enforce BR-OR-04,05.
--   sp_order_finance   Finance-only patch: revenue, GM %, NP % (BR-OR-06).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V018.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- =============================================================================
-- Re-create sp_opportunity_close: adds order auto-create on WON (BR-OR-01)
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_opportunity_close $$
CREATE PROCEDURE sp_opportunity_close(
  IN p_actor_user_id    BIGINT UNSIGNED,
  IN p_request_id       VARCHAR(64),
  IN p_ip               VARCHAR(45),
  IN p_opp_id           BIGINT UNSIGNED,
  IN p_row_version      INT UNSIGNED,
  IN p_outcome          VARCHAR(10),    -- WON / LOST / DORMANT
  -- WON fields
  IN p_final_value      DECIMAL(16,2),
  IN p_po_number        VARCHAR(60),
  IN p_po_value         DECIMAL(16,2),
  IN p_po_date          DATE,
  -- LOST fields
  IN p_loss_reason_ids  JSON,           -- array of reason IDs
  IN p_competitor_id    BIGINT UNSIGNED,
  -- DORMANT fields
  IN p_dormant_reason_id BIGINT UNSIGNED,
  IN p_dormant_note     VARCHAR(1000),
  IN p_wake_up_date     DATE
)
  SQL SECURITY DEFINER
  COMMENT 'Close as WON (creates order, BR-OR-01), LOST or DORMANT (BR-OP-05)'
BEGIN
  DECLARE v_stage    VARCHAR(20);
  DECLARE v_version  INT UNSIGNED;
  DECLARE v_owner    BIGINT UNSIGNED;
  DECLARE v_source   VARCHAR(10);
  DECLARE v_all      TINYINT;
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;
  -- WON extras
  DECLARE v_account_id    BIGINT UNSIGNED;
  DECLARE v_partner_id    BIGINT UNSIGNED;
  DECLARE v_pay_after_cus TINYINT(1) DEFAULT 0;
  DECLARE v_order_no      VARCHAR(30);
  DECLARE v_order_id      BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_outcome NOT IN ('WON', 'LOST', 'DORMANT') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Outcome must be WON, LOST or DORMANT.', 'outcome');
  END IF;

  SELECT stage_code, row_version, owner_user_id, source, account_id
    INTO v_stage, v_version, v_owner, v_source, v_account_id
    FROM opportunity WHERE id = p_opp_id;

  IF v_stage IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
  END IF;
  IF v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;
  IF v_stage IN ('WON', 'LOST') THEN
    CALL spi_raise('VALIDATION_FAILED', 'This opportunity is already closed.', 'stageCode');
  END IF;

  -- scope check
  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You do not have permission to close this opportunity.', 'id');
  END IF;

  -- outcome-specific validation
  IF p_outcome = 'WON' THEN
    IF p_final_value IS NULL OR p_final_value <= 0 THEN
      CALL spi_raise('VALIDATION_FAILED', 'Enter the final closed value.', 'finalValue');
    END IF;
    IF p_po_number IS NULL OR TRIM(p_po_number) = '' THEN
      CALL spi_raise('VALIDATION_FAILED', 'Enter the PO number.', 'poNumber');
    END IF;
    IF p_po_value IS NULL OR p_po_value <= 0 THEN
      CALL spi_raise('VALIDATION_FAILED', 'Enter the PO value.', 'poValue');
    END IF;
    IF p_po_date IS NULL THEN
      CALL spi_raise('VALIDATION_FAILED', 'Enter the PO date.', 'poDate');
    END IF;
  END IF;

  IF p_outcome = 'LOST' THEN
    IF p_loss_reason_ids IS NULL OR JSON_LENGTH(p_loss_reason_ids) = 0 THEN
      CALL spi_raise('VALIDATION_FAILED', 'Choose at least one loss reason.', 'lossReasonIds');
    END IF;
  END IF;

  IF p_outcome = 'DORMANT' THEN
    IF p_dormant_reason_id IS NULL THEN
      CALL spi_raise('VALIDATION_FAILED', 'Choose a reason for marking dormant.', 'dormantReasonId');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM reason WHERE id = p_dormant_reason_id AND reason_type = 'DORMANT' AND is_active = 1) THEN
      CALL spi_raise('VALIDATION_FAILED', 'Invalid dormant reason.', 'dormantReasonId');
    END IF;
    IF p_wake_up_date IS NULL THEN
      CALL spi_raise('VALIDATION_FAILED', 'Set a wake-up date for the dormant opportunity.', 'wakeUpDate');
    END IF;
  END IF;

  START TRANSACTION;

  IF p_outcome = 'WON' THEN
    UPDATE opportunity SET
      stage_code           = 'WON',
      stage_entered_at     = UTC_TIMESTAMP(3),
      previous_stage_code  = v_stage,
      final_value          = p_final_value,
      po_number            = TRIM(p_po_number),
      po_value             = p_po_value,
      po_date              = p_po_date,
      closed_at            = UTC_TIMESTAMP(3),
      updated_by           = p_actor_user_id,
      updated_at           = UTC_TIMESTAMP(3),
      row_version          = row_version + 1
    WHERE id = p_opp_id AND row_version = p_row_version;

    IF ROW_COUNT() = 0 THEN
      ROLLBACK;
      CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
    END IF;

    INSERT INTO win_loss (opportunity_id, outcome, competitor_id, recorded_by, recorded_at)
    VALUES (p_opp_id, 'WON', p_competitor_id, p_actor_user_id, UTC_TIMESTAMP(3));

    INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
    VALUES ('OPP', p_opp_id, v_stage, 'WON', p_actor_user_id);

    -- BR-OR-01: auto-create the sales order ----------------------------------------
    -- primary sourced partner (if any)
    SELECT op.partner_id INTO v_partner_id
      FROM opportunity_partner op
     WHERE op.opportunity_id = p_opp_id AND op.is_primary = 1
     LIMIT 1;

    -- pay_partner_after_customer from the latest partner_commercial (if any)
    SELECT pc.pay_partner_after_customer INTO v_pay_after_cus
      FROM partner_commercial pc
     WHERE pc.opportunity_id = p_opp_id
     ORDER BY pc.version_no DESC
     LIMIT 1;

    CALL spi_next_number('OR', 1, v_order_no);

    INSERT INTO sales_order
      (order_no, opportunity_id, account_id, fulfilment_partner_id,
       po_number, po_date, po_value, pay_partner_after_customer,
       status, created_by, updated_by, updated_at)
    VALUES
      (v_order_no, p_opp_id, v_account_id, v_partner_id,
       TRIM(p_po_number), p_po_date, p_po_value, COALESCE(v_pay_after_cus, 0),
       'PO_RECEIVED', p_actor_user_id, p_actor_user_id, UTC_TIMESTAMP(3));

    SET v_order_id = LAST_INSERT_ID();

    -- first event: PO_RECEIVED
    INSERT INTO order_event (order_id, status, event_date, by_user_id, remark)
    VALUES (v_order_id, 'PO_RECEIVED', p_po_date, p_actor_user_id, NULL);
    -- -------------------------------------------------------------------------------

  ELSEIF p_outcome = 'LOST' THEN
    UPDATE opportunity SET
      stage_code           = 'LOST',
      stage_entered_at     = UTC_TIMESTAMP(3),
      previous_stage_code  = v_stage,
      closed_at            = UTC_TIMESTAMP(3),
      updated_by           = p_actor_user_id,
      updated_at           = UTC_TIMESTAMP(3),
      row_version          = row_version + 1
    WHERE id = p_opp_id AND row_version = p_row_version;

    IF ROW_COUNT() = 0 THEN
      ROLLBACK;
      CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
    END IF;

    -- primary loss reason (first in array)
    INSERT INTO win_loss (opportunity_id, outcome, loss_reason_id, competitor_id, recorded_by, recorded_at)
    SELECT p_opp_id, 'LOST',
           CAST(JSON_UNQUOTE(JSON_EXTRACT(p_loss_reason_ids, '$[0]')) AS UNSIGNED),
           p_competitor_id, p_actor_user_id, UTC_TIMESTAMP(3);

    -- all loss reasons
    INSERT INTO win_loss_reason (opportunity_id, reason_id)
    SELECT DISTINCT p_opp_id, CAST(jt.reason_id AS UNSIGNED)
      FROM JSON_TABLE(p_loss_reason_ids, '$[*]' COLUMNS (reason_id BIGINT UNSIGNED PATH '$')) jt
      JOIN reason r ON r.id = jt.reason_id AND r.reason_type = 'LOSS' AND r.is_active = 1;

    INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
    VALUES ('OPP', p_opp_id, v_stage, 'LOST', p_actor_user_id);

  ELSE -- DORMANT
    UPDATE opportunity SET
      stage_code           = 'DORMANT',
      stage_entered_at     = UTC_TIMESTAMP(3),
      previous_stage_code  = v_stage,
      dormant_reason_id    = p_dormant_reason_id,
      dormant_note         = NULLIF(TRIM(COALESCE(p_dormant_note, '')), ''),
      wake_up_date         = p_wake_up_date,
      updated_by           = p_actor_user_id,
      updated_at           = UTC_TIMESTAMP(3),
      row_version          = row_version + 1
    WHERE id = p_opp_id AND row_version = p_row_version;

    IF ROW_COUNT() = 0 THEN
      ROLLBACK;
      CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
    END IF;

    INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
    VALUES ('OPP', p_opp_id, v_stage, 'DORMANT', p_actor_user_id);
  END IF;

  CALL spi_opp_weighted(p_opp_id);

  CALL spi_audit_write('OPP', p_opp_id, 'CLOSE',
       JSON_OBJECT('stageCode', JSON_OBJECT('from', v_stage, 'to', p_outcome)),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_opp_id AS id;
END $$

-- =============================================================================
-- sp_order_event: record a status event (BR-OR-02)
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_order_event $$
CREATE PROCEDURE sp_order_event(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_order_id      BIGINT UNSIGNED,
  IN p_status        VARCHAR(16),
  IN p_event_date    DATE,
  IN p_remark        VARCHAR(1000),
  IN p_document_id   BIGINT UNSIGNED,  -- nullable
  IN p_allow_any     TINYINT(1)        -- 1 = ALL-scope actor
)
  SQL SECURITY DEFINER
  COMMENT 'Record an order status event; advance order status (BR-OR-02)'
BEGIN
  DECLARE v_cur_status VARCHAR(16);
  DECLARE v_po_date    DATE;
  DECLARE v_cur_seq    SMALLINT UNSIGNED;
  DECLARE v_new_seq    SMALLINT UNSIGNED;
  DECLARE v_owner      BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  -- load order
  SELECT so.status, so.po_date, o.owner_user_id
    INTO v_cur_status, v_po_date, v_owner
    FROM sales_order so
    JOIN opportunity o ON o.id = so.opportunity_id
   WHERE so.id = p_order_id;

  IF v_cur_status IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Order not found.', 'id');
  END IF;

  -- scope check (own deal or ALL)
  IF p_allow_any = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You can only update events on your own orders.', 'id');
  END IF;

  -- BR-OR-02: new status must be in sequence at or after current status
  SELECT sequence_no INTO v_cur_seq FROM stage WHERE entity = 'ORDER' AND code = v_cur_status;
  SELECT sequence_no INTO v_new_seq FROM stage WHERE entity = 'ORDER' AND code = p_status AND is_active = 1;

  IF v_new_seq IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid order status.', 'status');
  END IF;
  IF v_new_seq < v_cur_seq THEN
    CALL spi_raise('VALIDATION_FAILED', 'Event status cannot go backwards in the order sequence.', 'status');
  END IF;

  -- BR-OR-02: event date must not precede PO date
  IF p_event_date < v_po_date THEN
    CALL spi_raise('VALIDATION_FAILED', 'Event date cannot be before the PO date.', 'eventDate');
  END IF;

  -- document visibility check (if provided)
  IF p_document_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM document WHERE id = p_document_id) THEN
    CALL spi_raise('NOT_FOUND', 'Document not found.', 'documentId');
  END IF;

  START TRANSACTION;

  INSERT INTO order_event (order_id, status, event_date, by_user_id, remark, document_id)
  VALUES (p_order_id, p_status, p_event_date, p_actor_user_id,
          NULLIF(TRIM(COALESCE(p_remark, '')), ''), p_document_id);

  -- advance order status
  UPDATE sales_order SET
    status     = p_status,
    updated_by = p_actor_user_id,
    updated_at = UTC_TIMESTAMP(3),
    row_version = row_version + 1
  WHERE id = p_order_id;

  CALL spi_audit_write('ORDER', p_order_id, 'EVENT',
       JSON_OBJECT('status', p_status, 'eventDate', p_event_date),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_order_id AS id, p_status AS status;
END $$

-- =============================================================================
-- sp_invoice_create: raise an invoice; first invoice sets order-to-book (BR-OR-03)
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_invoice_create $$
CREATE PROCEDURE sp_invoice_create(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_order_id      BIGINT UNSIGNED,
  IN p_invoice_no    VARCHAR(60),
  IN p_invoice_date  DATE,
  IN p_due_date      DATE,
  IN p_amount        DECIMAL(16,2),
  IN p_document_id   BIGINT UNSIGNED   -- nullable
)
  SQL SECURITY DEFINER
  COMMENT 'Raise an invoice; set order-to-book on first invoice (BR-OR-03)'
BEGIN
  DECLARE v_order_exists  TINYINT DEFAULT 0;
  DECLARE v_po_value      DECIMAL(16,2);
  DECLARE v_po_date       DATE;
  DECLARE v_first_inv     DATE;
  DECLARE v_inv_id        BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT 1, po_value, po_date, first_invoice_on
    INTO v_order_exists, v_po_value, v_po_date, v_first_inv
    FROM sales_order WHERE id = p_order_id;

  IF v_order_exists = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Order not found.', 'id');
  END IF;

  -- validation
  IF p_amount IS NULL OR p_amount <= 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invoice amount must be greater than zero.', 'amount');
  END IF;
  IF p_due_date < p_invoice_date THEN
    CALL spi_raise('VALIDATION_FAILED', 'Due date cannot be before invoice date.', 'dueDate');
  END IF;
  IF EXISTS (SELECT 1 FROM invoice WHERE invoice_no = p_invoice_no) THEN
    CALL spi_raise('CONFLICT', 'Invoice number already exists.', 'invoiceNo');
  END IF;

  START TRANSACTION;

  INSERT INTO invoice (order_id, invoice_no, invoice_date, due_date, amount, created_by)
  VALUES (p_order_id, TRIM(p_invoice_no), p_invoice_date, p_due_date, p_amount, p_actor_user_id);

  SET v_inv_id = LAST_INSERT_ID();

  -- update order: invoiced_value and optionally first_invoice_on + order_to_book_days (BR-OR-03)
  UPDATE sales_order SET
    invoiced_value    = invoiced_value + p_amount,
    first_invoice_on  = CASE WHEN v_first_inv IS NULL THEN p_invoice_date ELSE first_invoice_on END,
    order_to_book_days = CASE WHEN v_first_inv IS NULL
                              THEN DATEDIFF(p_invoice_date, po_date)
                              ELSE order_to_book_days END,
    updated_by        = p_actor_user_id,
    updated_at        = UTC_TIMESTAMP(3),
    row_version       = row_version + 1
  WHERE id = p_order_id;

  CALL spi_audit_write('ORDER', p_order_id, 'INVOICE_CREATE',
       JSON_OBJECT('invoiceNo', p_invoice_no, 'amount', p_amount),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT v_inv_id AS id;
END $$

-- =============================================================================
-- sp_invoice_update: edit invoice fields
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_invoice_update $$
CREATE PROCEDURE sp_invoice_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_invoice_id    BIGINT UNSIGNED,
  IN p_invoice_no    VARCHAR(60),
  IN p_invoice_date  DATE,
  IN p_due_date      DATE,
  IN p_amount        DECIMAL(16,2),
  IN p_document_id   BIGINT UNSIGNED   -- nullable
)
  SQL SECURITY DEFINER
  COMMENT 'Edit an existing invoice'
BEGIN
  DECLARE v_order_id  BIGINT UNSIGNED;
  DECLARE v_old_amount DECIMAL(16,2);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT order_id, amount INTO v_order_id, v_old_amount
    FROM invoice WHERE id = p_invoice_id;

  IF v_order_id IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Invoice not found.', 'invoiceId');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invoice amount must be greater than zero.', 'amount');
  END IF;
  IF p_due_date < p_invoice_date THEN
    CALL spi_raise('VALIDATION_FAILED', 'Due date cannot be before invoice date.', 'dueDate');
  END IF;

  -- check for duplicate invoice_no (excluding self)
  IF EXISTS (SELECT 1 FROM invoice WHERE invoice_no = p_invoice_no AND id <> p_invoice_id) THEN
    CALL spi_raise('CONFLICT', 'Invoice number already exists.', 'invoiceNo');
  END IF;

  START TRANSACTION;

  UPDATE invoice SET
    invoice_no    = TRIM(p_invoice_no),
    invoice_date  = p_invoice_date,
    due_date      = p_due_date,
    amount        = p_amount,
    document_id   = p_document_id,
    updated_by    = p_actor_user_id,
    updated_at    = UTC_TIMESTAMP(3)
  WHERE id = p_invoice_id;

  -- keep invoiced_value in sync on the order
  UPDATE sales_order SET
    invoiced_value = invoiced_value - v_old_amount + p_amount,
    updated_by     = p_actor_user_id,
    updated_at     = UTC_TIMESTAMP(3),
    row_version    = row_version + 1
  WHERE id = v_order_id;

  CALL spi_audit_write('ORDER', v_order_id, 'INVOICE_UPDATE',
       JSON_OBJECT('invoiceId', p_invoice_id, 'amount', p_amount),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_invoice_id AS id;
END $$

-- =============================================================================
-- sp_payment_create: record a received or released payment (BR-OR-04, BR-OR-05)
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_payment_create $$
CREATE PROCEDURE sp_payment_create(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_order_id      BIGINT UNSIGNED,
  IN p_direction     VARCHAR(8),       -- RECEIVED / RELEASED
  IN p_invoice_id    BIGINT UNSIGNED,  -- nullable
  IN p_partner_id    BIGINT UNSIGNED,  -- nullable; required when RELEASED
  IN p_amount        DECIMAL(16,2),
  IN p_paid_on       DATE,
  IN p_reference     VARCHAR(100),     -- nullable
  IN p_remarks       VARCHAR(1000)     -- nullable
)
  SQL SECURITY DEFINER
  COMMENT 'Record a customer or partner payment; enforce BR-OR-04, BR-OR-05'
BEGIN
  DECLARE v_po_date         DATE;
  DECLARE v_pay_after_cus   TINYINT(1);
  DECLARE v_received_value  DECIMAL(16,2);
  DECLARE v_released_value  DECIMAL(16,2);
  DECLARE v_inv_due_date    DATE;
  DECLARE v_delay_days      INT DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT po_date, pay_partner_after_customer, received_value, released_to_partner_value
    INTO v_po_date, v_pay_after_cus, v_received_value, v_released_value
    FROM sales_order WHERE id = p_order_id;

  IF v_po_date IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Order not found.', 'id');
  END IF;

  IF p_direction NOT IN ('RECEIVED', 'RELEASED') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Direction must be RECEIVED or RELEASED.', 'direction');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Amount must be greater than zero.', 'amount');
  END IF;

  -- RELEASED requires a partner
  IF p_direction = 'RELEASED' AND p_partner_id IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'A partner is required for a released payment.', 'partnerId');
  END IF;

  -- BR-OR-05: when pay_partner_after_customer, released total + new amount must not exceed received total
  IF p_direction = 'RELEASED' AND v_pay_after_cus = 1 THEN
    IF (v_released_value + p_amount) > v_received_value THEN
      CALL spi_raise('BUSINESS_RULE_VIOLATION',
           'Partner payment cannot be released until sufficient customer payment is received (BR-OR-05).',
           'amount');
    END IF;
  END IF;

  -- BR-OR-04: compute delay days for RECEIVED payments linked to an invoice
  IF p_direction = 'RECEIVED' AND p_invoice_id IS NOT NULL THEN
    SELECT due_date INTO v_inv_due_date FROM invoice WHERE id = p_invoice_id AND order_id = p_order_id;
    IF v_inv_due_date IS NULL THEN
      CALL spi_raise('NOT_FOUND', 'Invoice not found for this order.', 'invoiceId');
    END IF;
    -- delay is positive when paid after due date (BR-OR-04)
    IF p_paid_on > v_inv_due_date THEN
      SET v_delay_days = DATEDIFF(p_paid_on, v_inv_due_date);
    ELSE
      SET v_delay_days = 0;
    END IF;
  END IF;

  START TRANSACTION;

  INSERT INTO payment
    (order_id, invoice_id, direction, partner_id, amount, paid_on, reference, delay_days, remarks, created_by)
  VALUES
    (p_order_id, p_invoice_id, p_direction, p_partner_id, p_amount, p_paid_on,
     NULLIF(TRIM(COALESCE(p_reference, '')), ''), v_delay_days,
     NULLIF(TRIM(COALESCE(p_remarks, '')), ''), p_actor_user_id);

  -- update order running totals
  UPDATE sales_order SET
    received_value             = received_value +
                                 CASE WHEN p_direction = 'RECEIVED' THEN p_amount ELSE 0 END,
    released_to_partner_value  = released_to_partner_value +
                                 CASE WHEN p_direction = 'RELEASED' THEN p_amount ELSE 0 END,
    updated_by                 = p_actor_user_id,
    updated_at                 = UTC_TIMESTAMP(3),
    row_version                = row_version + 1
  WHERE id = p_order_id;

  -- mark the linked invoice as paid/part-paid when a RECEIVED payment closes it
  IF p_direction = 'RECEIVED' AND p_invoice_id IS NOT NULL THEN
    UPDATE invoice SET
      paid_amount = paid_amount + p_amount,
      status = CASE
                 WHEN paid_amount + p_amount >= amount THEN 'PAID'
                 WHEN paid_amount + p_amount > 0       THEN 'PART_PAID'
                 ELSE status
               END,
      updated_by = p_actor_user_id,
      updated_at = UTC_TIMESTAMP(3)
    WHERE id = p_invoice_id;
  END IF;

  CALL spi_audit_write('ORDER', p_order_id, 'PAYMENT',
       JSON_OBJECT('direction', p_direction, 'amount', p_amount),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT LAST_INSERT_ID() AS id;
END $$

-- =============================================================================
-- sp_order_finance: finance-only patch — revenue, GM %, NP % (BR-OR-06)
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_order_finance $$
CREATE PROCEDURE sp_order_finance(
  IN p_actor_user_id   BIGINT UNSIGNED,
  IN p_request_id      VARCHAR(64),
  IN p_ip              VARCHAR(45),
  IN p_order_id        BIGINT UNSIGNED,
  IN p_revenue         DECIMAL(16,2),  -- nullable
  IN p_gm_pct          DECIMAL(5,2),   -- nullable
  IN p_np_pct          DECIMAL(5,2),   -- nullable
  IN p_recognised_on   DATE            -- nullable
)
  SQL SECURITY DEFINER
  COMMENT 'Update revenue and margin fields; finance only (BR-OR-06)'
BEGIN
  DECLARE v_exists TINYINT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT 1 INTO v_exists FROM sales_order WHERE id = p_order_id;

  IF v_exists = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Order not found.', 'id');
  END IF;

  IF p_gm_pct IS NOT NULL AND (p_gm_pct < -100 OR p_gm_pct > 100) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Gross margin % must be between -100 and 100.', 'gmPct');
  END IF;
  IF p_np_pct IS NOT NULL AND (p_np_pct < -100 OR p_np_pct > 100) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Net profit % must be between -100 and 100.', 'npPct');
  END IF;

  START TRANSACTION;

  UPDATE sales_order SET
    revenue               = p_revenue,
    gross_margin_pct      = p_gm_pct,
    net_profit_pct        = p_np_pct,
    revenue_recognised_on = p_recognised_on,
    updated_by            = p_actor_user_id,
    updated_at            = UTC_TIMESTAMP(3),
    row_version           = row_version + 1
  WHERE id = p_order_id;

  CALL spi_audit_write('ORDER', p_order_id, 'FINANCE',
       JSON_OBJECT('revenue', p_revenue, 'gmPct', p_gm_pct, 'npPct', p_np_pct),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_order_id AS id;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V019', 'Order write side: auto-create on WON, events, invoices, payments, finance', UTC_TIMESTAMP());
