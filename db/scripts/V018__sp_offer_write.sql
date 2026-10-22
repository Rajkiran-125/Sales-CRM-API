-- =============================================================================
-- V018  Sales CRM - offers, write side                                  (2026-10-13)
--
--   sp_offer_create   Create a DRAFT offer version on an opportunity.
--                     Computes approval_required from settings (OD-49).
--   sp_offer_submit   Submit a DRAFT offer:
--                       DRAFT → PENDING_APPROVAL  (approval_required = 1)
--                       DRAFT → APPROVED          (approval_required = 0)
--   sp_offer_approve  Approve or reject a PENDING_APPROVAL offer.
--                       → APPROVED or REJECTED
--   sp_offer_send     Send an APPROVED offer to the customer.
--                       APPROVED → SENT; schedules OFFER_EXPIRY task.
--   sp_offer_respond  Record the customer's response on a SENT offer.
--                       SENT → ACCEPTED or REJECTED
--   sp_offer_revise   Revise any non-SUPERSEDED offer: marks it SUPERSEDED,
--                     creates a new DRAFT copying the last offer's fields.
--
-- Approval thresholds (settings, OD-49):
--   offer.approval.discount_pct   default 15    (%)
--   offer.approval.value_limit    default 10000000 (INR)
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V017.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_offer_create
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_offer_create $$
CREATE PROCEDURE sp_offer_create(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_opportunity_id BIGINT UNSIGNED,
  IN p_offer_value    DECIMAL(16,2),
  IN p_list_value     DECIMAL(16,2),   -- nullable
  IN p_discount_pct   DECIMAL(5,2),    -- nullable
  IN p_value_adds     VARCHAR(2000),   -- nullable
  IN p_payment_terms  VARCHAR(500),    -- nullable
  IN p_valid_till     DATE,
  IN p_allow_any      TINYINT(1)       -- 1 = ALL-scope actor
)
  SQL SECURITY DEFINER
  COMMENT 'Create a DRAFT offer; compute approval_required from settings'
BEGIN
  DECLARE v_opp_no    VARCHAR(30);
  DECLARE v_owner     BIGINT UNSIGNED;
  DECLARE v_version   INT UNSIGNED;
  DECLARE v_offer_id  BIGINT UNSIGNED;
  DECLARE v_offer_no  VARCHAR(30);
  DECLARE v_approved  TINYINT DEFAULT 0;
  DECLARE v_disc_thr  DECIMAL(16,2);
  DECLARE v_val_lim   DECIMAL(16,2);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  -- ---- check opportunity ----
  SELECT opportunity_no, owner_user_id
    INTO v_opp_no, v_owner
    FROM opportunity
   WHERE id = p_opportunity_id AND is_active = 1;

  IF v_opp_no IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'opportunityId');
  END IF;

  -- ---- scope: own deal or ALL scope ----
  IF p_allow_any = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (
       SELECT 1 FROM user_hierarchy h
        WHERE h.ancestor_user_id = p_actor_user_id
          AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You can only create offers on your own deals.', 'opportunityId');
  END IF;

  -- ---- validTill must be today or later ----
  IF p_valid_till < UTC_DATE() THEN
    CALL spi_raise('VALIDATION_FAILED', 'Valid till must be today or a future date.', 'validTill');
  END IF;

  -- ---- compute approval_required ----
  CALL spi_setting_decimal('offer.approval.discount_pct', 15, v_disc_thr);
  CALL spi_setting_decimal('offer.approval.value_limit',  10000000, v_val_lim);
  IF (p_discount_pct IS NOT NULL AND p_discount_pct > v_disc_thr)
     OR p_offer_value > v_val_lim THEN
    SET v_approved = 1;
  END IF;

  -- ---- version number ----
  SELECT COALESCE(MAX(version_no), 0) + 1
    INTO v_version
    FROM offer WHERE opportunity_id = p_opportunity_id;

  SET v_offer_no = CONCAT(v_opp_no, '/v', v_version);

  START TRANSACTION;

  INSERT INTO offer (
    opportunity_id, version_no, offer_no,
    offer_value, list_value, discount_pct, value_adds, payment_terms, valid_till,
    status, approval_required,
    created_at, created_by
  ) VALUES (
    p_opportunity_id, v_version, v_offer_no,
    p_offer_value, p_list_value, p_discount_pct, p_value_adds, p_payment_terms, p_valid_till,
    'DRAFT', v_approved,
    UTC_TIMESTAMP(3), p_actor_user_id
  );
  SET v_offer_id = LAST_INSERT_ID();

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('offer', v_offer_id, 'OFFER_CREATE', NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT v_offer_id AS id, v_offer_no AS offerNo, v_version AS versionNo, v_approved AS approvalRequired;
END $$

-- ---------------------------------------------------------------------------
-- sp_offer_submit
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_offer_submit $$
CREATE PROCEDURE sp_offer_submit(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_offer_id       BIGINT UNSIGNED,
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
  COMMENT 'Submit DRAFT → PENDING_APPROVAL or APPROVED based on approval_required flag'
BEGIN
  DECLARE v_status     VARCHAR(16);
  DECLARE v_opp_id     BIGINT UNSIGNED;
  DECLARE v_owner      BIGINT UNSIGNED;
  DECLARE v_app_req    TINYINT;
  DECLARE v_new_status VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT f.status, f.opportunity_id, o.owner_user_id, f.approval_required
    INTO v_status, v_opp_id, v_owner, v_app_req
    FROM offer f
    JOIN opportunity o ON o.id = f.opportunity_id
   WHERE f.id = p_offer_id;

  IF v_status IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Offer not found.', 'id');
  END IF;
  IF v_status <> 'DRAFT' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Only DRAFT offers can be submitted.', 'status');
  END IF;

  -- scope check
  IF p_allow_any = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (
       SELECT 1 FROM user_hierarchy h
        WHERE h.ancestor_user_id = p_actor_user_id
          AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You can only submit offers on your own deals.', 'id');
  END IF;

  SET v_new_status = IF(v_app_req = 1, 'PENDING_APPROVAL', 'APPROVED');

  START TRANSACTION;

  UPDATE offer
     SET status       = v_new_status,
         submitted_by = p_actor_user_id,
         submitted_at = UTC_TIMESTAMP(3),
         updated_at   = UTC_TIMESTAMP(3),
         updated_by   = p_actor_user_id,
         row_version  = row_version + 1
   WHERE id = p_offer_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('offer', p_offer_id, 'OFFER_SUBMIT', NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_offer_id AS id, v_new_status AS status;
END $$

-- ---------------------------------------------------------------------------
-- sp_offer_approve
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_offer_approve $$
CREATE PROCEDURE sp_offer_approve(
  IN p_actor_user_id   BIGINT UNSIGNED,
  IN p_request_id      VARCHAR(36),
  IN p_ip              VARCHAR(45),
  IN p_offer_id        BIGINT UNSIGNED,
  IN p_approved        TINYINT(1),     -- 1 = approve, 0 = reject
  IN p_approval_remark VARCHAR(1000)   -- nullable; required on reject
)
  SQL SECURITY DEFINER
  COMMENT 'Approve or reject a PENDING_APPROVAL offer; APPROVED or REJECTED'
BEGIN
  DECLARE v_status     VARCHAR(16);
  DECLARE v_new_status VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT status INTO v_status FROM offer WHERE id = p_offer_id;

  IF v_status IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Offer not found.', 'id');
  END IF;
  IF v_status <> 'PENDING_APPROVAL' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Only offers pending approval can be approved or rejected.', 'status');
  END IF;
  IF p_approved = 0 AND (p_approval_remark IS NULL OR TRIM(p_approval_remark) = '') THEN
    CALL spi_raise('VALIDATION_FAILED', 'A remark is required when rejecting an offer.', 'approvalRemark');
  END IF;

  SET v_new_status = IF(p_approved = 1, 'APPROVED', 'REJECTED');

  START TRANSACTION;

  UPDATE offer
     SET status          = v_new_status,
         approved_by     = p_actor_user_id,
         approved_at     = UTC_TIMESTAMP(3),
         approval_remark = p_approval_remark,
         updated_at      = UTC_TIMESTAMP(3),
         updated_by      = p_actor_user_id,
         row_version     = row_version + 1
   WHERE id = p_offer_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('offer', p_offer_id, IF(p_approved = 1, 'OFFER_APPROVE', 'OFFER_REJECT'),
          NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_offer_id AS id, v_new_status AS status;
END $$

-- ---------------------------------------------------------------------------
-- sp_offer_send
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_offer_send $$
CREATE PROCEDURE sp_offer_send(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_offer_id       BIGINT UNSIGNED,
  IN p_sent_to        VARCHAR(500),  -- nullable; comma-separated recipients
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
  COMMENT 'Send APPROVED offer to customer; schedules OFFER_EXPIRY task'
BEGIN
  DECLARE v_status      VARCHAR(16);
  DECLARE v_valid_till  DATE;
  DECLARE v_opp_id      BIGINT UNSIGNED;
  DECLARE v_owner       BIGINT UNSIGNED;
  DECLARE v_warn_days   INT;
  DECLARE v_warn_date   DATE;
  DECLARE v_task_ref    VARCHAR(120);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT f.status, f.valid_till, f.opportunity_id, o.owner_user_id
    INTO v_status, v_valid_till, v_opp_id, v_owner
    FROM offer f
    JOIN opportunity o ON o.id = f.opportunity_id
   WHERE f.id = p_offer_id;

  IF v_status IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Offer not found.', 'id');
  END IF;
  IF v_status <> 'APPROVED' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Only APPROVED offers can be sent.', 'status');
  END IF;

  -- scope check
  IF p_allow_any = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (
       SELECT 1 FROM user_hierarchy h
        WHERE h.ancestor_user_id = p_actor_user_id
          AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You can only send offers on your own deals.', 'id');
  END IF;

  START TRANSACTION;

  UPDATE offer
     SET status     = 'SENT',
         sent_by    = p_actor_user_id,
         sent_at    = UTC_TIMESTAMP(3),
         sent_to    = p_sent_to,
         updated_at = UTC_TIMESTAMP(3),
         updated_by = p_actor_user_id,
         row_version = row_version + 1
   WHERE id = p_offer_id;

  -- schedule OFFER_EXPIRY task (skip if warning date is already past)
  CALL spi_setting_int('offer.expiry_warning_days', 3, v_warn_days);
  SET v_warn_date = v_valid_till - INTERVAL v_warn_days DAY;
  IF v_warn_date >= UTC_DATE() THEN
    SET v_task_ref = CONCAT('offer-', p_offer_id, '-expiry');
    INSERT IGNORE INTO task (
      entity_type, entity_id, task_type, title,
      owner_user_id, due_at, status, source_ref,
      created_at, created_by
    ) VALUES (
      'OFFER', p_offer_id, 'OFFER_EXPIRY',
      CONCAT('Offer ', (SELECT offer_no FROM offer WHERE id = p_offer_id), ' expires soon'),
      v_owner,
      CONCAT(v_warn_date, ' 09:00:00'), 'OPEN', v_task_ref,
      UTC_TIMESTAMP(3), p_actor_user_id
    );
  END IF;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('offer', p_offer_id, 'OFFER_SEND', NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_offer_id AS id, 'SENT' AS status;
END $$

-- ---------------------------------------------------------------------------
-- sp_offer_respond
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_offer_respond $$
CREATE PROCEDURE sp_offer_respond(
  IN p_actor_user_id    BIGINT UNSIGNED,
  IN p_request_id       VARCHAR(36),
  IN p_ip               VARCHAR(45),
  IN p_offer_id         BIGINT UNSIGNED,
  IN p_accepted         TINYINT(1),       -- 1 = accepted, 0 = rejected by customer
  IN p_customer_response VARCHAR(2000),   -- nullable
  IN p_allow_any        TINYINT(1)
)
  SQL SECURITY DEFINER
  COMMENT 'Record customer ACCEPTED or REJECTED on a SENT offer'
BEGIN
  DECLARE v_status     VARCHAR(16);
  DECLARE v_opp_id     BIGINT UNSIGNED;
  DECLARE v_owner      BIGINT UNSIGNED;
  DECLARE v_new_status VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT f.status, f.opportunity_id, o.owner_user_id
    INTO v_status, v_opp_id, v_owner
    FROM offer f
    JOIN opportunity o ON o.id = f.opportunity_id
   WHERE f.id = p_offer_id;

  IF v_status IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Offer not found.', 'id');
  END IF;
  IF v_status <> 'SENT' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Only SENT offers can record a customer response.', 'status');
  END IF;

  -- scope check
  IF p_allow_any = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (
       SELECT 1 FROM user_hierarchy h
        WHERE h.ancestor_user_id = p_actor_user_id
          AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You can only record responses on your own deals.', 'id');
  END IF;

  SET v_new_status = IF(p_accepted = 1, 'ACCEPTED', 'REJECTED');

  START TRANSACTION;

  UPDATE offer
     SET status                 = v_new_status,
         customer_response      = p_customer_response,
         customer_responded_at  = UTC_TIMESTAMP(3),
         updated_at             = UTC_TIMESTAMP(3),
         updated_by             = p_actor_user_id,
         row_version            = row_version + 1
   WHERE id = p_offer_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('offer', p_offer_id, IF(p_accepted = 1, 'OFFER_ACCEPTED', 'OFFER_REJECTED_CUSTOMER'),
          NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_offer_id AS id, v_new_status AS status;
END $$

-- ---------------------------------------------------------------------------
-- sp_offer_revise
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_offer_revise $$
CREATE PROCEDURE sp_offer_revise(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_offer_id       BIGINT UNSIGNED,
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
  COMMENT 'Supersede offer and create a new DRAFT copying its fields'
BEGIN
  DECLARE v_status      VARCHAR(16);
  DECLARE v_opp_id      BIGINT UNSIGNED;
  DECLARE v_owner       BIGINT UNSIGNED;
  DECLARE v_opp_no      VARCHAR(30);
  DECLARE v_new_version INT UNSIGNED;
  DECLARE v_new_no      VARCHAR(30);
  DECLARE v_new_id      BIGINT UNSIGNED;
  DECLARE v_app_req     TINYINT;
  DECLARE v_disc_thr    DECIMAL(16,2);
  DECLARE v_val_lim     DECIMAL(16,2);
  DECLARE v_offer_val   DECIMAL(16,2);
  DECLARE v_disc_pct    DECIMAL(5,2);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT f.status, f.opportunity_id, o.owner_user_id, o.opportunity_no,
         f.offer_value, f.discount_pct
    INTO v_status, v_opp_id, v_owner, v_opp_no,
         v_offer_val, v_disc_pct
    FROM offer f
    JOIN opportunity o ON o.id = f.opportunity_id
   WHERE f.id = p_offer_id;

  IF v_status IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Offer not found.', 'id');
  END IF;
  IF v_status = 'SUPERSEDED' THEN
    CALL spi_raise('VALIDATION_FAILED', 'A superseded offer cannot be revised again.', 'status');
  END IF;

  -- scope check
  IF p_allow_any = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (
       SELECT 1 FROM user_hierarchy h
        WHERE h.ancestor_user_id = p_actor_user_id
          AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You can only revise offers on your own deals.', 'id');
  END IF;

  -- compute new approval_required for the new draft
  CALL spi_setting_decimal('offer.approval.discount_pct', 15, v_disc_thr);
  CALL spi_setting_decimal('offer.approval.value_limit',  10000000, v_val_lim);
  SET v_app_req = IF((v_disc_pct IS NOT NULL AND v_disc_pct > v_disc_thr)
                     OR v_offer_val > v_val_lim, 1, 0);

  SELECT COALESCE(MAX(version_no), 0) + 1
    INTO v_new_version
    FROM offer WHERE opportunity_id = v_opp_id;

  SET v_new_no = CONCAT(v_opp_no, '/v', v_new_version);

  START TRANSACTION;

  -- mark old offer superseded
  UPDATE offer
     SET status     = 'SUPERSEDED',
         updated_at = UTC_TIMESTAMP(3),
         updated_by = p_actor_user_id,
         row_version = row_version + 1
   WHERE id = p_offer_id;

  -- copy fields to new DRAFT
  INSERT INTO offer (
    opportunity_id, version_no, offer_no,
    offer_value, list_value, discount_pct, value_adds, payment_terms, valid_till,
    status, approval_required, created_at, created_by
  )
  SELECT opportunity_id, v_new_version, v_new_no,
         offer_value, list_value, discount_pct, value_adds, payment_terms, valid_till,
         'DRAFT', v_app_req, UTC_TIMESTAMP(3), p_actor_user_id
    FROM offer WHERE id = p_offer_id;

  SET v_new_id = LAST_INSERT_ID();

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('offer', p_offer_id, 'OFFER_SUPERSEDE', NULL, p_actor_user_id, p_ip, p_request_id),
         ('offer', v_new_id,   'OFFER_CREATE',    NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT v_new_id AS id, v_new_no AS offerNo, v_new_version AS versionNo;
END $$

DELIMITER ;
