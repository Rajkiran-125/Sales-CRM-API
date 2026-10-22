-- =============================================================================
-- V024  Sales CRM - lead convert creates the new account                (2026-10-14)
--
--   sp_lead_convert  Re-issue of V021. A lead without an account (account_name_text,
--                    "new account" on the lead form) no longer fails: convert links it
--                    to an active account of exactly that name, else creates the
--                    account (12.6: "directly or at lead conversion") as a PROSPECT with
--                    the lead's industry, city, locations, owner and backup owner.
--                    The DMU copy from V021 is unchanged.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V023.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_lead_convert: re-issue of V021, creating or linking the account first
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
  DECLARE v_dmu_id    BIGINT UNSIGNED;
  DECLARE v_dmu_name  VARCHAR(150);
  DECLARE v_contact   BIGINT UNSIGNED;
  DECLARE v_acc_name  VARCHAR(200);
  DECLARE v_city      VARCHAR(100);
  DECLARE v_locations INT UNSIGNED;
  DECLARE v_acc_no    VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT l.stage_code, l.row_version, l.owner_user_id, l.backup_owner_user_id,
         l.account_id, l.industry_id, l.source, l.solution_id, l.problem_statement,
         l.expected_close_date, l.rough_value, l.qualification_pct,
         NULLIF(TRIM(l.account_name_text), ''), l.city, l.locations_count
    INTO v_stage, v_version, v_owner, v_backup, v_account, v_industry, v_source,
         v_solution, v_problem, v_ec_date, v_value, v_qual_pct,
         v_acc_name, v_city, v_locations
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
  IF v_account IS NULL AND v_acc_name IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the account or enter the new company name before converting.', 'accountId');
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

  -- new-account lead: link to an active account of that exact name, else create it (12.6)
  IF v_account IS NULL THEN
    SELECT id INTO v_account FROM account
     WHERE is_active = 1 AND name = v_acc_name ORDER BY id LIMIT 1;
    IF v_account IS NULL THEN
      CALL spi_next_number('ACC', 0, v_acc_no);
      INSERT INTO account (
        account_no, name, industry_id, account_type, city, locations_count,
        owner_user_id, backup_owner_user_id, created_at, created_by
      ) VALUES (
        v_acc_no, v_acc_name, v_industry, 'PROSPECT', v_city, v_locations,
        v_owner, NULLIF(v_backup, v_owner), UTC_TIMESTAMP(3), p_actor_user_id
      );
      SET v_account = LAST_INSERT_ID();
      INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
      VALUES ('account', v_account, 'ACCOUNT_CREATE',
              JSON_OBJECT('ownerUserId', JSON_OBJECT('to', v_owner),
                          'leadId', JSON_OBJECT('to', p_lead_id)),
              p_actor_user_id, p_ip, p_request_id);
    END IF;
  END IF;

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

  -- link each lead DMU person to an account contact: same name, else a new contact
  WHILE EXISTS (SELECT 1 FROM lead_dmu WHERE lead_id = p_lead_id AND contact_id IS NULL) DO
    SELECT id, name INTO v_dmu_id, v_dmu_name
      FROM lead_dmu WHERE lead_id = p_lead_id AND contact_id IS NULL ORDER BY id LIMIT 1;
    SET v_contact = NULL;
    SELECT id INTO v_contact FROM contact
     WHERE account_id = v_account AND is_active = 1 AND name = v_dmu_name
     ORDER BY id LIMIT 1;
    IF v_contact IS NULL THEN
      INSERT INTO contact (account_id, name, designation, influence_level, stand, is_active,
                           created_at, created_by)
      SELECT v_account, d.name, d.designation, d.influence_level, d.stand, 1,
             UTC_TIMESTAMP(3), p_actor_user_id
        FROM lead_dmu d WHERE d.id = v_dmu_id;
      SET v_contact = LAST_INSERT_ID();
    END IF;
    UPDATE lead_dmu SET contact_id = v_contact WHERE lead_id = p_lead_id
       AND contact_id IS NULL AND name = v_dmu_name;
  END WHILE;

  -- one row per (contact, role); a duplicate pair on the lead keeps the lowest id
  INSERT INTO opportunity_dmu (opportunity_id, contact_id, dmu_role, influence_level, stand, notes,
                               created_at, created_by)
  SELECT v_opp_id, d.contact_id, d.dmu_role, d.influence_level, d.stand, d.notes,
         UTC_TIMESTAMP(3), p_actor_user_id
    FROM lead_dmu d
   WHERE d.lead_id = p_lead_id
     AND d.id = (SELECT MIN(d2.id) FROM lead_dmu d2
                  WHERE d2.lead_id = p_lead_id AND d2.contact_id = d.contact_id
                    AND d2.dmu_role = d.dmu_role);

  INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
  VALUES ('OPP', v_opp_id, NULL, 'QUALIFIED', p_actor_user_id);

  UPDATE sales_lead SET
    stage_code      = 'CONVERTED',
    stage_entered_at = UTC_TIMESTAMP(3),
    account_id      = v_account,
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

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V024', 'sp_lead_convert creates the account for a new-account lead', UTC_TIMESTAMP());
