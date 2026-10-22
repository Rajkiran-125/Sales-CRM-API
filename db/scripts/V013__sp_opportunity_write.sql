-- =============================================================================
-- V013  Sales CRM - opportunities, write side                          (2026-10-12)
--
--   spi_opp_weighted      Internal helper: recalculate weighted_value from
--                         expected_value × fx_rate × confidence_pct.
--   sp_opportunity_update Edit core fields (title, value, close date, solution,
--                         procurement, owners, products, confidence). Resets
--                         validation_status to PENDING when value or close date
--                         changes (BR-OP-08).
--   sp_opportunity_move_stage  Advance to the next open stage in the stepper
--                         (forward only unless stage_override is allowed by the
--                         route layer).
--   sp_opportunity_validate  Mark VALID or NOT_VALID with an optional remark.
--   sp_opportunity_close  Close as WON (with PO), LOST (with reasons) or DORMANT
--                         (with wake-up date).
--   sp_opportunity_get    Re-issue of V008 adding row_version, ownerUserId,
--                         backupOwnerUserId, presalesOwnerUserId, solutionId,
--                         industryId, procurementTypeId for the edit form.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V012.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- spi_opp_weighted: recalculate weighted_value after value / stage / override change
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_opp_weighted $$
CREATE PROCEDURE spi_opp_weighted(IN p_opp_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Recalculate weighted_value = value × fx_rate × confidence%'
BEGIN
  UPDATE opportunity o
     SET o.weighted_value = ROUND(
           o.expected_value * o.fx_rate
           * COALESCE(
               o.confidence_override_pct,
               (SELECT default_confidence_pct FROM stage
                 WHERE entity = 'OPP' AND code = o.stage_code),
               0
             ) / 100.0,
           2)
   WHERE o.id = p_opp_id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_update
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_update $$
CREATE PROCEDURE sp_opportunity_update(
  IN p_actor_user_id          BIGINT UNSIGNED,
  IN p_request_id             VARCHAR(64),
  IN p_ip                     VARCHAR(45),
  IN p_opp_id                 BIGINT UNSIGNED,
  IN p_row_version            INT UNSIGNED,
  -- identification / classification
  IN p_title                  VARCHAR(250),
  IN p_solution_id            BIGINT UNSIGNED,
  IN p_problem_statement      TEXT,
  IN p_technical_requirement  TEXT,
  IN p_locations_count        INT UNSIGNED,
  -- value / dates
  IN p_expected_value         DECIMAL(16,2),
  IN p_currency               CHAR(3),
  IN p_fx_rate                DECIMAL(12,6),
  IN p_expected_close_date    DATE,
  -- commercial
  IN p_commercial_window_value  DECIMAL(16,2),
  IN p_commercial_window_accepted TINYINT(1),
  IN p_budget_known           VARCHAR(7),
  IN p_budget_min             DECIMAL(16,2),
  IN p_budget_max             DECIMAL(16,2),
  -- procurement
  IN p_procurement_type_id    BIGINT UNSIGNED,
  IN p_procurement_steps_known TINYINT(1),
  IN p_current_procurement_step_id BIGINT UNSIGNED,
  -- owners (opportunity.assign guard is on the route)
  IN p_owner_user_id          BIGINT UNSIGNED,
  IN p_backup_owner_user_id   BIGINT UNSIGNED,
  IN p_presales_owner_user_id BIGINT UNSIGNED,
  IN p_sponsor_user_id        BIGINT UNSIGNED,
  -- misc
  IN p_confidence_override_pct      DECIMAL(5,2),
  IN p_confidence_override_reason   VARCHAR(500),
  IN p_partner_tbm            TINYINT(1),
  IN p_no_competition         TINYINT(1),
  IN p_payment_terms          VARCHAR(500),
  IN p_bundle_tag             VARCHAR(60),
  -- products JSON array of {productId, isPrimary}
  IN p_product_ids            JSON
)
  SQL SECURITY DEFINER
  COMMENT 'Update opportunity core fields; resets validation when value changes (BR-OP-08)'
BEGIN
  DECLARE v_stage        VARCHAR(20);
  DECLARE v_version      INT UNSIGNED;
  DECLARE v_owner        BIGINT UNSIGNED;
  DECLARE v_old_value    DECIMAL(16,2);
  DECLARE v_old_close    DATE;
  DECLARE v_val_status   VARCHAR(10);
  DECLARE v_new_owner    BIGINT UNSIGNED;
  DECLARE v_all          TINYINT;
  DECLARE v_own          TINYINT;
  DECLARE v_assigned     TINYINT;
  DECLARE v_partner      TINYINT;
  DECLARE v_module       TINYINT;
  DECLARE v_reset_valid  TINYINT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT stage_code, row_version, owner_user_id, expected_value, expected_close_date, validation_status
    INTO v_stage, v_version, v_owner, v_old_value, v_old_close, v_val_status
    FROM opportunity WHERE id = p_opp_id;

  IF v_stage IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
  END IF;
  IF v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;
  IF v_stage IN ('WON', 'LOST') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Closed opportunities cannot be edited.', 'stageCode');
  END IF;

  -- scope check
  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You do not have permission to edit this opportunity.', 'id');
  END IF;

  -- basic validation
  IF p_title IS NULL OR TRIM(p_title) = '' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Enter a title.', 'title');
  END IF;
  IF p_expected_value IS NOT NULL AND p_expected_value < 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Value cannot be negative.', 'expectedValue');
  END IF;
  IF p_solution_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM solution WHERE id = p_solution_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Solution not found or inactive.', 'solutionId');
  END IF;
  IF p_procurement_type_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM procurement_type WHERE id = p_procurement_type_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Procurement type not found or inactive.', 'procurementTypeId');
  END IF;
  IF p_current_procurement_step_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM procurement_step WHERE id = p_current_procurement_step_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Procurement step not found or inactive.', 'currentProcurementStepId');
  END IF;
  IF p_budget_known IS NOT NULL AND p_budget_known NOT IN ('YES', 'NO', 'UNKNOWN') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Budget known must be YES, NO or UNKNOWN.', 'budgetKnown');
  END IF;
  IF p_confidence_override_pct IS NOT NULL
     AND (p_confidence_override_pct < 0 OR p_confidence_override_pct > 100) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Confidence override must be between 0 and 100.', 'confidenceOverridePct');
  END IF;

  -- owner resolution
  SET v_new_owner = COALESCE(p_owner_user_id, v_owner);
  IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = v_new_owner AND status = 'ACTIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'The owner must be an active user.', 'ownerUserId');
  END IF;
  -- only ALL-scope users may re-assign beyond their own team
  IF v_new_owner <> v_owner AND v_all = 0
     AND v_new_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_new_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You can only assign to yourself or your team.', 'ownerUserId');
  END IF;

  -- reset validation when value or close date changes (BR-OP-08)
  IF v_val_status = 'VALID'
     AND (COALESCE(p_expected_value, 0) <> COALESCE(v_old_value, 0)
          OR COALESCE(p_expected_close_date, '1970-01-01') <> COALESCE(v_old_close, '1970-01-01')) THEN
    SET v_reset_valid = 1;
  END IF;

  START TRANSACTION;

  UPDATE opportunity SET
    title                      = TRIM(p_title),
    solution_id                = p_solution_id,
    problem_statement          = NULLIF(TRIM(COALESCE(p_problem_statement, '')), ''),
    technical_requirement      = NULLIF(TRIM(COALESCE(p_technical_requirement, '')), ''),
    locations_count            = p_locations_count,
    expected_value             = COALESCE(p_expected_value, expected_value),
    currency                   = COALESCE(NULLIF(TRIM(COALESCE(p_currency,'')), ''), currency),
    fx_rate                    = COALESCE(p_fx_rate, fx_rate),
    expected_close_date        = p_expected_close_date,
    close_date_change_count    = close_date_change_count
                                 + IF(COALESCE(p_expected_close_date, '1970-01-01') <> COALESCE(expected_close_date, '1970-01-01'), 1, 0),
    commercial_window_value    = p_commercial_window_value,
    commercial_window_accepted = COALESCE(p_commercial_window_accepted, commercial_window_accepted),
    budget_known               = p_budget_known,
    budget_min                 = p_budget_min,
    budget_max                 = p_budget_max,
    procurement_type_id        = p_procurement_type_id,
    procurement_steps_known    = COALESCE(p_procurement_steps_known, procurement_steps_known),
    current_procurement_step_id = p_current_procurement_step_id,
    owner_user_id              = v_new_owner,
    backup_owner_user_id       = p_backup_owner_user_id,
    presales_owner_user_id     = p_presales_owner_user_id,
    sponsor_user_id            = p_sponsor_user_id,
    confidence_override_pct    = p_confidence_override_pct,
    confidence_override_reason = NULLIF(TRIM(COALESCE(p_confidence_override_reason, '')), ''),
    partner_tbm                = COALESCE(p_partner_tbm, partner_tbm),
    no_competition             = COALESCE(p_no_competition, no_competition),
    payment_terms              = NULLIF(TRIM(COALESCE(p_payment_terms, '')), ''),
    bundle_tag                 = NULLIF(TRIM(COALESCE(p_bundle_tag, '')), ''),
    validation_status          = IF(v_reset_valid = 1, 'PENDING', validation_status),
    validated_by               = IF(v_reset_valid = 1, NULL, validated_by),
    validated_at               = IF(v_reset_valid = 1, NULL, validated_at),
    updated_by                 = p_actor_user_id,
    updated_at                 = UTC_TIMESTAMP(3),
    row_version                = row_version + 1
  WHERE id = p_opp_id AND row_version = p_row_version;

  IF ROW_COUNT() = 0 THEN
    ROLLBACK;
    CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;

  -- refresh product list
  IF p_product_ids IS NOT NULL THEN
    DELETE FROM opportunity_product WHERE opportunity_id = p_opp_id;
    IF JSON_LENGTH(p_product_ids) > 0 THEN
      INSERT INTO opportunity_product (opportunity_id, product_id, is_primary, created_by)
      SELECT DISTINCT p_opp_id,
             jt.product_id,
             COALESCE(jt.is_primary, 0),
             p_actor_user_id
        FROM JSON_TABLE(p_product_ids, '$[*]'
               COLUMNS (
                 product_id BIGINT UNSIGNED PATH '$.productId',
                 is_primary TINYINT PATH '$.isPrimary'
               )) jt
       WHERE jt.product_id IS NOT NULL;
    END IF;
  END IF;

  CALL spi_opp_weighted(p_opp_id);

  CALL spi_audit_write('OPP', p_opp_id, 'UPDATE',
       JSON_OBJECT('title', JSON_OBJECT('to', TRIM(p_title)),
                   'ownerUserId', JSON_OBJECT('from', v_owner, 'to', v_new_owner)),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_opp_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_move_stage
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_move_stage $$
CREATE PROCEDURE sp_opportunity_move_stage(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(64),
  IN p_ip             VARCHAR(45),
  IN p_opp_id         BIGINT UNSIGNED,
  IN p_row_version    INT UNSIGNED,
  IN p_to_stage       VARCHAR(20),
  IN p_allow_backward TINYINT         -- 1 = stage_override permission granted by route
)
  SQL SECURITY DEFINER
  COMMENT 'Move an opportunity to a new open stage in the stepper (BR-OP-04)'
BEGIN
  DECLARE v_stage       VARCHAR(20);
  DECLARE v_version     INT UNSIGNED;
  DECLARE v_owner       BIGINT UNSIGNED;
  DECLARE v_cur_seq     SMALLINT UNSIGNED;
  DECLARE v_new_seq     SMALLINT UNSIGNED;
  DECLARE v_new_open    TINYINT;
  DECLARE v_all         TINYINT;
  DECLARE v_own         TINYINT;
  DECLARE v_assigned    TINYINT;
  DECLARE v_partner     TINYINT;
  DECLARE v_module      TINYINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT stage_code, row_version, owner_user_id
    INTO v_stage, v_version, v_owner
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
  IF v_stage = p_to_stage THEN
    CALL spi_raise('VALIDATION_FAILED', 'The opportunity is already in this stage.', 'toStage');
  END IF;
  IF p_to_stage IN ('WON', 'LOST', 'DORMANT') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Use the close action to mark as WON, LOST or DORMANT.', 'toStage');
  END IF;

  -- validate the target stage exists and is open
  SELECT sequence_no, is_open INTO v_new_seq, v_new_open
    FROM stage WHERE entity = 'OPP' AND code = p_to_stage AND is_active = 1;
  IF v_new_seq IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid target stage.', 'toStage');
  END IF;
  IF v_new_open = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Cannot move to a closed stage using this action.', 'toStage');
  END IF;

  SELECT sequence_no INTO v_cur_seq FROM stage WHERE entity = 'OPP' AND code = v_stage;

  IF v_new_seq <= v_cur_seq AND p_allow_backward = 0 THEN
    CALL spi_raise('FORBIDDEN', 'Backward stage moves require the stage override permission.', 'toStage');
  END IF;

  -- scope check
  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You do not have permission to move this opportunity.', 'id');
  END IF;

  START TRANSACTION;

  UPDATE opportunity SET
    previous_stage_code = v_stage,
    stage_code          = p_to_stage,
    stage_entered_at    = UTC_TIMESTAMP(3),
    updated_by          = p_actor_user_id,
    updated_at          = UTC_TIMESTAMP(3),
    row_version         = row_version + 1
  WHERE id = p_opp_id AND row_version = p_row_version;

  IF ROW_COUNT() = 0 THEN
    ROLLBACK;
    CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;

  INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
  VALUES ('OPP', p_opp_id, v_stage, p_to_stage, p_actor_user_id);

  CALL spi_opp_weighted(p_opp_id);

  CALL spi_audit_write('OPP', p_opp_id, 'STAGE_MOVE',
       JSON_OBJECT('stageCode', JSON_OBJECT('from', v_stage, 'to', p_to_stage)),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_opp_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_validate
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_validate $$
CREATE PROCEDURE sp_opportunity_validate(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(64),
  IN p_ip             VARCHAR(45),
  IN p_opp_id         BIGINT UNSIGNED,
  IN p_row_version    INT UNSIGNED,
  IN p_status         VARCHAR(10),    -- 'VALID' or 'NOT_VALID'
  IN p_remark         VARCHAR(1000)
)
  SQL SECURITY DEFINER
  COMMENT 'Set validation_status VALID or NOT_VALID (opportunity.validate permission)'
BEGIN
  DECLARE v_stage   VARCHAR(20);
  DECLARE v_version INT UNSIGNED;
  DECLARE v_all     TINYINT;
  DECLARE v_own     TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_status NOT IN ('VALID', 'NOT_VALID') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Status must be VALID or NOT_VALID.', 'status');
  END IF;

  SELECT stage_code, row_version INTO v_stage, v_version
    FROM opportunity WHERE id = p_opp_id;

  IF v_stage IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
  END IF;
  IF v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;
  IF v_stage IN ('WON', 'LOST') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Closed opportunities cannot be re-validated.', 'stageCode');
  END IF;

  -- scope: validate is an ALL-scope action (route guards opportunity.validate which is role-locked)
  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 THEN
    CALL spi_raise('FORBIDDEN', 'Only users with ALL data scope can validate opportunities.', 'id');
  END IF;

  START TRANSACTION;

  UPDATE opportunity SET
    validation_status = p_status,
    validated_by      = p_actor_user_id,
    validated_at      = UTC_TIMESTAMP(3),
    validation_remark = NULLIF(TRIM(COALESCE(p_remark, '')), ''),
    updated_by        = p_actor_user_id,
    updated_at        = UTC_TIMESTAMP(3),
    row_version       = row_version + 1
  WHERE id = p_opp_id AND row_version = p_row_version;

  IF ROW_COUNT() = 0 THEN
    ROLLBACK;
    CALL spi_raise('CONFLICT', 'This opportunity was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;

  CALL spi_audit_write('OPP', p_opp_id, 'VALIDATE',
       JSON_OBJECT('validationStatus', JSON_OBJECT('to', p_status)),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_opp_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_close
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_close $$
CREATE PROCEDURE sp_opportunity_close(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(64),
  IN p_ip             VARCHAR(45),
  IN p_opp_id         BIGINT UNSIGNED,
  IN p_row_version    INT UNSIGNED,
  IN p_outcome        VARCHAR(10),    -- WON / LOST / DORMANT
  -- WON fields
  IN p_final_value    DECIMAL(16,2),
  IN p_po_number      VARCHAR(60),
  IN p_po_value       DECIMAL(16,2),
  IN p_po_date        DATE,
  -- LOST fields
  IN p_loss_reason_ids JSON,          -- array of reason IDs
  IN p_competitor_id  BIGINT UNSIGNED,
  -- DORMANT fields
  IN p_dormant_reason_id BIGINT UNSIGNED,
  IN p_dormant_note   VARCHAR(1000),
  IN p_wake_up_date   DATE
)
  SQL SECURITY DEFINER
  COMMENT 'Close an opportunity as WON, LOST or DORMANT (BR-OP-05)'
BEGIN
  DECLARE v_stage   VARCHAR(20);
  DECLARE v_version INT UNSIGNED;
  DECLARE v_owner   BIGINT UNSIGNED;
  DECLARE v_source  VARCHAR(10);
  DECLARE v_all     TINYINT;
  DECLARE v_own     TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_outcome NOT IN ('WON', 'LOST', 'DORMANT') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Outcome must be WON, LOST or DORMANT.', 'outcome');
  END IF;

  SELECT stage_code, row_version, owner_user_id, source
    INTO v_stage, v_version, v_owner, v_source
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

-- ---------------------------------------------------------------------------
-- sp_opportunity_get: re-issue from V008 adding row_version + IDs for edit form
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_get $$
CREATE PROCEDURE sp_opportunity_get(
  IN p_user_id            BIGINT UNSIGNED,
  IN p_id                 BIGINT UNSIGNED,
  IN p_can_see_commercial TINYINT
)
  SQL SECURITY DEFINER
  COMMENT 'Deal workspace, read side (12.5) + row_version for optimistic lock'
BEGIN
  DECLARE v_all     TINYINT;
  DECLARE v_visible TINYINT DEFAULT 0;
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);
  SELECT COUNT(*) INTO v_visible FROM tmp_dash_opp WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
  END IF;

  -- RS 0: deal header (adds rowVersion + loose IDs on top of V008 for the edit form)
  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, o.account_id AS accountId,
         a.name AS accountName, a.is_strategic AS accountStrategic, o.source,
         i.name AS industryName, o.industry_id AS industryId,
         so.name AS solutionName, o.solution_id AS solutionId,
         (SELECT GROUP_CONCAT(pr.name ORDER BY opr.is_primary DESC, pr.name SEPARATOR ', ')
            FROM opportunity_product opr JOIN product pr ON pr.id = opr.product_id
           WHERE opr.opportunity_id = o.id) AS products,
         o.problem_statement AS problemStatement, o.technical_requirement AS technicalRequirement,
         o.locations_count AS locationsCount,
         o.stage_code AS stageCode, s.name AS stageName, s.is_open AS isOpen,
         o.stage_entered_at AS stageEnteredAt,
         DATEDIFF(v_today, DATE(o.stage_entered_at + INTERVAL 330 MINUTE)) AS daysInStage,
         s.sla_days AS stageSlaDays,
         COALESCE(o.confidence_override_pct, s.default_confidence_pct) AS confidencePct,
         o.confidence_override_pct AS confidenceOverridePct,
         o.confidence_override_reason AS confidenceOverrideReason,
         o.currency, o.fx_rate AS fxRate,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(o.expected_value AS DECIMAL(18,2)) AS expectedValue,
         CAST(o.weighted_value AS DECIMAL(18,2)) AS weighted,
         o.expected_close_date AS expectedCloseDate, o.close_date_change_count AS closeDateChangeCount,
         CAST(o.commercial_window_value AS DECIMAL(18,2)) AS commercialWindowValue,
         o.commercial_window_accepted AS commercialWindowAccepted, o.budget_known AS budgetKnown,
         CAST(o.budget_min AS DECIMAL(18,2)) AS budgetMin, CAST(o.budget_max AS DECIMAL(18,2)) AS budgetMax,
         o.procurement_type_id AS procurementTypeId, pt.name AS procurementTypeName,
         o.current_procurement_step_id AS currentProcurementStepId, pst.name AS procurementStepName,
         o.validation_status AS validationStatus, vb.full_name AS validatedByName,
         o.validated_at AS validatedAt, o.validation_remark AS validationRemark,
         o.owner_user_id AS ownerUserId, u.full_name AS ownerName,
         o.backup_owner_user_id AS backupOwnerUserId, bu.full_name AS backupOwnerName,
         o.presales_owner_user_id AS presalesOwnerUserId, ps.full_name AS presalesName,
         o.sponsor_user_id AS sponsorUserId, sp.full_name AS sponsorName,
         o.partner_tbm AS partnerTbm, o.no_competition AS noCompetition,
         CAST(o.final_value AS DECIMAL(18,2)) AS finalValue, o.payment_terms AS paymentTerms,
         o.po_number AS poNumber, o.po_date AS poDate, CAST(o.po_value AS DECIMAL(18,2)) AS poValue,
         o.closed_at AS closedAt, dr.name AS dormantReason, o.dormant_note AS dormantNote,
         o.wake_up_date AS wakeUpDate, o.bundle_tag AS bundleTag, o.health,
         o.last_activity_at AS lastActivityAt, o.last_status_at AS lastStatusAt,
         o.lead_id AS leadId, l.lead_no AS leadNo,
         (SELECT so2.id FROM sales_order so2 WHERE so2.opportunity_id = o.id LIMIT 1) AS orderId,
         o.created_at AS createdAt, cb.full_name AS createdByName,
         o.row_version AS rowVersion
    FROM opportunity o
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
    LEFT JOIN industry i ON i.id = COALESCE(o.industry_id, a.industry_id)
    LEFT JOIN solution so ON so.id = o.solution_id
    LEFT JOIN procurement_type pt ON pt.id = o.procurement_type_id
    LEFT JOIN procurement_step pst ON pst.id = o.current_procurement_step_id
    LEFT JOIN `user` vb ON vb.id = o.validated_by
    LEFT JOIN `user` bu ON bu.id = o.backup_owner_user_id
    LEFT JOIN `user` ps ON ps.id = o.presales_owner_user_id
    LEFT JOIN `user` sp ON sp.id = o.sponsor_user_id
    LEFT JOIN `user` cb ON cb.id = o.created_by
    LEFT JOIN reason dr ON dr.id = o.dormant_reason_id
    LEFT JOIN sales_lead l ON l.id = o.lead_id
   WHERE o.id = p_id;

  -- RS 1: stepper
  SELECT code, name, sequence_no AS sequenceNo, default_confidence_pct AS confidencePct,
         is_open AS isOpen, is_won AS isWon, is_lost AS isLost
    FROM stage WHERE entity = 'OPP' AND is_active = 1 ORDER BY sequence_no;

  -- RS 2: products
  SELECT pr.id, pr.name, opr.is_primary AS isPrimary
    FROM opportunity_product opr JOIN product pr ON pr.id = opr.product_id
   WHERE opr.opportunity_id = p_id ORDER BY opr.is_primary DESC, pr.name;

  -- RS 3: DMU contacts (opportunity_dmu links to contact; d.name does not exist — use c.name)
  SELECT d.id, c.id AS contactId, c.name, c.designation, c.department, c.email, c.phone,
         d.dmu_role AS dmuRole, d.influence_level AS influenceLevel, d.stand, d.notes
    FROM opportunity_dmu d JOIN contact c ON c.id = d.contact_id
   WHERE d.opportunity_id = p_id
   ORDER BY FIELD(d.dmu_role, 'TECH_BUYER', 'COMM_BUYER', 'SPONSOR', 'INFLUENCER_INT', 'INFLUENCER_EXT'), d.id;

  -- RS 4: partners
  SELECT op.id, p.id AS partnerId, p.partner_no AS partnerNo,
         COALESCE(p.short_name, p.legal_name) AS partnerName, p.tier,
         op.partner_role AS partnerRole, op.engagement_level AS engagementLevel,
         op.is_primary AS isPrimary, op.commercial_confirmed AS commercialConfirmed, op.notes
    FROM opportunity_partner op JOIN partner p ON p.id = op.partner_id
   WHERE op.opportunity_id = p_id
   ORDER BY op.is_primary DESC, op.id;

  -- RS 5: competitors
  SELECT oc.id, c.name, CAST(oc.their_price AS DECIMAL(18,2)) AS theirPrice,
         oc.their_strength AS theirStrength, oc.our_differentiator AS ourDifferentiator
    FROM opportunity_competitor oc JOIN competitor c ON c.id = oc.competitor_id
   WHERE oc.opportunity_id = p_id ORDER BY c.name;

  -- RS 6: POC
  SELECT pc.id, pc.external_poc_ref AS externalPocRef, pc.status, pc.start_date AS startDate,
         pc.end_date AS endDate, pc.success_criteria AS successCriteria, pc.exit_criteria AS exitCriteria,
         c.name AS customerLeadName, u2.full_name AS cnergeeLeadName, pc.result,
         pc.customer_validated AS customerValidated, pc.readout_date AS readoutDate,
         pc.skipped, pc.skip_reason AS skipReason, pc.notes
    FROM opportunity_poc pc
    LEFT JOIN contact c ON c.id = pc.customer_lead_contact_id
    LEFT JOIN `user` u2 ON u2.id = pc.cnergee_lead_user_id
   WHERE pc.opportunity_id = p_id;

  -- RS 7: offers
  SELECT f.id, f.version_no AS versionNo, f.offer_no AS offerNo,
         CAST(f.offer_value AS DECIMAL(18,2)) AS offerValue, CAST(f.list_value AS DECIMAL(18,2)) AS listValue,
         f.discount_pct AS discountPct, f.value_adds AS valueAdds, f.payment_terms AS paymentTerms,
         f.valid_till AS validTill, f.status, f.approval_required AS approvalRequired,
         sb.full_name AS submittedByName, f.submitted_at AS submittedAt,
         ab.full_name AS approvedByName, f.approved_at AS approvedAt, f.approval_remark AS approvalRemark,
         f.sent_at AS sentAt, f.sent_to AS sentTo, f.customer_response AS customerResponse,
         f.customer_responded_at AS customerRespondedAt, f.created_at AS createdAt
    FROM offer f
    LEFT JOIN `user` sb ON sb.id = f.submitted_by
    LEFT JOIN `user` ab ON ab.id = f.approved_by
   WHERE f.opportunity_id = p_id
   ORDER BY f.version_no DESC;

  -- RS 8: partner commercial (only for holders of partner_commercial.view)
  SELECT pc.id, COALESCE(p.short_name, p.legal_name) AS partnerName, pc.partner_role AS partnerRole,
         pc.version_no AS versionNo, pc.deal_size_basis AS dealSizeBasis,
         CAST(pc.price_to_partner AS DECIMAL(18,2)) AS priceToPartner,
         pc.partner_margin_pct AS partnerMarginPct, pc.payment_terms AS paymentTerms,
         pc.pay_partner_after_customer AS payPartnerAfterCustomer, pc.valid_till AS validTill,
         pc.remarks, pc.created_at AS createdAt, u3.full_name AS createdByName
    FROM partner_commercial pc
    JOIN partner p ON p.id = pc.partner_id
    LEFT JOIN `user` u3 ON u3.id = pc.created_by
   WHERE pc.opportunity_id = p_id AND p_can_see_commercial = 1
   ORDER BY p.short_name, pc.version_no DESC;

  -- RS 9: activities
  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject,
         ac.notes, ac.outcome, ac.people_met AS peopleMet, ac.next_action AS nextAction,
         ac.next_action_on AS nextActionOn, u4.full_name AS byName
    FROM activity ac JOIN `user` u4 ON u4.id = ac.by_user_id
   WHERE ac.is_active = 1 AND (ac.opportunity_id = p_id OR (ac.entity_type = 'OPP' AND ac.entity_id = p_id))
   ORDER BY ac.activity_at DESC, ac.id DESC
   LIMIT 100;

  -- RS 10: weekly status
  SELECT ws.id, ws.week_start AS weekStart, ws.status, ws.this_week AS thisWeek,
         ws.next_step AS nextStep, ws.expected_close_date AS expectedCloseDate,
         ws.close_change_reason AS closeChangeReason,
         CAST(ws.expected_value AS DECIMAL(18,2)) AS expectedValue, s.name AS stageName,
         u5.full_name AS submittedByName, ws.submitted_at AS submittedAt
    FROM weekly_status ws
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = ws.stage_code
    LEFT JOIN `user` u5 ON u5.id = ws.submitted_by
   WHERE ws.opportunity_id = p_id
   ORDER BY ws.week_start DESC
   LIMIT 26;

  -- RS 11: monthly commits
  SELECT mc.id, mc.commit_month AS commitMonth, mc.commit_type AS commitType,
         CAST(mc.commit_value AS DECIMAL(18,2)) AS commitValue, mc.achieved
    FROM monthly_commit mc WHERE mc.opportunity_id = p_id ORDER BY mc.commit_month DESC;

  -- RS 12: stage history
  SELECT sh.id, fs.name AS fromStage, ts.name AS toStage, sh.to_stage AS toStageCode,
         u6.full_name AS changedByName, sh.changed_at AS changedAt, sh.reason,
         sh.days_in_previous AS daysInPrevious, sh.was_override AS wasOverride
    FROM stage_history sh
    LEFT JOIN stage fs ON fs.entity = 'OPP' AND fs.code = sh.from_stage
    LEFT JOIN stage ts ON ts.entity = 'OPP' AND ts.code = sh.to_stage
    LEFT JOIN `user` u6 ON u6.id = sh.changed_by
   WHERE sh.entity_type = 'OPP' AND sh.entity_id = p_id
   ORDER BY sh.changed_at DESC, sh.id DESC;

  -- RS 13: win/loss
  SELECT wl.outcome, lr.name AS lossReason, c.name AS competitorName, wl.detail, wl.lesson,
         wl.competition_replaced AS competitionReplaced, wl.remarks,
         (SELECT GROUP_CONCAT(r.name ORDER BY r.sort_order SEPARATOR ', ')
            FROM win_loss_reason wr JOIN reason r ON r.id = wr.reason_id
           WHERE wr.opportunity_id = wl.opportunity_id) AS winReasons,
         u7.full_name AS recordedByName, wl.recorded_at AS recordedAt
    FROM win_loss wl
    LEFT JOIN reason lr ON lr.id = wl.loss_reason_id
    LEFT JOIN competitor c ON c.id = wl.competitor_id
    LEFT JOIN `user` u7 ON u7.id = wl.recorded_by
   WHERE wl.opportunity_id = p_id;

  -- RS 14: tasks
  SELECT tk.id, tk.task_type AS taskType, tk.title, tk.due_at AS dueAt, tk.status,
         u8.full_name AS ownerName
    FROM task tk JOIN `user` u8 ON u8.id = tk.owner_user_id
   WHERE tk.entity_type = 'OPP' AND tk.entity_id = p_id
   ORDER BY tk.status = 'OPEN' DESC, tk.due_at;
END $$

DELIMITER ;
