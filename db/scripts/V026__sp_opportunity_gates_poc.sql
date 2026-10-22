-- =============================================================================
-- V026  Sales CRM - stage gates, POC details, partial deal edit         (2026-10-14)
--
--   sp_opportunity_edit_values   The current editable values of a deal, so the API can
--                                merge a partial PATCH (a full replace lost data, D-42).
--   spi_opp_gate_missing         Missing items to leave the deal's stage (16.3) into
--                                tmp_gate_missing; BR-OP-02/03/04.
--   sp_opportunity_gate          GET /opportunities/{id}/gate: next stage + missing items.
--   sp_opportunity_move_stage    Re-issue of V013: one stage forward at a time (BR-OP-01)
--                                and only with the gate met, unless a holder of
--                                opportunity.stage_override overrides with a reason;
--                                backward moves also need that permission and a reason.
--   sp_opportunity_poc_save      PUT /opportunities/{id}/poc (12.5.4), one record per deal.
--   sp_opportunity_poc_get       GET /opportunities/{id}/poc: the record with ids, for the edit form.
--   sp_opportunity_close         Re-issue of V019: WON only from CONTRACT_SIGNED (BR-OP-01, OD-34).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V025.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_edit_values: keys match the PATCH body (camelCase)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_edit_values $$
CREATE PROCEDURE sp_opportunity_edit_values(IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  SELECT o.title, o.solution_id AS solutionId, o.problem_statement AS problemStatement,
         o.technical_requirement AS technicalRequirement, o.locations_count AS locationsCount,
         o.expected_value AS expectedValue, o.currency, o.fx_rate AS fxRate,
         o.expected_close_date AS expectedCloseDate,
         o.commercial_window_value AS commercialWindowValue,
         o.commercial_window_accepted AS commercialWindowAccepted, o.budget_known AS budgetKnown,
         o.budget_min AS budgetMin, o.budget_max AS budgetMax, o.procurement_type_id AS procurementTypeId,
         o.procurement_steps_known AS procurementStepsKnown,
         o.current_procurement_step_id AS currentProcurementStepId, o.owner_user_id AS ownerUserId,
         o.backup_owner_user_id AS backupOwnerUserId, o.presales_owner_user_id AS presalesOwnerUserId,
         o.sponsor_user_id AS sponsorUserId, o.confidence_override_pct AS confidenceOverridePct,
         o.confidence_override_reason AS confidenceOverrideReason, o.partner_tbm AS partnerTbm,
         o.no_competition AS noCompetition, o.payment_terms AS paymentTerms, o.bundle_tag AS bundleTag
    FROM opportunity o WHERE o.id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- spi_opp_gate_missing: what is missing to leave p_from_stage (16.3). The caller
-- reads and drops tmp_gate_missing.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_opp_gate_missing $$
CREATE PROCEDURE spi_opp_gate_missing(IN p_opp_id BIGINT UNSIGNED, IN p_from_stage VARCHAR(20))
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_valid     VARCHAR(10);
  DECLARE v_problem   TEXT;
  DECLARE v_solution  BIGINT UNSIGNED;
  DECLARE v_cw_value  DECIMAL(16,2);
  DECLARE v_cw_ok     TINYINT;
  DECLARE v_proc      BIGINT UNSIGNED;
  DECLARE v_presales  BIGINT UNSIGNED;
  DECLARE v_tech      TEXT;
  DECLARE v_no_comp   TINYINT;
  DECLARE v_final     DECIMAL(16,2);
  DECLARE v_terms     VARCHAR(500);
  DECLARE v_tbm       TINYINT;

  DROP TEMPORARY TABLE IF EXISTS tmp_gate_missing;
  CREATE TEMPORARY TABLE tmp_gate_missing (seq INT NOT NULL AUTO_INCREMENT PRIMARY KEY, item VARCHAR(200) NOT NULL);

  SELECT validation_status, problem_statement, solution_id, commercial_window_value, commercial_window_accepted,
         procurement_type_id, presales_owner_user_id, technical_requirement, no_competition, final_value,
         payment_terms, partner_tbm
    INTO v_valid, v_problem, v_solution, v_cw_value, v_cw_ok, v_proc, v_presales, v_tech, v_no_comp, v_final,
         v_terms, v_tbm
    FROM opportunity WHERE id = p_opp_id;

  CASE p_from_stage
    WHEN 'QUALIFIED' THEN
      IF IFNULL(v_valid, '') <> 'VALID' THEN INSERT INTO tmp_gate_missing (item) VALUES ('The deal is validated (VALID)'); END IF;
      IF NULLIF(TRIM(IFNULL(v_problem, '')), '') IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Problem statement'); END IF;
      IF v_solution IS NULL OR NOT EXISTS (SELECT 1 FROM opportunity_product WHERE opportunity_id = p_opp_id) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Product and solution');
      END IF;
      IF v_cw_value IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Commercial window value'); END IF;
      IF NOT EXISTS (SELECT 1 FROM opportunity_dmu WHERE opportunity_id = p_opp_id AND dmu_role = 'TECH_BUYER') THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('DMU: a technical buyer');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM opportunity_dmu WHERE opportunity_id = p_opp_id AND dmu_role = 'COMM_BUYER') THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('DMU: a commercial buyer');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM opportunity_dmu WHERE opportunity_id = p_opp_id
                      AND dmu_role IN ('INFLUENCER_INT', 'INFLUENCER_EXT')) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('DMU: an influencer');
      END IF;
      IF v_proc IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Procurement process'); END IF;
    WHEN 'TECH_ENGAGEMENT' THEN
      IF v_presales IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Pre-sales owner'); END IF;
      IF NULLIF(TRIM(IFNULL(v_tech, '')), '') IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Technical requirement'); END IF;
      IF v_no_comp = 0 AND NOT EXISTS (SELECT 1 FROM opportunity_competitor WHERE opportunity_id = p_opp_id) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Competition: a competitor, or "no competition"');
      END IF;
      IF v_cw_ok = 0 THEN INSERT INTO tmp_gate_missing (item) VALUES ('Commercial window accepted by the customer'); END IF;
    WHEN 'POC' THEN
      IF NOT EXISTS (SELECT 1 FROM opportunity_poc
                      WHERE opportunity_id = p_opp_id
                        AND ((skipped = 1 AND NULLIF(TRIM(IFNULL(skip_reason, '')), '') IS NOT NULL)
                             OR (skipped = 0 AND NULLIF(TRIM(IFNULL(success_criteria, '')), '') IS NOT NULL
                                 AND NULLIF(TRIM(IFNULL(exit_criteria, '')), '') IS NOT NULL
                                 AND customer_lead_contact_id IS NOT NULL))) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('POC: success and exit criteria and the customer lead, or POC skipped with a reason');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM offer WHERE opportunity_id = p_opp_id AND sent_at IS NOT NULL) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('An offer sent to the customer');
      END IF;
    WHEN 'PROPOSAL' THEN
      IF NOT EXISTS (SELECT 1 FROM offer WHERE opportunity_id = p_opp_id AND customer_response IS NOT NULL)
         AND NOT EXISTS (SELECT 1 FROM activity WHERE opportunity_id = p_opp_id AND activity_type = 'NEGOTIATION' AND is_active = 1) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('The customer response on an offer, or a negotiation activity');
      END IF;
    WHEN 'NEGOTIATION' THEN
      IF NOT EXISTS (SELECT 1 FROM activity WHERE opportunity_id = p_opp_id AND activity_type = 'NEGOTIATION'
                      AND is_active = 1 AND NULLIF(TRIM(IFNULL(notes, '')), '') IS NOT NULL) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Negotiation notes (a negotiation activity with notes)');
      END IF;
      -- an accepted offer carries the agreed value and terms (D-42)
      IF v_final IS NULL AND NOT EXISTS (SELECT 1 FROM offer WHERE opportunity_id = p_opp_id AND status = 'ACCEPTED') THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Final value (or an accepted offer)');
      END IF;
      IF NULLIF(TRIM(IFNULL(v_terms, '')), '') IS NULL AND NOT EXISTS (
           SELECT 1 FROM offer WHERE opportunity_id = p_opp_id AND status = 'ACCEPTED'
              AND NULLIF(TRIM(IFNULL(payment_terms, '')), '') IS NOT NULL) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Payment terms');
      END IF;
      IF EXISTS (SELECT 1 FROM opportunity_partner WHERE opportunity_id = p_opp_id AND commercial_confirmed = 0) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Partner commercial confirmed for every partner on the deal');
      END IF;
      IF v_tbm = 1 THEN INSERT INTO tmp_gate_missing (item) VALUES ('Partner "to be mapped" cleared'); END IF;
    WHEN 'COMMERCIAL_CLOSED' THEN
      IF NOT EXISTS (SELECT 1 FROM document d JOIN document_type dt ON dt.id = d.document_type_id
                      WHERE d.opportunity_id = p_opp_id AND d.is_active = 1 AND dt.code = 'CONTRACT') THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('A contract or LoI document');
      END IF;
    ELSE
      BEGIN END;
  END CASE;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_gate: the next stage and what is missing to move there
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_gate $$
CREATE PROCEDURE sp_opportunity_gate(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Gate check for the next stage (16.3)'
BEGIN
  DECLARE v_stage   VARCHAR(20);
  DECLARE v_seq     INT;
  DECLARE v_next    VARCHAR(20);
  DECLARE v_visible INT DEFAULT 0;

  CALL spi_visible_accounts(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_dash_opp WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
  END IF;

  SELECT o.stage_code, s.sequence_no INTO v_stage, v_seq
    FROM opportunity o JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE o.id = p_id AND s.is_open = 1;
  SELECT code INTO v_next FROM stage
   WHERE entity = 'OPP' AND is_open = 1 AND is_active = 1 AND sequence_no = v_seq + 1;

  CALL spi_opp_gate_missing(p_id, IFNULL(v_stage, ''));
  IF v_stage IS NULL OR v_next IS NULL THEN DELETE FROM tmp_gate_missing; END IF;
  SELECT v_stage AS stageCode, v_next AS nextStage,
         (v_next IS NOT NULL AND NOT EXISTS (SELECT 1 FROM tmp_gate_missing)) AS allowed;
  SELECT item FROM tmp_gate_missing ORDER BY seq;
  DROP TEMPORARY TABLE IF EXISTS tmp_gate_missing;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_move_stage (re-issue of V013)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_move_stage $$
CREATE PROCEDURE sp_opportunity_move_stage(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(64),
  IN p_ip             VARCHAR(45),
  IN p_opp_id         BIGINT UNSIGNED,
  IN p_row_version    INT UNSIGNED,
  IN p_to_stage       VARCHAR(20),
  IN p_can_override   TINYINT,        -- 1 = the actor holds opportunity.stage_override
  IN p_override       TINYINT,        -- 1 = the actor asks to override the gate / order
  IN p_reason         VARCHAR(1000)
)
  SQL SECURITY DEFINER
  COMMENT 'Move an open deal one stage forward with its gate met (BR-OP-01/02/03/04)'
BEGIN
  DECLARE v_stage    VARCHAR(20);
  DECLARE v_version  INT UNSIGNED;
  DECLARE v_owner    BIGINT UNSIGNED;
  DECLARE v_cur_seq  INT;
  DECLARE v_cur_open TINYINT;
  DECLARE v_new_seq  INT;
  DECLARE v_new_open TINYINT;
  DECLARE v_missing  INT DEFAULT 0;
  DECLARE v_forced   TINYINT DEFAULT 0;
  DECLARE v_reason   VARCHAR(1000) DEFAULT NULLIF(TRIM(IFNULL(p_reason, '')), '');
  DECLARE v_all      TINYINT;
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT stage_code, row_version, owner_user_id INTO v_stage, v_version, v_owner
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

  SELECT sequence_no, is_open INTO v_new_seq, v_new_open
    FROM stage WHERE entity = 'OPP' AND code = p_to_stage AND is_active = 1;
  IF v_new_seq IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid target stage.', 'toStage');
  END IF;
  IF v_new_open = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Cannot move to a closed stage using this action.', 'toStage');
  END IF;
  SELECT sequence_no, is_open INTO v_cur_seq, v_cur_open FROM stage WHERE entity = 'OPP' AND code = v_stage;

  -- scope check
  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You do not have permission to move this opportunity.', 'id');
  END IF;

  IF p_override = 1 AND p_can_override = 0 THEN
    CALL spi_raise('FORBIDDEN', 'Overriding a stage gate needs the stage override permission.', 'override');
  END IF;

  IF v_cur_open = 1 AND v_new_seq = v_cur_seq + 1 THEN
    -- forward one step: the gate of the current stage (16.3)
    CALL spi_opp_gate_missing(p_opp_id, v_stage);
    SELECT COUNT(*) INTO v_missing FROM tmp_gate_missing;
    DROP TEMPORARY TABLE IF EXISTS tmp_gate_missing;
    IF v_missing > 0 THEN
      IF p_override = 0 THEN
        CALL spi_raise('GATE_NOT_MET', CONCAT(v_missing, ' gate item(s) missing. Complete them or override with a reason.'), 'toStage');
      END IF;
      SET v_forced = 1;
    END IF;
  ELSE
    -- backward, skipping stages or reopening a dormant deal (BR-OP-01)
    IF p_can_override = 0 THEN
      CALL spi_raise('FORBIDDEN', 'Moves other than one stage forward need the stage override permission.', 'toStage');
    END IF;
    SET v_forced = 1;
  END IF;
  IF v_forced = 1 AND v_reason IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Give a reason for this override.', 'reason');
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

  INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by, reason, was_override)
  VALUES ('OPP', p_opp_id, v_stage, p_to_stage, p_actor_user_id, v_reason, v_forced);

  CALL spi_opp_weighted(p_opp_id);

  CALL spi_audit_write('OPP', p_opp_id, IF(v_forced = 1, 'STAGE_OVERRIDE', 'STAGE_MOVE'),
       JSON_OBJECT('stageCode', JSON_OBJECT('from', v_stage, 'to', p_to_stage), 'reason', v_reason),
       NULL, p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT p_opp_id AS id, v_forced AS overridden;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_poc_save: create or replace the deal's POC record (12.5.4)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_poc_save $$
CREATE PROCEDURE sp_opportunity_poc_save(
  IN p_actor_user_id     BIGINT UNSIGNED,
  IN p_request_id        VARCHAR(36),
  IN p_ip                VARCHAR(45),
  IN p_opp_id            BIGINT UNSIGNED,
  IN p_skipped           TINYINT(1),
  IN p_skip_reason       VARCHAR(1000),
  IN p_external_ref      VARCHAR(60),
  IN p_status            VARCHAR(12),
  IN p_start_date        DATE,
  IN p_end_date          DATE,
  IN p_success_criteria  TEXT,
  IN p_exit_criteria     TEXT,
  IN p_customer_lead_id  BIGINT UNSIGNED,
  IN p_cnergee_lead_id   BIGINT UNSIGNED,
  IN p_result            VARCHAR(12),
  IN p_customer_valid    TINYINT(1),
  IN p_readout_date      DATE,
  IN p_notes             TEXT
)
  SQL SECURITY DEFINER
  COMMENT 'POC details of a deal (12.5.4, BR-OP-04)'
BEGIN
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_id      BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_opp_edit_check(p_actor_user_id, p_opp_id, 1, v_account);

  IF p_skipped = 1 AND NULLIF(TRIM(IFNULL(p_skip_reason, '')), '') IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Give the reason the POC is skipped.', 'skipReason');
  END IF;
  IF p_status NOT IN ('REQUESTED','IN_PROGRESS','COMPLETED','CANCELLED') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid POC status.', 'status');
  END IF;
  IF p_result IS NOT NULL AND p_result NOT IN ('SUCCESS','FAIL','INCONCLUSIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid POC result.', 'result');
  END IF;
  IF p_result IS NOT NULL AND p_status <> 'COMPLETED' THEN
    CALL spi_raise('VALIDATION_FAILED', 'A result needs the POC status COMPLETED.', 'result');
  END IF;
  IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_end_date < p_start_date THEN
    CALL spi_raise('VALIDATION_FAILED', 'The end date cannot be before the start date.', 'endDate');
  END IF;
  IF p_customer_lead_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM contact WHERE id = p_customer_lead_id AND account_id = v_account AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'The customer lead must be a contact of the deal''s account.', 'customerLeadContactId');
  END IF;
  IF p_cnergee_lead_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_cnergee_lead_id AND status = 'ACTIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'The Cnergee lead must be an active user.', 'cnergeeLeadUserId');
  END IF;

  START TRANSACTION;
  SELECT id INTO v_id FROM opportunity_poc WHERE opportunity_id = p_opp_id FOR UPDATE;
  IF v_id IS NULL THEN
    INSERT INTO opportunity_poc (opportunity_id, created_by) VALUES (p_opp_id, p_actor_user_id);
    SET v_id = LAST_INSERT_ID();
  END IF;
  UPDATE opportunity_poc SET
    skipped                  = p_skipped,
    skip_reason              = IF(p_skipped = 1, TRIM(p_skip_reason), NULL),
    external_poc_ref         = p_external_ref,
    status                   = p_status,
    start_date               = p_start_date,
    end_date                 = p_end_date,
    success_criteria         = p_success_criteria,
    exit_criteria            = p_exit_criteria,
    customer_lead_contact_id = p_customer_lead_id,
    cnergee_lead_user_id     = p_cnergee_lead_id,
    result                   = p_result,
    customer_validated       = p_customer_valid,
    readout_date             = p_readout_date,
    notes                    = p_notes,
    updated_at               = UTC_TIMESTAMP(3),
    updated_by               = p_actor_user_id
  WHERE id = v_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opp_id, 'POC_SAVE',
          JSON_OBJECT('status', p_status, 'skipped', p_skipped = 1, 'result', p_result),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_poc_get: the POC record with ids, for the edit form (GET /poc)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_poc_get $$
CREATE PROCEDURE sp_opportunity_poc_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible INT DEFAULT 0;
  CALL spi_visible_accounts(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_dash_opp WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
  END IF;

  SELECT pc.skipped, pc.skip_reason AS skipReason, pc.external_poc_ref AS externalPocRef, pc.status,
         pc.start_date AS startDate, pc.end_date AS endDate, pc.success_criteria AS successCriteria,
         pc.exit_criteria AS exitCriteria, pc.customer_lead_contact_id AS customerLeadContactId,
         pc.cnergee_lead_user_id AS cnergeeLeadUserId, u.full_name AS cnergeeLeadName, pc.result,
         pc.customer_validated AS customerValidated, pc.readout_date AS readoutDate, pc.notes
    FROM opportunity_poc pc
    LEFT JOIN `user` u ON u.id = pc.cnergee_lead_user_id
   WHERE pc.opportunity_id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_close: V019 + WON only from CONTRACT_SIGNED
-- ---------------------------------------------------------------------------
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

  -- BR-OP-01 / OD-34: WON only after the stage gates, from CONTRACT_SIGNED (V026)
  IF p_outcome = 'WON' AND v_stage <> 'CONTRACT_SIGNED' THEN
    CALL spi_raise('GATE_NOT_MET', 'A deal is won from the Contract signed stage. Move it there first.', 'outcome');
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

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V026', 'Stage gates and overrides, POC save, deal edit values for partial PATCH, WON only from contract signed', UTC_TIMESTAMP());
