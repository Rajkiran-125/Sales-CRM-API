-- =============================================================================
-- V038  Sales CRM - monthly closure commits and team nudges             (2026-10-15)
--
--   sp_monthly_commit_save   PUT /forecast/monthly: per deal this month COMMIT (committed),
--                            UPSIDE (best case) or NEXT_MONTH (forecast) with its value;
--                            no type removes the commit (BR-FC-03, BR-FC-05). Own deals or the
--                            team's (owner in the actor's tree), or ALL scope. Past months are
--                            closed; achieved is marked by the month-end job.
--   sp_forecast_nudge        POST /forecast/nudges: every member of the actor's team (not the
--                            actor) with open deals still without this week's status gets one
--                            task listing how many (12.10 "nudge"); one task per person and
--                            week, a second nudge moves its due time.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V037.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_monthly_commit_save $$
CREATE PROCEDURE sp_monthly_commit_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_month         DATE,              -- first day of the month
  IN p_items         JSON,              -- [{opportunityId, commitType|null, commitValue}]
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_bad   INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF DAY(p_month) <> 1 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Use the first day of the month.', 'month');
  END IF;
  IF p_month < v_today - INTERVAL (DAY(v_today) - 1) DAY THEN
    CALL spi_raise('VALIDATION_FAILED', 'A past month is closed.', 'month');
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_mc;
  CREATE TEMPORARY TABLE tmp_mc AS
  SELECT j.opp_id, j.ctype, j.cvalue
    FROM JSON_TABLE(p_items, '$[*]' COLUMNS (
           opp_id BIGINT UNSIGNED PATH '$.opportunityId',
           ctype  VARCHAR(10)     PATH '$.commitType',
           cvalue DECIMAL(16,2)   PATH '$.commitValue')) j;

  -- every deal must exist, be open or won this month, and be the actor's or the team's
  SELECT COUNT(*) INTO v_bad
    FROM tmp_mc t
    LEFT JOIN opportunity o ON o.id = t.opp_id AND o.is_active = 1
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE o.id IS NULL
      OR NOT (s.is_open = 1 OR o.stage_code = 'WON')
      OR (p_allow_any = 0 AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
            WHERE h.ancestor_user_id = p_actor_user_id AND h.descendant_user_id = o.owner_user_id));
  IF v_bad > 0 THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_mc;
    CALL spi_raise('FORBIDDEN', 'You can only commit open deals of yours or of your team.', 'items');
  END IF;
  IF EXISTS (SELECT 1 FROM tmp_mc WHERE ctype IS NOT NULL
               AND (ctype NOT IN ('COMMIT', 'UPSIDE', 'NEXT_MONTH') OR cvalue IS NULL OR cvalue <= 0)) THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_mc;
    CALL spi_raise('VALIDATION_FAILED', 'Each commit needs a type and a value above zero.', 'items');
  END IF;

  START TRANSACTION;
  DELETE mc FROM monthly_commit mc JOIN tmp_mc t ON t.opp_id = mc.opportunity_id
   WHERE mc.commit_month = p_month AND t.ctype IS NULL;
  INSERT INTO monthly_commit (opportunity_id, commit_month, commit_type, commit_value, committed_by, created_by)
  SELECT t.opp_id, p_month, t.ctype, t.cvalue, p_actor_user_id, p_actor_user_id
    FROM tmp_mc t WHERE t.ctype IS NOT NULL
  ON DUPLICATE KEY UPDATE commit_type = t.ctype, commit_value = t.cvalue, committed_by = p_actor_user_id,
                          committed_at = UTC_TIMESTAMP(3), updated_at = UTC_TIMESTAMP(3),
                          updated_by = p_actor_user_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  SELECT 'opportunity', t.opp_id, 'MONTHLY_COMMIT',
         JSON_OBJECT('month', p_month, 'type', t.ctype, 'value', t.cvalue),
         p_actor_user_id, p_ip, p_request_id
    FROM tmp_mc t;
  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_mc;

  SELECT COUNT(*) AS committed FROM monthly_commit WHERE commit_month = p_month AND committed_by = p_actor_user_id;
END $$

DROP PROCEDURE IF EXISTS sp_forecast_nudge $$
CREATE PROCEDURE sp_forecast_nudge(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_week_start    DATE               -- the Monday
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_count INT;
  DECLARE v_due   DATETIME(3) DEFAULT UTC_TIMESTAMP(3) + INTERVAL 1 DAY;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF WEEKDAY(p_week_start) <> 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'The week must start on a Monday.', 'weekStart');
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_nudge;
  CREATE TEMPORARY TABLE tmp_nudge AS
  SELECT o.owner_user_id AS user_id, COUNT(*) AS pending
    FROM opportunity o
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
    JOIN user_hierarchy h ON h.ancestor_user_id = p_actor_user_id AND h.descendant_user_id = o.owner_user_id
   WHERE o.is_active = 1 AND o.owner_user_id <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM weekly_status w WHERE w.opportunity_id = o.id AND w.week_start = p_week_start)
   GROUP BY o.owner_user_id;
  SELECT COUNT(*) INTO v_count FROM tmp_nudge;

  START TRANSACTION;
  INSERT INTO task (task_type, title, description, owner_user_id, due_at, status, source_ref, created_by)
  SELECT 'FOLLOW_UP', LEFT(CONCAT('Weekly status: ', n.pending, ' deal(s) to update'), 250),
         CONCAT('Your manager asked for the weekly status of the week of ', DATE_FORMAT(p_week_start, '%d %b %Y'), '.'),
         n.user_id, v_due, 'OPEN', CONCAT('NUDGE:', n.user_id, ':', p_week_start), p_actor_user_id
    FROM tmp_nudge n
  ON DUPLICATE KEY UPDATE title = LEFT(CONCAT('Weekly status: ', n.pending, ' deal(s) to update'), 250),
                          due_at = v_due, status = 'OPEN', completed_at = NULL, completed_by = NULL,
                          updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  SELECT 'user', n.user_id, 'FORECAST_NUDGE', JSON_OBJECT('weekStart', p_week_start, 'pending', n.pending),
         p_actor_user_id, p_ip, p_request_id
    FROM tmp_nudge n;
  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_nudge;

  SELECT v_count AS nudged;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V038', 'Monthly closure commits and forecast nudges', UTC_TIMESTAMP());
