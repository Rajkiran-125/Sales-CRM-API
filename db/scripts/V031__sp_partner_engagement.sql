-- =============================================================================
-- V031  Sales CRM - partner engagement log, next plan task, account map  (2026-10-14)
--
--   spi_partner_owner_check        owner, backup or their manager (or ALL scope); no version
--   sp_partner_engagement_save     POST / PATCH /partners/{id}/engagements: log an engagement
--                                  (anyone who sees the partner); edit your own (or as the
--                                  owner / ALL scope). Keeps last / next engagement on the
--                                  partner; a next action with a date upserts ONE open
--                                  ENGAGEMENT task per partner for the relationship owner
--                                  (BR-PT-05). The reminder email comes with the scheduler jobs.
--   sp_partner_account_map_save    POST / PATCH /partners/{id}/account-map: 6-month plan rows.
--   sp_partner_account_map_delete  DELETE /partners/{id}/account-map/{rowId}
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V030.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS spi_partner_owner_check $$
CREATE PROCEDURE spi_partner_owner_check(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_owner  BIGINT UNSIGNED;
  DECLARE v_backup BIGINT UNSIGNED;

  SELECT relationship_owner_user_id, backup_owner_user_id INTO v_owner, v_backup
    FROM partner WHERE id = p_partner_id AND is_active = 1 AND deleted_at IS NULL;
  IF v_owner IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Partner not found.', 'id');
  END IF;
  IF p_allow_any = 0 AND NOT EXISTS (SELECT 1 FROM user_hierarchy
       WHERE ancestor_user_id = p_actor_user_id AND descendant_user_id IN (v_owner, IFNULL(v_backup, 0))) THEN
    CALL spi_raise('FORBIDDEN', 'Only the relationship owner, the backup owner or their manager can change this partner.', 'id');
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_engagement_save: p_id NULL = new
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_engagement_save $$
CREATE PROCEDURE sp_partner_engagement_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_id            BIGINT UNSIGNED,
  IN p_type          VARCHAR(15),
  IN p_on            DATE,
  IN p_with_whom     VARCHAR(500),
  IN p_notes         TEXT,
  IN p_outcome       VARCHAR(1000),
  IN p_next_action   VARCHAR(500),
  IN p_next_on       DATE,
  IN p_account_id    BIGINT UNSIGNED,   -- on an edit, NULL keeps the stored account
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible INT;
  DECLARE v_by      BIGINT UNSIGNED;
  DECLARE v_owner   BIGINT UNSIGNED;
  DECLARE v_id      BIGINT UNSIGNED;
  DECLARE v_name    VARCHAR(250);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_visible_partners(p_actor_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_ptr WHERE id = p_partner_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Partner not found.', 'id');
  END IF;
  IF p_on > DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE) THEN
    CALL spi_raise('VALIDATION_FAILED', 'An engagement is logged after it happened; plan the next one instead.', 'engagementOn');
  END IF;
  IF p_next_on IS NOT NULL AND p_next_on < p_on THEN
    CALL spi_raise('VALIDATION_FAILED', 'The next engagement must be after this one.', 'nextActionOn');
  END IF;
  IF p_next_on IS NOT NULL AND NULLIF(TRIM(IFNULL(p_next_action, '')), '') IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Say what the next engagement is.', 'nextAction');
  END IF;
  IF p_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM account WHERE id = p_account_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active account.', 'accountId');
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT by_user_id INTO v_by FROM partner_engagement WHERE id = p_id AND partner_id = p_partner_id;
    IF v_by IS NULL THEN
      CALL spi_raise('NOT_FOUND', 'Engagement not found.', 'engagementId');
    END IF;
    IF v_by <> p_actor_user_id THEN
      CALL spi_partner_owner_check(p_actor_user_id, p_partner_id, p_allow_any);
    END IF;
  END IF;

  SELECT relationship_owner_user_id, COALESCE(short_name, legal_name) INTO v_owner, v_name
    FROM partner WHERE id = p_partner_id;

  START TRANSACTION;
  IF p_id IS NULL THEN
    INSERT INTO partner_engagement (partner_id, engagement_type, engagement_on, with_whom, by_user_id,
                                    notes, outcome, next_action, next_action_on, account_id, created_by)
    VALUES (p_partner_id, p_type, p_on, p_with_whom, p_actor_user_id,
            p_notes, p_outcome, p_next_action, p_next_on, p_account_id, p_actor_user_id);
    SET v_id = LAST_INSERT_ID();
  ELSE
    UPDATE partner_engagement
       SET engagement_type = p_type, engagement_on = p_on, with_whom = p_with_whom, notes = p_notes,
           outcome = p_outcome, next_action = p_next_action, next_action_on = p_next_on,
           account_id = IFNULL(p_account_id, account_id),
           updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
     WHERE id = p_id;
    SET v_id = p_id;
  END IF;

  -- the partner carries the latest engagement and the plan of the latest one that has a plan
  UPDATE partner p
     SET p.last_engagement_on = (SELECT MAX(engagement_on) FROM partner_engagement WHERE partner_id = p.id),
         p.next_engagement_on = IFNULL(p_next_on, p.next_engagement_on),
         p.next_engagement_plan = IF(p_next_on IS NULL, p.next_engagement_plan, p_next_action),
         p.updated_at = UTC_TIMESTAMP(3), p.updated_by = p_actor_user_id
   WHERE p.id = p_partner_id;

  -- BR-PT-05: one open "next engagement" task per partner, due 10:00 IST on the planned day
  IF p_next_on IS NOT NULL THEN
    INSERT INTO task (entity_type, entity_id, task_type, title, description, owner_user_id, due_at,
                      status, source_ref, created_by)
    VALUES ('PARTNER', p_partner_id, 'ENGAGEMENT', LEFT(CONCAT('Next engagement: ', v_name), 250),
            p_next_action, v_owner, TIMESTAMP(p_next_on, '04:30:00'), 'OPEN',
            CONCAT('ENG:', p_partner_id), p_actor_user_id)
    ON DUPLICATE KEY UPDATE title = LEFT(CONCAT('Next engagement: ', v_name), 250),
                            description = p_next_action, owner_user_id = v_owner,
                            due_at = TIMESTAMP(p_next_on, '04:30:00'),
                            status = 'OPEN', completed_at = NULL, completed_by = NULL,
                            reminder_sent_at = NULL,
                            updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id;
  END IF;

  CALL spi_partner_completeness(p_partner_id);
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('partner', p_partner_id, IF(p_id IS NULL, 'PARTNER_ENGAGEMENT_ADD', 'PARTNER_ENGAGEMENT_UPDATE'),
          JSON_OBJECT('engagementId', v_id, 'type', p_type, 'on', p_on, 'nextOn', p_next_on),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_account_map_save: p_id NULL = new; one row per account and period
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_account_map_save $$
CREATE PROCEDURE sp_partner_account_map_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_id            BIGINT UNSIGNED,
  IN p_account_id    BIGINT UNSIGNED,
  IN p_period        VARCHAR(10),
  IN p_status        VARCHAR(12),
  IN p_notes         VARCHAR(1000),
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_owner_check(p_actor_user_id, p_partner_id, p_allow_any);
  IF NOT EXISTS (SELECT 1 FROM account WHERE id = p_account_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active account.', 'accountId');
  END IF;
  IF p_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM partner_account_map WHERE id = p_id AND partner_id = p_partner_id) THEN
    CALL spi_raise('NOT_FOUND', 'Account map row not found.', 'rowId');
  END IF;
  IF EXISTS (SELECT 1 FROM partner_account_map
              WHERE partner_id = p_partner_id AND account_id = p_account_id AND plan_period = p_period
                AND (p_id IS NULL OR id <> p_id)) THEN
    CALL spi_raise('VALIDATION_FAILED', 'This account is already mapped for that period.', 'accountId');
  END IF;

  START TRANSACTION;
  IF p_id IS NULL THEN
    INSERT INTO partner_account_map (partner_id, account_id, plan_period, status, notes, created_by)
    VALUES (p_partner_id, p_account_id, p_period, p_status, p_notes, p_actor_user_id);
    SET v_id = LAST_INSERT_ID();
  ELSE
    UPDATE partner_account_map
       SET account_id = p_account_id, plan_period = p_period, status = p_status, notes = p_notes,
           updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
     WHERE id = p_id;
    SET v_id = p_id;
  END IF;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('partner', p_partner_id, IF(p_id IS NULL, 'PARTNER_ACCOUNT_MAP_ADD', 'PARTNER_ACCOUNT_MAP_UPDATE'),
          JSON_OBJECT('rowId', v_id, 'accountId', p_account_id, 'period', p_period, 'status', p_status),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id;
END $$

DROP PROCEDURE IF EXISTS sp_partner_account_map_delete $$
CREATE PROCEDURE sp_partner_account_map_delete(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_id            BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_period  VARCHAR(10);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_owner_check(p_actor_user_id, p_partner_id, p_allow_any);
  SELECT account_id, plan_period INTO v_account, v_period
    FROM partner_account_map WHERE id = p_id AND partner_id = p_partner_id;
  IF v_account IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Account map row not found.', 'rowId');
  END IF;

  START TRANSACTION;
  DELETE FROM partner_account_map WHERE id = p_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('partner', p_partner_id, 'PARTNER_ACCOUNT_MAP_REMOVE',
          JSON_OBJECT('rowId', p_id, 'accountId', v_account, 'period', v_period),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V031', 'Partner engagement log, next engagement task, account map', UTC_TIMESTAMP());
