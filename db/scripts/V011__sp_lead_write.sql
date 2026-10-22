-- =============================================================================
-- V011  Sales CRM - leads, write side: create a lead (M05)           (2026-10-12)
--
--   sp_lead_create  BR-LD-01 mandatory fields, BR-LD-02 partner when source = PARTNER,
--                   BR-LD-09 no second account with the same name, owner limited to the
--                   creator's team (10.8). Writes the lead (stage NEW), its products, the
--                   stage history row, the follow-up task (next action + due date) and
--                   the audit row in one transaction.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V010.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_lead_create $$
CREATE PROCEDURE sp_lead_create(
  IN p_actor_user_id       BIGINT UNSIGNED,
  IN p_request_id          VARCHAR(64),
  IN p_ip                  VARCHAR(45),
  IN p_source              VARCHAR(10),
  IN p_partner_id          BIGINT UNSIGNED,
  IN p_partner_contact     VARCHAR(200),
  IN p_account_id          BIGINT UNSIGNED,
  IN p_account_name_text   VARCHAR(200),
  IN p_industry_id         BIGINT UNSIGNED,
  IN p_contact_name        VARCHAR(150),
  IN p_contact_designation VARCHAR(100),
  IN p_contact_email       VARCHAR(150),
  IN p_contact_phone       VARCHAR(20),
  IN p_city                VARCHAR(100),
  IN p_locations_count     INT UNSIGNED,
  IN p_need_text           TEXT,
  IN p_rough_value         DECIMAL(16,2),
  IN p_rough_timing        VARCHAR(40),
  IN p_owner_user_id       BIGINT UNSIGNED,
  IN p_backup_owner_user_id BIGINT UNSIGNED,
  IN p_next_action         VARCHAR(500),
  IN p_next_action_due_on  DATE,
  IN p_product_ids         JSON
)
  SQL SECURITY DEFINER
  COMMENT 'Create a lead in stage NEW with its follow-up task (12.4, BR-LD-01, 02, 09)'
BEGIN
  DECLARE v_today      DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_owner      BIGINT UNSIGNED DEFAULT IFNULL(p_owner_user_id, p_actor_user_id);
  DECLARE v_account    VARCHAR(200) DEFAULT NULLIF(TRIM(p_account_name_text), '');
  DECLARE v_all        TINYINT;
  DECLARE v_own        TINYINT;
  DECLARE v_assigned   TINYINT;
  DECLARE v_partner    TINYINT;
  DECLARE v_module     TINYINT;
  DECLARE v_requested  INT DEFAULT 0;
  DECLARE v_valid      INT DEFAULT 0;
  DECLARE v_no         VARCHAR(30);
  DECLARE v_lead_id    BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  -- source and partner (BR-LD-02)
  IF p_source IS NULL OR p_source NOT IN ('DIRECT', 'PARTNER', 'TENDER', 'EVENT', 'WEBSITE', 'REFERRAL') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the source of the lead.', 'source');
  END IF;
  IF p_source = 'PARTNER' AND p_partner_id IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the partner that brought this lead.', 'partnerId');
  END IF;
  IF p_partner_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM partner WHERE id = p_partner_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'The partner does not exist or is inactive.', 'partnerId');
  END IF;

  -- account: an existing one, or a new name that is not taken yet (BR-LD-09)
  IF p_account_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM account WHERE id = p_account_id AND is_active = 1) THEN
      CALL spi_raise('VALIDATION_FAILED', 'The account does not exist or is inactive.', 'accountId');
    END IF;
    SET v_account = NULL;
  ELSE
    IF v_account IS NULL THEN
      CALL spi_raise('VALIDATION_FAILED', 'Choose an existing account or enter the new company name.', 'accountNameText');
    END IF;
    IF EXISTS (SELECT 1 FROM account WHERE name = v_account AND is_active = 1) THEN
      CALL spi_raise('VALIDATION_FAILED', 'An account with this name exists. Select it from the list.', 'accountNameText');
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM industry WHERE id = p_industry_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the industry.', 'industryId');
  END IF;

  -- owner: the creator or someone in the creator's team (all-scope roles: anyone active)
  IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = v_owner AND status = 'ACTIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'The owner must be an active user.', 'ownerUserId');
  END IF;
  IF v_owner <> p_actor_user_id THEN
    CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
    IF v_all = 0 AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                                  WHERE h.ancestor_user_id = p_actor_user_id
                                    AND h.descendant_user_id = v_owner) THEN
      CALL spi_raise('VALIDATION_FAILED', 'You can assign a lead to yourself or to someone in your team.', 'ownerUserId');
    END IF;
  END IF;
  IF p_backup_owner_user_id IS NOT NULL THEN
    IF p_backup_owner_user_id = v_owner THEN
      CALL spi_raise('VALIDATION_FAILED', 'The backup owner must be a different person.', 'backupOwnerUserId');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_backup_owner_user_id AND status = 'ACTIVE') THEN
      CALL spi_raise('VALIDATION_FAILED', 'The backup owner must be an active user.', 'backupOwnerUserId');
    END IF;
  END IF;

  IF p_next_action_due_on < v_today THEN
    CALL spi_raise('VALIDATION_FAILED', 'The due date cannot be in the past.', 'nextActionDueOn');
  END IF;
  IF p_rough_value IS NOT NULL AND p_rough_value <= 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'The rough value must be more than zero.', 'roughValue');
  END IF;

  -- products of interest (optional)
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

  START TRANSACTION;

  CALL spi_next_number('LD', 1, v_no);

  INSERT INTO sales_lead (lead_no, source, partner_id, partner_contact_text, account_id, account_name_text,
                          industry_id, contact_name, contact_designation, contact_email, contact_phone,
                          city, locations_count, need_text, rough_value, rough_timing,
                          owner_user_id, backup_owner_user_id, next_action, next_action_due_on,
                          created_by)
  VALUES (v_no, p_source, p_partner_id, NULLIF(TRIM(p_partner_contact), ''), p_account_id, v_account,
          p_industry_id, TRIM(p_contact_name), NULLIF(TRIM(p_contact_designation), ''),
          NULLIF(TRIM(p_contact_email), ''), NULLIF(TRIM(p_contact_phone), ''),
          TRIM(p_city), p_locations_count, TRIM(p_need_text), p_rough_value,
          NULLIF(TRIM(p_rough_timing), ''), v_owner, p_backup_owner_user_id,
          TRIM(p_next_action), p_next_action_due_on, p_actor_user_id);
  SET v_lead_id = LAST_INSERT_ID();

  IF v_requested > 0 THEN
    INSERT INTO lead_product (lead_id, product_id, created_by)
    SELECT DISTINCT v_lead_id, jt.product_id, p_actor_user_id
      FROM JSON_TABLE(p_product_ids, '$[*]' COLUMNS (product_id BIGINT UNSIGNED PATH '$')) jt;
  END IF;

  INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
  VALUES ('LEAD', v_lead_id, NULL, 'NEW', p_actor_user_id);

  -- the next action becomes a follow-up task for the owner (UM 6.1)
  INSERT INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref, created_by)
  VALUES ('LEAD', v_lead_id, 'FOLLOW_UP', TRIM(p_next_action), v_owner,
          TIMESTAMP(p_next_action_due_on, '05:30:00'), 'OPEN', CONCAT('lead-next-', v_lead_id), p_actor_user_id);

  CALL spi_audit_write('LEAD', v_lead_id, 'CREATE',
       JSON_OBJECT('leadNo',          JSON_OBJECT('from', NULL, 'to', v_no),
                   'source',          JSON_OBJECT('from', NULL, 'to', p_source),
                   'accountId',       JSON_OBJECT('from', NULL, 'to', p_account_id),
                   'accountNameText', JSON_OBJECT('from', NULL, 'to', v_account),
                   'ownerUserId',     JSON_OBJECT('from', NULL, 'to', v_owner)),
       NULL, p_actor_user_id, p_ip, p_request_id);

  COMMIT;

  SELECT v_lead_id AS id, v_no AS leadNo;
END $$

DELIMITER ;
