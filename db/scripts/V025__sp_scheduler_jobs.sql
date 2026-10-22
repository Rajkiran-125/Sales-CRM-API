-- =============================================================================
-- V025  Sales CRM - scheduler (Phase 1 jobs)                          (2026-10-14)
--
--   sp_job_lock_acquire / _release   One runner per job (8.10, job_lock).
--   sp_job_run_start / _finish       job_run_log rows.
--   sp_job_last_success              Last successful start, for catch-up scheduling.
--   sp_job_settings                  Times the API scheduler needs (OD-16).
--   sp_job_weekly_status_tasks       Monday: a WEEKLY_STATUS task per open deal (12.18).
--   sp_job_monday_report             Rows of last week's status + the recipients.
--   sp_job_stale_deals               No activity and no status for deal.stale_days: STALE.
--   sp_job_close_date_slip           Expected close in the past: SLIPPED + CLOSE_DATE task;
--                                    a corrected date puts SLIPPED back to ON_TRACK.
--   sp_weekly_status_upsert          Re-issue of V015: also closes that week's task.
--
-- Times are IST (UTC+05:30, OD-28). System changes are audited with user_id NULL.
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V024.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

-- Email templates for the jobs (editable under Settings > Email templates)
INSERT IGNORE INTO email_template (code, name, subject, body_html, placeholders) VALUES
  ('WEEKLY_STATUS_REPORT', 'Monday weekly status report', 'Weekly status report, week of {{weekStart}}',
   '<p>Hello {{fullName}},</p><p>The weekly status report for the week of {{weekStart}} is attached.</p><p>Open deals: {{dealCount}}. Status submitted: {{submittedCount}}. Not submitted: {{pendingCount}}. At risk, slipped or stalled: {{riskCount}}.</p><p>Open {{appName}} for the details.</p>',
   JSON_ARRAY('appName','fullName','weekStart','dealCount','submittedCount','pendingCount','riskCount')),
  ('DEAL_STALE', 'Stale deal notice', 'Stale deal: {{opportunityNo}} {{title}}',
   '<p>Hello {{fullName}},</p><p>The deal {{opportunityNo}} {{title}} (owner {{ownerName}}) has had no activity and no weekly status for {{daysQuiet}} days, so it is now marked stale.</p><p>Please log an update in {{appName}} or mark the deal dormant.</p>',
   JSON_ARRAY('appName','fullName','opportunityNo','title','ownerName','daysQuiet'));

DELIMITER $$

-- ---------------------------------------------------------------------------
-- job lock and run log
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_job_lock_acquire $$
CREATE PROCEDURE sp_job_lock_acquire(IN p_job VARCHAR(60), IN p_holder VARCHAR(100), IN p_minutes INT)
  SQL SECURITY DEFINER
  COMMENT 'Take the job lock when free or expired; returns acquired 1/0'
BEGIN
  INSERT IGNORE INTO job_lock (job_name, locked_until, locked_by, updated_at)
  VALUES (p_job, NULL, NULL, UTC_TIMESTAMP(3));
  UPDATE job_lock
     SET locked_until = UTC_TIMESTAMP(3) + INTERVAL p_minutes MINUTE, locked_by = p_holder,
         updated_at = UTC_TIMESTAMP(3)
   WHERE job_name = p_job AND (locked_until IS NULL OR locked_until < UTC_TIMESTAMP(3));
  SELECT ROW_COUNT() AS acquired;
END $$

DROP PROCEDURE IF EXISTS sp_job_lock_release $$
CREATE PROCEDURE sp_job_lock_release(IN p_job VARCHAR(60), IN p_holder VARCHAR(100))
  SQL SECURITY DEFINER
BEGIN
  UPDATE job_lock SET locked_until = NULL, locked_by = NULL, updated_at = UTC_TIMESTAMP(3)
   WHERE job_name = p_job AND locked_by = p_holder;
END $$

DROP PROCEDURE IF EXISTS sp_job_run_start $$
CREATE PROCEDURE sp_job_run_start(IN p_job VARCHAR(60))
  SQL SECURITY DEFINER
BEGIN
  INSERT INTO job_run_log (job_name, started_at, status) VALUES (p_job, UTC_TIMESTAMP(3), 'RUNNING');
  SELECT LAST_INSERT_ID() AS id;
END $$

DROP PROCEDURE IF EXISTS sp_job_run_finish $$
CREATE PROCEDURE sp_job_run_finish(
  IN p_id     BIGINT UNSIGNED,
  IN p_status VARCHAR(10),
  IN p_count  INT UNSIGNED,
  IN p_error  VARCHAR(2000)
)
  SQL SECURITY DEFINER
BEGIN
  UPDATE job_run_log
     SET finished_at = UTC_TIMESTAMP(3), status = p_status, processed_count = p_count, error = p_error
   WHERE id = p_id;
END $$

DROP PROCEDURE IF EXISTS sp_job_last_success $$
CREATE PROCEDURE sp_job_last_success(IN p_job VARCHAR(60))
  SQL SECURITY DEFINER
BEGIN
  SELECT MAX(started_at) AS lastSuccessAt FROM job_run_log WHERE job_name = p_job AND status = 'SUCCESS';
END $$

DROP PROCEDURE IF EXISTS sp_job_settings $$
CREATE PROCEDURE sp_job_settings()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_report VARCHAR(1000);
  CALL spi_setting_text('report.monday.time', '09:00', v_report);
  SELECT v_report AS mondayReportTime;
END $$

-- ---------------------------------------------------------------------------
-- sp_job_weekly_status_tasks: one task per open deal for the week starting
-- p_week_start (a Monday), due on weekly_status.due_day at due_time IST.
-- De-duplicated by source_ref WS:<deal>:<week>, so a re-run creates nothing new.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_job_weekly_status_tasks $$
CREATE PROCEDURE sp_job_weekly_status_tasks(IN p_week_start DATE)
  SQL SECURITY DEFINER
  COMMENT 'Monday: weekly status tasks (12.18, UM 6.4)'
BEGIN
  DECLARE v_day  VARCHAR(1000);
  DECLARE v_time VARCHAR(1000);
  DECLARE v_due  DATETIME(3);

  IF WEEKDAY(p_week_start) <> 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'The week must start on a Monday.', 'weekStart');
  END IF;
  CALL spi_setting_text('weekly_status.due_day', 'FRIDAY', v_day);
  CALL spi_setting_text('weekly_status.due_time', '18:00', v_time);
  SET v_due = TIMESTAMP(p_week_start + INTERVAL (GREATEST(FIELD(v_day, 'MONDAY','TUESDAY','WEDNESDAY',
                'THURSDAY','FRIDAY','SATURDAY','SUNDAY'), 1) - 1) DAY, v_time) - INTERVAL 330 MINUTE;

  INSERT IGNORE INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref)
  SELECT 'OPP', o.id, 'WEEKLY_STATUS',
         LEFT(CONCAT('Weekly status: ', o.opportunity_no, ' · ', o.title), 250),
         o.owner_user_id, v_due, 'OPEN', CONCAT('WS:', o.id, ':', p_week_start)
    FROM opportunity o
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
   WHERE o.is_active = 1
     AND NOT EXISTS (SELECT 1 FROM weekly_status w WHERE w.opportunity_id = o.id AND w.week_start = p_week_start);

  SELECT ROW_COUNT() AS processed;
END $$

-- ---------------------------------------------------------------------------
-- sp_job_monday_report: every open deal with its status for the week starting
-- p_week_start (last week), and the recipients (active sales heads, OD-16 default)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_job_monday_report $$
CREATE PROCEDURE sp_job_monday_report(IN p_week_start DATE)
  SQL SECURITY DEFINER
  COMMENT 'Monday report rows and recipients (12.18, UM 8)'
BEGIN
  SELECT u.full_name AS ownerName, m.full_name AS managerName, o.opportunity_no AS opportunityNo,
         o.title, a.name AS accountName, s.name AS stageName, o.health,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS valueInr,
         CAST(o.weighted_value AS DECIMAL(18,2)) AS weightedInr, o.expected_close_date AS expectedCloseDate,
         w.status AS weekStatus, w.this_week AS thisWeek, w.next_step AS nextStep,
         w.submitted_at AS submittedAt
    FROM opportunity o
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN `user` m ON m.id = u.reporting_to_user_id
    LEFT JOIN account a ON a.id = o.account_id
    LEFT JOIN weekly_status w ON w.opportunity_id = o.id AND w.week_start = p_week_start
   WHERE o.is_active = 1
   ORDER BY u.full_name, w.status IS NULL DESC, o.expected_close_date;

  SELECT DISTINCT u.email, u.full_name AS fullName
    FROM `user` u
    JOIN user_role ur ON ur.user_id = u.id
    JOIN role r ON r.id = ur.role_id AND r.code = 'SALES_HEAD'
   WHERE u.status = 'ACTIVE';
END $$

-- ---------------------------------------------------------------------------
-- sp_job_stale_deals: open deals with no activity and no weekly status for
-- deal.stale_days (OD-50) become STALE (BR-OP-14); returns the newly flagged
-- deals with the owner and the manager to notify (once, on the transition).
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_job_stale_deals $$
CREATE PROCEDURE sp_job_stale_deals()
  SQL SECURITY DEFINER
  COMMENT 'Flag stale deals (12.18, BR-OP-14)'
BEGIN
  DECLARE v_days INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  CALL spi_setting_int('deal.stale_days', 60, v_days);

  DROP TEMPORARY TABLE IF EXISTS tmp_stale;
  CREATE TEMPORARY TABLE tmp_stale (id BIGINT UNSIGNED NOT NULL PRIMARY KEY, last_touch DATETIME(3) NULL);
  INSERT INTO tmp_stale (id, last_touch)
  SELECT o.id,
         GREATEST(o.created_at,
                  IFNULL((SELECT MAX(ac.activity_at) FROM activity ac
                           WHERE ac.is_active = 1 AND (ac.opportunity_id = o.id OR (ac.entity_type = 'OPP' AND ac.entity_id = o.id))),
                         o.created_at),
                  IFNULL((SELECT MAX(w.submitted_at) FROM weekly_status w WHERE w.opportunity_id = o.id), o.created_at))
    FROM opportunity o
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
   WHERE o.is_active = 1 AND o.health <> 'STALE';
  DELETE FROM tmp_stale WHERE last_touch >= UTC_TIMESTAMP(3) - INTERVAL v_days DAY;

  START TRANSACTION;
  UPDATE opportunity o JOIN tmp_stale t ON t.id = o.id SET o.health = 'STALE';
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  SELECT 'opportunity', t.id, 'HEALTH_STALE', JSON_OBJECT('staleDays', v_days), NULL, NULL, NULL FROM tmp_stale t;
  COMMIT;

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title,
         DATEDIFF(UTC_TIMESTAMP(), t.last_touch) AS daysQuiet,
         u.email AS ownerEmail, u.full_name AS ownerName,
         IF(m.status = 'ACTIVE', m.email, NULL) AS managerEmail, m.full_name AS managerName
    FROM tmp_stale t
    JOIN opportunity o ON o.id = t.id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN `user` m ON m.id = u.reporting_to_user_id
   ORDER BY o.id;
  DROP TEMPORARY TABLE IF EXISTS tmp_stale;
END $$

-- ---------------------------------------------------------------------------
-- sp_job_close_date_slip: open deals whose expected close date (IST) is past
-- become SLIPPED (unless STALE) and get one CLOSE_DATE task per slipped date;
-- SLIPPED deals with a corrected date go back to ON_TRACK.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_job_close_date_slip $$
CREATE PROCEDURE sp_job_close_date_slip()
  SQL SECURITY DEFINER
  COMMENT 'Close-date slip (12.18)'
BEGIN
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_slipped INT DEFAULT 0;
  DECLARE v_tasks   INT DEFAULT 0;
  DECLARE v_back    INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  DROP TEMPORARY TABLE IF EXISTS tmp_slip;
  CREATE TEMPORARY TABLE tmp_slip (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_slip (id)
  SELECT o.id FROM opportunity o
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
   WHERE o.is_active = 1 AND o.expected_close_date < v_today;

  START TRANSACTION;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  SELECT 'opportunity', o.id, 'HEALTH_SLIPPED', JSON_OBJECT('expectedCloseDate', o.expected_close_date), NULL, NULL, NULL
    FROM opportunity o JOIN tmp_slip t ON t.id = o.id WHERE o.health IN ('ON_TRACK', 'AT_RISK');
  UPDATE opportunity o JOIN tmp_slip t ON t.id = o.id SET o.health = 'SLIPPED'
   WHERE o.health IN ('ON_TRACK', 'AT_RISK');
  SET v_slipped = ROW_COUNT();

  INSERT IGNORE INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref)
  SELECT 'OPP', o.id, 'CLOSE_DATE',
         LEFT(CONCAT('Update the close date: ', o.opportunity_no, ' · ', o.title), 250),
         o.owner_user_id, TIMESTAMP(v_today, '18:00') - INTERVAL 330 MINUTE, 'OPEN',
         CONCAT('SLIP:', o.id, ':', o.expected_close_date)
    FROM opportunity o JOIN tmp_slip t ON t.id = o.id;
  SET v_tasks = ROW_COUNT();

  UPDATE opportunity o
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
     SET o.health = 'ON_TRACK'
   WHERE o.is_active = 1 AND o.health = 'SLIPPED' AND o.expected_close_date >= v_today;
  SET v_back = ROW_COUNT();
  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_slip;

  SELECT v_slipped AS slipped, v_tasks AS tasks, v_back AS recovered;
END $$

-- ---------------------------------------------------------------------------
-- sp_weekly_status_upsert: V015 + closes the scheduler's task for that week
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

  -- the scheduler's task for this deal and week is done (V025)
  UPDATE task
     SET status = 'DONE', completed_at = UTC_TIMESTAMP(3), completed_by = p_actor_user_id,
         updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE source_ref = CONCAT('WS:', p_opportunity_id, ':', p_week_start) AND status = 'OPEN';

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('weekly_status', v_row_id, v_action, NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT v_row_id AS id;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V025', 'Scheduler: job lock/log, weekly status tasks, Monday report, stale, close-date slip', UTC_TIMESTAMP());
