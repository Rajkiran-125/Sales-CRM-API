-- =============================================================================
-- V014  Sales CRM - activities, write side                             (2026-10-13)
--
--   sp_activity_create   Log a new activity (call, meeting, email, visit, CEC
--                        visit, demo, negotiation, note, intel note) on any
--                        supported entity. Optionally creates a follow-up task
--                        when next_action + next_action_on are supplied.
--                        Side-effects:
--                          * Moves a NEW lead to CONTACTED on first activity.
--                          * Clears STALE health_status on the opportunity.
--
--   sp_activity_update   Edit an activity the actor logged (update_own). Only
--                        the actor or an admin (ALL scope) may edit.
--
--   sp_activity_delete   Soft-delete (is_active = 0). Same ownership rule.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V013.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_activity_create
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_activity_create $$
CREATE PROCEDURE sp_activity_create(
  IN p_actor_user_id       BIGINT UNSIGNED,
  IN p_request_id          VARCHAR(36),
  IN p_ip                  VARCHAR(45),
  IN p_entity_type         VARCHAR(10),   -- LEAD | OPP | ACCOUNT | PARTNER | TENDER | ORDER
  IN p_entity_id           BIGINT UNSIGNED,
  IN p_activity_type       VARCHAR(12),
  IN p_activity_at         DATETIME(3),
  IN p_subject             VARCHAR(250),
  IN p_people_met          VARCHAR(500),
  IN p_notes               TEXT,
  IN p_outcome             VARCHAR(1000),
  IN p_next_action         VARCHAR(500),
  IN p_next_action_on      DATE,
  IN p_next_action_owner   BIGINT UNSIGNED,
  IN p_contact_ids         JSON           -- array of contact id ints, may be NULL
)
BEGIN
  DECLARE v_activity_id   BIGINT UNSIGNED;
  DECLARE v_lead_id       BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_opp_id        BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_account_id    BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_partner_id    BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_lead_stage    VARCHAR(12);
  DECLARE v_task_ref      VARCHAR(120);

  -- ---- validate entity type ----
  IF p_entity_type NOT IN ('LEAD','OPP','ACCOUNT','PARTNER','TENDER','ORDER') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|entityType|Invalid entity type.';
  END IF;

  IF p_activity_type NOT IN ('CALL','MEETING','EMAIL','VISIT','CEC_VISIT','DEMO','NEGOTIATION','NOTE','INTEL') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|activityType|Invalid activity type.';
  END IF;

  IF p_next_action IS NOT NULL AND p_next_action_on IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|nextActionOn|Required when next action is set.';
  END IF;

  -- ---- verify entity exists and resolve denorm FKs ----
  IF p_entity_type = 'LEAD' THEN
    SELECT id INTO v_lead_id FROM sales_lead WHERE id = p_entity_id AND is_active = 1 LIMIT 1;
    IF v_lead_id IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|entityId|Lead not found.';
    END IF;
    SELECT account_id INTO v_account_id FROM sales_lead WHERE id = p_entity_id;
    -- side-effect: NEW → CONTACTED
    SELECT stage_code INTO v_lead_stage FROM sales_lead WHERE id = p_entity_id;
    IF v_lead_stage = 'NEW' THEN
      UPDATE sales_lead SET stage_code = 'CONTACTED', updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id WHERE id = p_entity_id;
    END IF;
  ELSEIF p_entity_type = 'OPP' THEN
    SELECT id, account_id INTO v_opp_id, v_account_id FROM opportunity WHERE id = p_entity_id AND is_active = 1 LIMIT 1;
    IF v_opp_id IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|entityId|Opportunity not found.';
    END IF;
    -- side-effect: clear STALE health
    UPDATE opportunity
      SET health = 'ON_TRACK', updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
    WHERE id = p_entity_id AND health = 'STALE';
  ELSEIF p_entity_type = 'ACCOUNT' THEN
    IF NOT EXISTS (SELECT 1 FROM account WHERE id = p_entity_id AND is_active = 1) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|entityId|Account not found.';
    END IF;
    SET v_account_id = p_entity_id;
  ELSEIF p_entity_type = 'PARTNER' THEN
    IF NOT EXISTS (SELECT 1 FROM partner WHERE id = p_entity_id AND is_active = 1) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|entityId|Partner not found.';
    END IF;
    SET v_partner_id = p_entity_id;
  ELSEIF p_entity_type = 'TENDER' THEN
    IF NOT EXISTS (SELECT 1 FROM tender WHERE id = p_entity_id) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|entityId|Tender not found.';
    END IF;
  ELSEIF p_entity_type = 'ORDER' THEN
    IF NOT EXISTS (SELECT 1 FROM sales_order WHERE id = p_entity_id) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|entityId|Order not found.';
    END IF;
  END IF;

  -- ---- insert activity ----
  INSERT INTO activity (
    entity_type, entity_id, lead_id, opportunity_id, account_id, partner_id,
    activity_type, activity_at, subject, people_met, notes, outcome,
    next_action, next_action_on, next_action_owner_id,
    by_user_id, created_at, created_by
  ) VALUES (
    p_entity_type, p_entity_id, v_lead_id, v_opp_id, v_account_id, v_partner_id,
    p_activity_type, p_activity_at, p_subject, p_people_met, p_notes, p_outcome,
    p_next_action, p_next_action_on, p_next_action_owner,
    p_actor_user_id, UTC_TIMESTAMP(3), p_actor_user_id
  );
  SET v_activity_id = LAST_INSERT_ID();

  -- ---- link contacts ----
  IF p_contact_ids IS NOT NULL AND JSON_LENGTH(p_contact_ids) > 0 THEN
    INSERT IGNORE INTO activity_contact (activity_id, contact_id)
    SELECT v_activity_id, CAST(jt.id AS UNSIGNED)
    FROM JSON_TABLE(p_contact_ids, '$[*]' COLUMNS (id BIGINT PATH '$')) AS jt
    WHERE EXISTS (SELECT 1 FROM contact WHERE id = CAST(jt.id AS UNSIGNED));
  END IF;

  -- ---- create follow-up task if next action given ----
  IF p_next_action IS NOT NULL THEN
    SET v_task_ref = CONCAT('activity-', v_activity_id, '-followup');
    INSERT IGNORE INTO task (
      entity_type, entity_id, task_type, title,
      owner_user_id, due_at, status, source_ref,
      created_at, created_by
    ) VALUES (
      p_entity_type, p_entity_id, 'FOLLOW_UP', p_next_action,
      COALESCE(p_next_action_owner, p_actor_user_id),
      CONCAT(p_next_action_on, ' 09:00:00'), 'OPEN', v_task_ref,
      UTC_TIMESTAMP(3), p_actor_user_id
    );
  END IF;

  -- ---- audit ----
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('activity', v_activity_id, 'ACTIVITY_CREATE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT v_activity_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_activity_update
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_activity_update $$
CREATE PROCEDURE sp_activity_update(
  IN p_actor_user_id    BIGINT UNSIGNED,
  IN p_request_id       VARCHAR(36),
  IN p_ip               VARCHAR(45),
  IN p_activity_id      BIGINT UNSIGNED,
  IN p_activity_type    VARCHAR(12),
  IN p_activity_at      DATETIME(3),
  IN p_subject          VARCHAR(250),
  IN p_people_met       VARCHAR(500),
  IN p_notes            TEXT,
  IN p_outcome          VARCHAR(1000),
  IN p_next_action      VARCHAR(500),
  IN p_next_action_on   DATE,
  IN p_next_action_owner BIGINT UNSIGNED,
  IN p_contact_ids      JSON,
  IN p_allow_any        TINYINT(1)     -- 1 when actor has ALL scope (admin / head)
)
BEGIN
  DECLARE v_owner BIGINT UNSIGNED;

  SELECT by_user_id INTO v_owner FROM activity WHERE id = p_activity_id AND is_active = 1;
  IF v_owner IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|id|Activity not found.';
  END IF;

  IF p_allow_any = 0 AND v_owner <> p_actor_user_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN|id|You can only edit your own activities.';
  END IF;

  IF p_activity_type NOT IN ('CALL','MEETING','EMAIL','VISIT','CEC_VISIT','DEMO','NEGOTIATION','NOTE','INTEL') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|activityType|Invalid activity type.';
  END IF;

  IF p_next_action IS NOT NULL AND p_next_action_on IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|nextActionOn|Required when next action is set.';
  END IF;

  UPDATE activity SET
    activity_type         = p_activity_type,
    activity_at           = p_activity_at,
    subject               = p_subject,
    people_met            = p_people_met,
    notes                 = p_notes,
    outcome               = p_outcome,
    next_action           = p_next_action,
    next_action_on        = p_next_action_on,
    next_action_owner_id  = p_next_action_owner,
    updated_at            = UTC_TIMESTAMP(3),
    updated_by            = p_actor_user_id
  WHERE id = p_activity_id;

  -- replace contact links
  IF p_contact_ids IS NOT NULL THEN
    DELETE FROM activity_contact WHERE activity_id = p_activity_id;
    IF JSON_LENGTH(p_contact_ids) > 0 THEN
      INSERT IGNORE INTO activity_contact (activity_id, contact_id)
      SELECT p_activity_id, CAST(jt.id AS UNSIGNED)
      FROM JSON_TABLE(p_contact_ids, '$[*]' COLUMNS (id BIGINT PATH '$')) AS jt
      WHERE EXISTS (SELECT 1 FROM contact WHERE id = CAST(jt.id AS UNSIGNED));
    END IF;
  END IF;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('activity', p_activity_id, 'ACTIVITY_UPDATE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT p_activity_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_activity_delete
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_activity_delete $$
CREATE PROCEDURE sp_activity_delete(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_activity_id    BIGINT UNSIGNED,
  IN p_allow_any      TINYINT(1)
)
BEGIN
  DECLARE v_owner BIGINT UNSIGNED;

  SELECT by_user_id INTO v_owner FROM activity WHERE id = p_activity_id AND is_active = 1;
  IF v_owner IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|id|Activity not found.';
  END IF;

  IF p_allow_any = 0 AND v_owner <> p_actor_user_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN|id|You can only delete your own activities.';
  END IF;

  UPDATE activity SET
    is_active  = 0,
    updated_at = UTC_TIMESTAMP(3),
    updated_by = p_actor_user_id
  WHERE id = p_activity_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('activity', p_activity_id, 'ACTIVITY_DELETE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT p_activity_id AS id;
END $$

DELIMITER ;
