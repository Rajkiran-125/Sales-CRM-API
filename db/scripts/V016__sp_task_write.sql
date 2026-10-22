-- =============================================================================
-- V016  Sales CRM - tasks, write side                                 (2026-10-13)
--
--   sp_task_create   Manually create a task (task_type = CUSTOM).
--                    entity_type / entity_id are optional; owner defaults to
--                    the actor when not supplied.
--
--   sp_task_update   Complete, cancel, reschedule or edit a task.
--                    Only the task owner may edit; ALL-scope actors may edit any.
--                    Sets completed_at / completed_by when status → DONE.
--                    Clears those columns when status → OPEN or CANCELLED.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V015.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_task_create
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_task_create $$
CREATE PROCEDURE sp_task_create(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_entity_type    VARCHAR(10),     -- nullable (LEAD|OPP|ACCOUNT|…)
  IN p_entity_id      BIGINT UNSIGNED, -- nullable
  IN p_title          VARCHAR(250),
  IN p_description    VARCHAR(1000),   -- nullable
  IN p_owner_user_id  BIGINT UNSIGNED, -- nullable → defaults to actor
  IN p_due_at         DATETIME(3)
)
BEGIN
  DECLARE v_task_id    BIGINT UNSIGNED;
  DECLARE v_owner      BIGINT UNSIGNED;

  -- ---- validate entity type when supplied ----
  IF p_entity_type IS NOT NULL AND
     p_entity_type NOT IN ('LEAD','OPP','ACCOUNT','PARTNER','TENDER','ORDER') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|entityType|Invalid entity type.';
  END IF;

  IF p_entity_type IS NOT NULL AND p_entity_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|entityId|Required when entity type is set.';
  END IF;

  -- ---- resolve owner ----
  SET v_owner = COALESCE(p_owner_user_id, p_actor_user_id);

  IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = v_owner AND status = 'ACTIVE') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|ownerUserId|User not found.';
  END IF;

  -- ---- insert ----
  INSERT INTO task (
    entity_type, entity_id, task_type, title, description,
    owner_user_id, due_at, status,
    created_at, created_by
  ) VALUES (
    p_entity_type, p_entity_id, 'CUSTOM', p_title, p_description,
    v_owner, p_due_at, 'OPEN',
    UTC_TIMESTAMP(3), p_actor_user_id
  );
  SET v_task_id = LAST_INSERT_ID();

  -- ---- audit ----
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('task', v_task_id, 'TASK_CREATE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT v_task_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_task_update
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_task_update $$
CREATE PROCEDURE sp_task_update(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_task_id        BIGINT UNSIGNED,
  IN p_title          VARCHAR(250),
  IN p_description    VARCHAR(1000),   -- nullable
  IN p_due_at         DATETIME(3),
  IN p_owner_user_id  BIGINT UNSIGNED,
  IN p_status         VARCHAR(10),     -- OPEN | DONE | CANCELLED
  IN p_allow_any      TINYINT(1)
)
BEGIN
  DECLARE v_owner BIGINT UNSIGNED;

  SELECT owner_user_id INTO v_owner FROM task WHERE id = p_task_id;
  IF v_owner IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|id|Task not found.';
  END IF;

  IF p_allow_any = 0 AND v_owner <> p_actor_user_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN|id|You can only edit your own tasks.';
  END IF;

  IF p_status NOT IN ('OPEN','DONE','CANCELLED') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|status|Invalid status.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_owner_user_id AND status = 'ACTIVE') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|ownerUserId|User not found.';
  END IF;

  UPDATE task SET
    title          = p_title,
    description    = p_description,
    due_at         = p_due_at,
    owner_user_id  = p_owner_user_id,
    status         = p_status,
    completed_at   = CASE WHEN p_status = 'DONE' THEN UTC_TIMESTAMP(3) ELSE NULL END,
    completed_by   = CASE WHEN p_status = 'DONE' THEN p_actor_user_id  ELSE NULL END,
    updated_at     = UTC_TIMESTAMP(3),
    updated_by     = p_actor_user_id
  WHERE id = p_task_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('task', p_task_id, 'TASK_UPDATE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT p_task_id AS id;
END $$

DELIMITER ;
