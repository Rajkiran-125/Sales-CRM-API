-- =============================================================================
-- V015  Sales CRM - weekly status, write side                         (2026-10-13)
--
--   sp_weekly_status_upsert   Submit or update a weekly status entry.
--                             One row per (opportunity_id, week_start). The
--                             week_start supplied must be the Monday of the
--                             target week (enforced by the table CHECK).
--                             Permission: forecast.submit_own.
--                             ALL-scope users may submit on behalf of any deal.
--
--   sp_weekly_status_delete   Remove a status entry (own or any for ALL-scope).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V014.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_weekly_status_upsert
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_weekly_status_upsert $$
CREATE PROCEDURE sp_weekly_status_upsert(
  IN p_actor_user_id      BIGINT UNSIGNED,
  IN p_request_id         VARCHAR(36),
  IN p_ip                 VARCHAR(45),
  IN p_opportunity_id     BIGINT UNSIGNED,
  IN p_week_start         DATE,            -- must be a Monday
  IN p_status             VARCHAR(10),
  IN p_this_week          VARCHAR(2000),
  IN p_next_step          VARCHAR(1000),
  IN p_expected_close_date DATE,           -- NULL = unchanged from deal
  IN p_close_change_reason VARCHAR(1000),
  IN p_expected_value     DECIMAL(16,2),   -- NULL = unchanged from deal
  IN p_allow_any          TINYINT(1)       -- 1 for ALL-scope users
)
BEGIN
  DECLARE v_opp_owner     BIGINT UNSIGNED;
  DECLARE v_stage_code    VARCHAR(20);
  DECLARE v_row_id        BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_action        VARCHAR(20);

  -- validate week_start is a Monday
  IF WEEKDAY(p_week_start) <> 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|weekStart|Must be a Monday.';
  END IF;

  IF p_status NOT IN ('ON_TRACK','AT_RISK','SLIPPED','STALLED') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|status|Invalid status.';
  END IF;

  -- verify opportunity exists and get owner + stage snapshot
  SELECT owner_user_id, stage_code
    INTO v_opp_owner, v_stage_code
    FROM opportunity
   WHERE id = p_opportunity_id AND is_active = 1
   LIMIT 1;

  IF v_opp_owner IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|opportunityId|Opportunity not found.';
  END IF;

  IF p_allow_any = 0 AND v_opp_owner <> p_actor_user_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN|opportunityId|You can only submit status for your own deals.';
  END IF;

  -- check if a row already exists for this week
  SELECT id INTO v_row_id
    FROM weekly_status
   WHERE opportunity_id = p_opportunity_id AND week_start = p_week_start
   LIMIT 1;

  IF v_row_id IS NULL THEN
    SET v_action = 'WEEKLY_STATUS_CREATE';
    INSERT INTO weekly_status (
      opportunity_id, week_start, status, this_week, next_step,
      expected_close_date, close_change_reason, expected_value, stage_code,
      submitted_by, submitted_at, source,
      created_at, created_by
    ) VALUES (
      p_opportunity_id, p_week_start, p_status, p_this_week, p_next_step,
      p_expected_close_date, p_close_change_reason, p_expected_value, v_stage_code,
      p_actor_user_id, UTC_TIMESTAMP(3), 'INTERNAL',
      UTC_TIMESTAMP(3), p_actor_user_id
    );
    SET v_row_id = LAST_INSERT_ID();
  ELSE
    SET v_action = 'WEEKLY_STATUS_UPDATE';
    UPDATE weekly_status SET
      status               = p_status,
      this_week            = p_this_week,
      next_step            = p_next_step,
      expected_close_date  = p_expected_close_date,
      close_change_reason  = p_close_change_reason,
      expected_value       = p_expected_value,
      stage_code           = v_stage_code,
      submitted_by         = p_actor_user_id,
      submitted_at         = UTC_TIMESTAMP(3),
      updated_at           = UTC_TIMESTAMP(3),
      updated_by           = p_actor_user_id
    WHERE id = v_row_id;
  END IF;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('weekly_status', v_row_id, v_action, NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT v_row_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_weekly_status_delete
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_weekly_status_delete $$
CREATE PROCEDURE sp_weekly_status_delete(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_id             BIGINT UNSIGNED,
  IN p_allow_any      TINYINT(1)
)
BEGIN
  DECLARE v_owner BIGINT UNSIGNED;
  DECLARE v_exists TINYINT DEFAULT 0;

  SELECT 1, submitted_by INTO v_exists, v_owner FROM weekly_status WHERE id = p_id LIMIT 1;

  IF v_exists = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|id|Weekly status not found.';
  END IF;

  -- v_owner may be NULL when submitted_by was not recorded; treat as unowned → only ALL-scope may delete
  IF p_allow_any = 0 AND (v_owner IS NULL OR v_owner <> p_actor_user_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN|id|You can only delete your own status entries.';
  END IF;

  DELETE FROM weekly_status WHERE id = p_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('weekly_status', p_id, 'WEEKLY_STATUS_DELETE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT p_id AS id;
END $$

DELIMITER ;
