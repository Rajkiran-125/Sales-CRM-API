-- =============================================================================
-- V012  Sales CRM - leads, write side 2: update, disqualify, convert  (2026-10-12)
--
--   sp_lead_update     Edit the lead while in an open stage (NEW/CONTACTED/QUALIFYING).
--                      Moves stage from NEW/CONTACTED → QUALIFYING when a qualification
--                      field is supplied. Recalculates qualification_pct.
--   sp_lead_disqualify Set stage DISQUALIFIED with a reason (BR-LD-07).
--   sp_lead_convert    Check 6/6 facts, create the opportunity in QUALIFYING, mark lead
--                      CONVERTED (BR-LD-06, BR-LD-08).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V011.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- internal helper: recalculate qualification_pct for a lead
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_lead_qualification_pct $$
CREATE PROCEDURE spi_lead_qualification_pct(IN p_lead_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Recalculate qualification_pct for a lead (6 facts × 16.67)'
BEGIN
  DECLARE v_done  TINYINT DEFAULT 0;
  DECLARE v_pct   DECIMAL(5,2) DEFAULT 0;

  SELECT (
    (NULLIF(TRIM(COALESCE(l.problem_statement, '')), '') IS NOT NULL)
    + (l.product_id IS NOT NULL AND l.solution_id IS NOT NULL)
    + (l.commercial_window_value IS NOT NULL
       AND l.budget_known IS NOT NULL
       AND (l.budget_known <> 'YES'
            OR l.budget_min IS NOT NULL
            OR l.budget_max IS NOT NULL))
    + (EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_lead_id AND d.dmu_role = 'TECH_BUYER')
       AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_lead_id AND d.dmu_role = 'COMM_BUYER')
       AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_lead_id
                   AND d.dmu_role IN ('INFLUENCER_INT', 'INFLUENCER_EXT')))
    + (l.procurement_type_id IS NOT NULL AND l.procurement_steps_known = 1)
    + (l.expected_close_date IS NOT NULL)
  ) INTO v_done FROM sales_lead l WHERE l.id = p_lead_id;

  SET v_pct = ROUND(COALESCE(v_done, 0) * 100.0 / 6, 2);
  UPDATE sales_lead SET qualification_pct = v_pct WHERE id = p_lead_id;
END $$

-- ---------------------------------------------------------------------------
-- sp_lead_update
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_lead_update $$
CREATE PROCEDURE sp_lead_update(
  IN p_actor_user_id          BIGINT UNSIGNED,
  IN p_request_id             VARCHAR(64),
  IN p_ip                     VARCHAR(45),
  IN p_lead_id                BIGINT UNSIGNED,
  IN p_row_version            INT UNSIGNED,
  -- basic fields
  IN p_source                 VARCHAR(10),
  IN p_partner_id             BIGINT UNSIGNED,
  IN p_partner_contact        VARCHAR(200),
  IN p_account_id             BIGINT UNSIGNED,
  IN p_account_name_text      VARCHAR(200),
  IN p_industry_id            BIGINT UNSIGNED,
  IN p_contact_name           VARCHAR(150),
  IN p_contact_designation    VARCHAR(100),
  IN p_contact_email          VARCHAR(150),
  IN p_contact_phone          VARCHAR(20),
  IN p_city                   VARCHAR(100),
  IN p_locations_count        INT UNSIGNED,
  IN p_need_text              TEXT,
  IN p_rough_value            DECIMAL(16,2),
  IN p_rough_timing           VARCHAR(40),
  IN p_owner_user_id          BIGINT UNSIGNED,
  IN p_backup_owner_user_id   BIGINT UNSIGNED,
  IN p_next_action            VARCHAR(500),
  IN p_next_action_due_on     DATE,
  IN p_product_ids            JSON,
  -- qualification facts
  IN p_problem_statement      TEXT,
  IN p_product_id             BIGINT UNSIGNED,
  IN p_solution_id            BIGINT UNSIGNED,
  IN p_commercial_window_value DECIMAL(16,2),
  IN p_budget_known           VARCHAR(7),
  IN p_budget_min             DECIMAL(16,2),
  IN p_budget_max             DECIMAL(16,2),
  IN p_procurement_type_id    BIGINT UNSIGNED,
  IN p_procurement_steps_known TINYINT(1),
  IN p_expected_close_date    DATE
)
  SQL SECURITY DEFINER
  COMMENT 'Edit a lead while in an open stage; recalculates qualification_pct (12.4)'
BEGIN
  DECLARE v_today       DATE    DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_stage       VARCHAR(20);
  DECLARE v_version     INT UNSIGNED;
  DECLARE v_old_source  VARCHAR(10);
  DECLARE v_old_owner   BIGINT UNSIGNED;
  DECLARE v_owner       BIGINT UNSIGNED DEFAULT p_owner_user_id;
  DECLARE v_account     VARCHAR(200) DEFAULT NULLIF(TRIM(p_account_name_text), '');
  DECLARE v_all         TINYINT;
  DECLARE v_own         TINYINT;
  DECLARE v_assigned    TINYINT;
  DECLARE v_partner     TINYINT;
  DECLARE v_module      TINYINT;
  DECLARE v_requested   INT DEFAULT 0;
  DECLARE v_valid       INT DEFAULT 0;
  DECLARE v_new_stage   VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT stage_code, row_version, source, owner_user_id
    INTO v_stage, v_version, v_old_source, v_old_owner
    FROM sales_lead WHERE id = p_lead_id;

  IF v_stage IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Lead not found.', 'id');
  END IF;
  IF v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This lead was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;
  IF v_stage IN ('CONVERTED', 'DISQUALIFIED') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Converted or disqualified leads cannot be edited.', 'stageCode');
  END IF;

  -- scope: actor must own the lead or have ALL scope
  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 AND v_old_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_old_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You do not have permission to edit this lead.', 'id');
  END IF;

  -- source and partner
  IF p_source IS NULL OR p_source NOT IN ('DIRECT','PARTNER','TENDER','EVENT','WEBSITE','REFERRAL') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the source of the lead.', 'source');
  END IF;
  IF p_source = 'PARTNER' AND p_partner_id IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the partner that brought this lead.', 'partnerId');
  END IF;
  IF p_partner_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM partner WHERE id = p_partner_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'The partner does not exist or is inactive.', 'partnerId');
  END IF;

  -- account
  IF p_account_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM account WHERE id = p_account_id AND is_active = 1) THEN
      CALL spi_raise('VALIDATION_FAILED', 'The account does not exist or is inactive.', 'accountId');
    END IF;
    SET v_account = NULL;
  ELSE
    IF v_account IS NULL THEN
      CALL spi_raise('VALIDATION_FAILED', 'Choose an existing account or enter the new company name.', 'accountNameText');
    END IF;
    IF EXISTS (SELECT 1 FROM account WHERE name = v_account AND is_active = 1
               AND NOT EXISTS (SELECT 1 FROM sales_lead sl WHERE sl.account_name_text = v_account AND sl.id = p_lead_id)) THEN
      CALL spi_raise('VALIDATION_FAILED', 'An account with this name exists. Select it from the list.', 'accountNameText');
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM industry WHERE id = p_industry_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the industry.', 'industryId');
  END IF;

  -- owner
  IF v_owner IS NULL THEN SET v_owner = v_old_owner; END IF;
  IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = v_owner AND status = 'ACTIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'The owner must be an active user.', 'ownerUserId');
  END IF;
  IF v_owner <> p_actor_user_id AND v_all = 0
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('VALIDATION_FAILED', 'You can assign a lead to yourself or to someone in your team.', 'ownerUserId');
  END IF;
  IF p_backup_owner_user_id IS NOT NULL THEN
    IF p_backup_owner_user_id = v_owner THEN
      CALL spi_raise('VALIDATION_FAILED', 'The backup owner must be a different person.', 'backupOwnerUserId');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_backup_owner_user_id AND status = 'ACTIVE') THEN
      CALL spi_raise('VALIDATION_FAILED', 'The backup owner must be an active user.', 'backupOwnerUserId');
    END IF;
  END IF;

  IF p_next_action_due_on IS NOT NULL AND p_next_action_due_on < v_today THEN
    CALL spi_raise('VALIDATION_FAILED', 'The due date cannot be in the past.', 'nextActionDueOn');
  END IF;
  IF p_rough_value IS NOT NULL AND p_rough_value <= 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'The rough value must be more than zero.', 'roughValue');
  END IF;

  -- qualification: solution
  IF p_product_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM product WHERE id = p_product_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Product not found or inactive.', 'productId');
  END IF;
  IF p_solution_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM solution WHERE id = p_solution_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Solution not found or inactive.', 'solutionId');
  END IF;
  IF p_procurement_type_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM procurement_type WHERE id = p_procurement_type_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Procurement type not found or inactive.', 'procurementTypeId');
  END IF;
  IF p_budget_known IS NOT NULL AND p_budget_known NOT IN ('YES','NO','TBD') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Budget known must be YES, NO or TBD.', 'budgetKnown');
  END IF;

  -- products of interest
  IF p_product_ids IS NOT NULL AND JSON_LENGTH(p_product_ids) > 0 THEN
    SELECT COUNT(DISTINCT jt.product_id) INTO v_requested
      FROM JSON_TABLE(p_product_ids, '$[*]' COLUMNS (product_id BIGINT UNSIGNED PATH '$')) jt;
    SELECT COUNT(DISTINCT pr.id) INTO v_valid
      FROM JSON_TABLE(p_product_ids, '$[*]' COLUMNS (product_id BIGINT UNSIGNED PATH '$')) jt
      JOIN product pr ON pr.id = jt.product_id AND pr.is_active = 1;
    IF v_valid <> v_requested THEN
      CALL spi_raise('VALIDATION_FAILED', 'One or more products are invalid or inactive.', 'productIds');
    END IF;
  END IF;

  -- determine new stage: advance to QUALIFYING if a qualification field is provided
  SET v_new_stage = v_stage;
  IF v_stage IN ('NEW','CONTACTED')
     AND (p_problem_statement IS NOT NULL OR p_product_id IS NOT NULL OR p_solution_id IS NOT NULL
          OR p_commercial_window_value IS NOT NULL OR p_budget_known IS NOT NULL
          OR p_procurement_type_id IS NOT NULL OR p_expected_close_date IS NOT NULL) THEN
    SET v_new_stage = 'QUALIFYING';
  END IF;

  START TRANSACTION;

  UPDATE sales_lead SET
    source                 = p_source,
    partner_id             = p_partner_id,
    partner_contact_text   = NULLIF(TRIM(COALESCE(p_partner_contact, '')), ''),
    account_id             = p_account_id,
    account_name_text      = v_account,
    industry_id            = p_industry_id,
    contact_name           = TRIM(p_contact_name),
    contact_designation    = NULLIF(TRIM(COALESCE(p_contact_designation, '')), ''),
    contact_email          = NULLIF(TRIM(COALESCE(p_contact_email, '')), ''),
    contact_phone          = NULLIF(TRIM(COALESCE(p_contact_phone, '')), ''),
    city                   = TRIM(p_city),
    locations_count        = p_locations_count,
    need_text              = TRIM(p_need_text),
    rough_value            = p_rough_value,
    rough_timing           = NULLIF(TRIM(COALESCE(p_rough_timing, '')), ''),
    owner_user_id          = v_owner,
    backup_owner_user_id   = p_backup_owner_user_id,
    next_action            = TRIM(p_next_action),
    next_action_due_on     = p_next_action_due_on,
    -- qualification facts
    problem_statement      = NULLIF(TRIM(COALESCE(p_problem_statement, '')), ''),
    product_id             = p_product_id,
    solution_id            = p_solution_id,
    commercial_window_value = p_commercial_window_value,
    budget_known           = p_budget_known,
    budget_min             = p_budget_min,
    budget_max             = p_budget_max,
    procurement_type_id    = p_procurement_type_id,
    procurement_steps_known = COALESCE(p_procurement_steps_known, 0),
    expected_close_date    = p_expected_close_date,
    stage_code             = v_new_stage,
    stage_entered_at       = IF(v_new_stage <> v_stage, UTC_TIMESTAMP(3), stage_entered_at),
    updated_by             = p_actor_user_id,
    updated_at             = UTC_TIMESTAMP(3),
    row_version            = row_version + 1
  WHERE id = p_lead_id AND row_version = p_row_version;

  IF ROW_COUNT() = 0 THEN
    ROLLBACK;
    CALL spi_raise('CONFLICT', 'This lead was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;

  -- refresh products of interest
  IF p_product_ids IS NOT NULL THEN
    DELETE FROM lead_product WHERE lead_id = p_lead_id;
    IF JSON_LENGTH(p_product_ids) > 0 THEN
      INSERT INTO lead_product (lead_id, product_id, created_by)
      SELECT DISTINCT p_lead_id, jt.product_id, p_actor_user_id
        FROM JSON_TABLE(p_product_ids, '$[*]' COLUMNS (product_id BIGINT UNSIGNED PATH '$')) jt;
    END IF;
  END IF;

  -- stage history row if stage advanced
  IF v_new_stage <> v_stage THEN
    INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
    VALUES ('LEAD', p_lead_id, v_stage, v_new_stage, p_actor_user_id);
  END IF;

  -- recalculate qualification_pct after the update is committed
  CALL spi_lead_qualification_pct(p_lead_id);

  CALL spi_audit_write('LEAD', p_lead_id, 'UPDATE',
       JSON_OBJECT('source', JSON_OBJECT('from', v_old_source, 'to', p_source),
                   'ownerUserId', JSON_OBJECT('from', v_old_owner, 'to', v_owner)),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_lead_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_lead_disqualify
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_lead_disqualify $$
CREATE PROCEDURE sp_lead_disqualify(
  IN p_actor_user_id    BIGINT UNSIGNED,
  IN p_request_id       VARCHAR(64),
  IN p_ip               VARCHAR(45),
  IN p_lead_id          BIGINT UNSIGNED,
  IN p_row_version      INT UNSIGNED,
  IN p_reason_id        BIGINT UNSIGNED,
  IN p_note             VARCHAR(1000)
)
  SQL SECURITY DEFINER
  COMMENT 'Disqualify a lead with a reason (BR-LD-07)'
BEGIN
  DECLARE v_stage    VARCHAR(20);
  DECLARE v_version  INT UNSIGNED;
  DECLARE v_owner    BIGINT UNSIGNED;
  DECLARE v_all      TINYINT;
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT stage_code, row_version, owner_user_id
    INTO v_stage, v_version, v_owner
    FROM sales_lead WHERE id = p_lead_id;

  IF v_stage IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Lead not found.', 'id');
  END IF;
  IF v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This lead was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;
  IF v_stage IN ('CONVERTED', 'DISQUALIFIED') THEN
    CALL spi_raise('VALIDATION_FAILED', 'This lead is already closed.', 'stageCode');
  END IF;
  IF p_reason_id IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose a disqualify reason.', 'reasonId');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM reason WHERE id = p_reason_id AND reason_type = 'DISQUALIFY' AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid disqualify reason.', 'reasonId');
  END IF;

  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You do not have permission to disqualify this lead.', 'id');
  END IF;

  START TRANSACTION;

  UPDATE sales_lead SET
    stage_code           = 'DISQUALIFIED',
    stage_entered_at     = UTC_TIMESTAMP(3),
    disqualify_reason_id = p_reason_id,
    disqualify_note      = NULLIF(TRIM(COALESCE(p_note, '')), ''),
    disqualified_at      = UTC_TIMESTAMP(3),
    updated_by           = p_actor_user_id,
    updated_at           = UTC_TIMESTAMP(3),
    row_version          = row_version + 1
  WHERE id = p_lead_id AND row_version = p_row_version;

  IF ROW_COUNT() = 0 THEN
    ROLLBACK;
    CALL spi_raise('CONFLICT', 'This lead was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;

  INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
  VALUES ('LEAD', p_lead_id, v_stage, 'DISQUALIFIED', p_actor_user_id);

  CALL spi_audit_write('LEAD', p_lead_id, 'DISQUALIFY',
       JSON_OBJECT('stageCode', JSON_OBJECT('from', v_stage, 'to', 'DISQUALIFIED'),
                   'reasonId',  JSON_OBJECT('from', NULL, 'to', p_reason_id)),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT p_lead_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_lead_convert
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_lead_convert $$
CREATE PROCEDURE sp_lead_convert(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(64),
  IN p_ip             VARCHAR(45),
  IN p_lead_id        BIGINT UNSIGNED,
  IN p_row_version    INT UNSIGNED,
  IN p_title          VARCHAR(250)
)
  SQL SECURITY DEFINER
  COMMENT 'Convert a fully-qualified lead to an opportunity in stage QUALIFIED (BR-LD-06, 08)'
BEGIN
  DECLARE v_stage     VARCHAR(20);
  DECLARE v_version   INT UNSIGNED;
  DECLARE v_owner     BIGINT UNSIGNED;
  DECLARE v_backup    BIGINT UNSIGNED;
  DECLARE v_account   BIGINT UNSIGNED;
  DECLARE v_industry  BIGINT UNSIGNED;
  DECLARE v_source    VARCHAR(10);
  DECLARE v_solution  BIGINT UNSIGNED;
  DECLARE v_problem   TEXT;
  DECLARE v_ec_date   DATE;
  DECLARE v_value     DECIMAL(16,2);
  DECLARE v_qual_pct  DECIMAL(5,2);
  DECLARE v_all       TINYINT;
  DECLARE v_own       TINYINT;
  DECLARE v_assigned  TINYINT;
  DECLARE v_partner   TINYINT;
  DECLARE v_module    TINYINT;
  DECLARE v_opp_no    VARCHAR(30);
  DECLARE v_opp_id    BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT l.stage_code, l.row_version, l.owner_user_id, l.backup_owner_user_id,
         l.account_id, l.industry_id, l.source, l.solution_id, l.problem_statement,
         l.expected_close_date, l.rough_value, l.qualification_pct
    INTO v_stage, v_version, v_owner, v_backup, v_account, v_industry, v_source,
         v_solution, v_problem, v_ec_date, v_value, v_qual_pct
    FROM sales_lead l WHERE l.id = p_lead_id;

  IF v_stage IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Lead not found.', 'id');
  END IF;
  IF v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This lead was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;
  IF v_stage IN ('CONVERTED', 'DISQUALIFIED') THEN
    CALL spi_raise('VALIDATION_FAILED', 'This lead is already closed.', 'stageCode');
  END IF;
  IF v_account IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'The lead must be linked to an existing account before converting. Create the account first.', 'accountId');
  END IF;
  IF v_qual_pct < 100 THEN
    CALL spi_raise('VALIDATION_FAILED', 'All six qualification facts must be complete before converting.', 'qualificationPct');
  END IF;

  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id
                        AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You do not have permission to convert this lead.', 'id');
  END IF;

  IF p_title IS NULL OR TRIM(p_title) = '' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Enter a title for the opportunity.', 'title');
  END IF;

  START TRANSACTION;

  CALL spi_next_number('OP', 1, v_opp_no);

  INSERT INTO opportunity (
    opportunity_no, title, account_id, lead_id, source, industry_id, solution_id,
    problem_statement, expected_close_date, expected_value, stage_code, stage_entered_at,
    owner_user_id, backup_owner_user_id, created_by
  ) VALUES (
    v_opp_no, TRIM(p_title), v_account, p_lead_id, v_source, v_industry, v_solution,
    v_problem, v_ec_date, COALESCE(v_value, 0), 'QUALIFIED', UTC_TIMESTAMP(3),
    v_owner, v_backup, p_actor_user_id
  );
  SET v_opp_id = LAST_INSERT_ID();

  -- copy lead products to opportunity_product
  INSERT INTO opportunity_product (opportunity_id, product_id, created_by)
  SELECT v_opp_id, lp.product_id, p_actor_user_id
    FROM lead_product lp WHERE lp.lead_id = p_lead_id;

  INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
  VALUES ('OPP', v_opp_id, NULL, 'QUALIFIED', p_actor_user_id);

  UPDATE sales_lead SET
    stage_code      = 'CONVERTED',
    stage_entered_at = UTC_TIMESTAMP(3),
    opportunity_id  = v_opp_id,
    converted_at    = UTC_TIMESTAMP(3),
    updated_by      = p_actor_user_id,
    updated_at      = UTC_TIMESTAMP(3),
    row_version     = row_version + 1
  WHERE id = p_lead_id AND row_version = p_row_version;

  IF ROW_COUNT() = 0 THEN
    ROLLBACK;
    CALL spi_raise('CONFLICT', 'This lead was modified by someone else. Reload and try again.', 'rowVersion');
  END IF;

  INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
  VALUES ('LEAD', p_lead_id, v_stage, 'CONVERTED', p_actor_user_id);

  CALL spi_audit_write('LEAD', p_lead_id, 'CONVERT',
       JSON_OBJECT('stageCode', JSON_OBJECT('from', v_stage, 'to', 'CONVERTED'),
                   'opportunityId', JSON_OBJECT('from', NULL, 'to', v_opp_id)),
       NULL, p_actor_user_id, p_ip, p_request_id);
  CALL spi_audit_write('OPP', v_opp_id, 'CREATE',
       JSON_OBJECT('opportunityNo', JSON_OBJECT('from', NULL, 'to', v_opp_no),
                   'leadId', JSON_OBJECT('from', NULL, 'to', p_lead_id)),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT v_opp_id AS opportunityId, v_opp_no AS opportunityNo;
END $$

-- ---------------------------------------------------------------------------
-- sp_lead_get: re-issue from V008 adding row_version + qualification field IDs
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_lead_get $$
CREATE PROCEDURE sp_lead_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Lead page with the qualification facts (12.4) + row_version for optimistic lock'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;

  CALL spi_visible_leads(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_lead WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_lead;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Lead not found.', 'id');
  END IF;

  SELECT l.id, l.lead_no AS leadNo, l.stage_code AS stageCode, s.name AS stageName,
         l.stage_entered_at AS stageEnteredAt, l.source, l.partner_id AS partnerId,
         p.short_name AS partnerName, l.partner_contact_text AS partnerContact,
         l.account_id AS accountId, COALESCE(a.name, l.account_name_text) AS accountName,
         (l.account_id IS NULL) AS isNewAccount, i.id AS industryId, i.name AS industryName,
         l.contact_name AS contactName, l.contact_designation AS contactDesignation,
         l.contact_email AS contactEmail, l.contact_phone AS contactPhone, l.city,
         l.locations_count AS locationsCount, l.need_text AS needText,
         CAST(l.rough_value AS DECIMAL(18,2)) AS roughValue, l.rough_timing AS roughTiming,
         u.full_name AS ownerName, u.id AS ownerUserId,
         b.full_name AS backupOwnerName, b.id AS backupOwnerUserId,
         l.next_action AS nextAction, l.next_action_due_on AS nextActionDueOn,
         l.problem_statement AS problemStatement,
         pr.name AS productName, pr.id AS productId,
         so.name AS solutionName, so.id AS solutionId,
         CAST(l.commercial_window_value AS DECIMAL(18,2)) AS commercialWindowValue,
         l.budget_known AS budgetKnown, CAST(l.budget_min AS DECIMAL(18,2)) AS budgetMin,
         CAST(l.budget_max AS DECIMAL(18,2)) AS budgetMax,
         pt.id AS procurementTypeId, pt.name AS procurementTypeName,
         l.procurement_steps_known AS procurementStepsKnown,
         l.expected_close_date AS expectedCloseDate,
         l.qualification_pct AS qualificationPct, r.name AS disqualifyReason,
         l.disqualify_note AS disqualifyNote, l.disqualified_at AS disqualifiedAt,
         l.opportunity_id AS opportunityId, o.opportunity_no AS opportunityNo,
         l.converted_at AS convertedAt, l.last_activity_at AS lastActivityAt,
         l.created_at AS createdAt, cb.full_name AS createdByName,
         l.row_version AS rowVersion
    FROM sales_lead l
    LEFT JOIN stage s ON s.entity = 'LEAD' AND s.code = l.stage_code
    LEFT JOIN partner p ON p.id = l.partner_id
    LEFT JOIN account a ON a.id = l.account_id
    LEFT JOIN industry i ON i.id = l.industry_id
    LEFT JOIN product pr ON pr.id = l.product_id
    LEFT JOIN solution so ON so.id = l.solution_id
    LEFT JOIN procurement_type pt ON pt.id = l.procurement_type_id
    LEFT JOIN reason r ON r.id = l.disqualify_reason_id
    LEFT JOIN opportunity o ON o.id = l.opportunity_id
    LEFT JOIN `user` b ON b.id = l.backup_owner_user_id
    LEFT JOIN `user` cb ON cb.id = l.created_by
    JOIN `user` u ON u.id = l.owner_user_id
   WHERE l.id = p_id;

  -- the six qualification facts (BR-LD-05); conversion needs 6 / 6 (BR-LD-06)
  SELECT 1 AS seq, 'PROBLEM' AS code, 'Problem statement' AS label,
         (NULLIF(TRIM(l.problem_statement), '') IS NOT NULL) AS done
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 2, 'SOLUTION', 'Solution mapped (product + solution)',
         (l.product_id IS NOT NULL AND l.solution_id IS NOT NULL)
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 3, 'COMMERCIAL', 'Commercial window (value + budget)',
         (l.commercial_window_value IS NOT NULL AND l.budget_known IS NOT NULL
          AND (l.budget_known <> 'YES' OR l.budget_min IS NOT NULL OR l.budget_max IS NOT NULL))
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 4, 'DMU', 'DMU: tech buyer, commercial buyer, influencer',
         (EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_id AND d.dmu_role = 'TECH_BUYER')
          AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_id AND d.dmu_role = 'COMM_BUYER')
          AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_id AND d.dmu_role IN ('INFLUENCER_INT', 'INFLUENCER_EXT')))
  UNION ALL
  SELECT 5, 'PROCUREMENT', 'Procurement process known',
         (l.procurement_type_id IS NOT NULL AND l.procurement_steps_known = 1)
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 6, 'CLOSE_DATE', 'Expected closure date', (l.expected_close_date IS NOT NULL)
    FROM sales_lead l WHERE l.id = p_id
  ORDER BY seq;

  SELECT pr.id, pr.name FROM lead_product lp JOIN product pr ON pr.id = lp.product_id
   WHERE lp.lead_id = p_id ORDER BY pr.sort_order, pr.name;

  SELECT d.id, d.name, d.designation, d.dmu_role AS dmuRole, d.influence_level AS influenceLevel,
         d.stand, d.notes
    FROM lead_dmu d WHERE d.lead_id = p_id
   ORDER BY FIELD(d.dmu_role, 'TECH_BUYER', 'COMM_BUYER', 'INFLUENCER_INT', 'INFLUENCER_EXT'), d.id;

  SELECT c.id, c.name FROM lead_competitor lc JOIN competitor c ON c.id = lc.competitor_id
   WHERE lc.lead_id = p_id ORDER BY c.name;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject,
         ac.notes, ac.outcome, ac.people_met AS peopleMet, ac.next_action AS nextAction,
         ac.next_action_on AS nextActionOn, u.full_name AS byName
    FROM activity ac JOIN `user` u ON u.id = ac.by_user_id
   WHERE ac.is_active = 1 AND (ac.lead_id = p_id OR (ac.entity_type = 'LEAD' AND ac.entity_id = p_id))
   ORDER BY ac.activity_at DESC, ac.id DESC
   LIMIT 100;

  SELECT tk.id, tk.task_type AS taskType, tk.title, tk.due_at AS dueAt, tk.status,
         u.full_name AS ownerName
    FROM task tk JOIN `user` u ON u.id = tk.owner_user_id
   WHERE tk.entity_type = 'LEAD' AND tk.entity_id = p_id
   ORDER BY tk.status = 'OPEN' DESC, tk.due_at;

  SELECT sh.id, fs.name AS fromStage, ts.name AS toStage, u.full_name AS changedByName,
         sh.changed_at AS changedAt, sh.reason, sh.days_in_previous AS daysInPrevious
    FROM stage_history sh
    LEFT JOIN stage fs ON fs.entity = 'LEAD' AND fs.code = sh.from_stage
    LEFT JOIN stage ts ON ts.entity = 'LEAD' AND ts.code = sh.to_stage
    LEFT JOIN `user` u ON u.id = sh.changed_by
   WHERE sh.entity_type = 'LEAD' AND sh.entity_id = p_id
   ORDER BY sh.changed_at DESC, sh.id DESC;
END $$

DELIMITER ;
