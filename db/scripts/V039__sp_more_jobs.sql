-- =============================================================================
-- V039  Sales CRM - remaining scheduler jobs (12.18)                    (2026-10-15)
--
--   sp_job_weekly_status_reminder  due day 09:00 IST: owners with this week's WEEKLY_STATUS
--                                  tasks still open get one reminder email (12.18 "reminder
--                                  before the due time").
--   sp_job_monthly_close           1st of the month: last month's commits marked achieved (won
--                                  in that month) and one MONTHLY_COMMIT task per owner with open
--                                  deals, due the 5th 18:00 IST (BR-FC-03).
--   sp_job_wake_up                 daily: DORMANT deals whose wake-up date has come get a WAKE_UP
--                                  task (and an email) once per wake-up date.
--   sp_job_invoice_due             daily: unpaid invoices past due become OVERDUE; invoices due
--                                  within 3 days or overdue get one INVOICE_DUE task for the
--                                  deal owner.
--   sp_job_engagement_reminder     daily: the next-engagement task (V031) of today gets one
--                                  reminder email to the relationship owner.
--   sp_job_stage_ageing            Monday: per manager, the team's open deals longer in their
--                                  stage than its SLA (OD-47) for the weekly digest email.
--   sp_job_housekeeping            daily: expired reset / invite tokens, refresh tokens and login
--                                  attempts older than the retention (30 / 30 / 90 days).
-- Offer validity needs no job: sending an offer schedules its OFFER_EXPIRY task (V018).
--
-- Re-runnable (DROP + CREATE; templates INSERT IGNORE). Prerequisite: V001-V038.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

INSERT IGNORE INTO email_template (code, name, subject, body_html, placeholders) VALUES
  ('WEEKLY_STATUS_REMINDER', 'Weekly status reminder', 'Weekly status due: {{pendingCount}} deal(s)',
   '<p>Hello {{fullName}},</p><p>The weekly status of {{pendingCount}} of your deals is still to be submitted for the week of {{weekStart}}. It is due today.</p><p>Open My day in {{appName}} to submit it.</p>',
   JSON_ARRAY('appName','fullName','pendingCount','weekStart')),
  ('DEAL_WAKE_UP', 'Dormant deal wake-up', 'Time to wake up {{opportunityNo}}',
   '<p>Hello {{fullName}},</p><p>The dormant deal {{opportunityNo}} · {{title}} reached its wake-up date. Review it and reopen or update it in {{appName}}.</p>',
   JSON_ARRAY('appName','fullName','opportunityNo','title')),
  ('ENGAGEMENT_REMINDER', 'Partner engagement reminder', 'Planned today: {{partnerName}}',
   '<p>Hello {{fullName}},</p><p>Your next engagement with {{partnerName}} is planned for today: {{plan}}.</p><p>Log it in {{appName}} when it is done.</p>',
   JSON_ARRAY('appName','fullName','partnerName','plan')),
  ('STAGE_AGEING_DIGEST', 'Stage ageing digest', '{{dealCount}} deal(s) over their stage time',
   '<p>Hello {{fullName}},</p><p>{{dealCount}} deal(s) of your team have stayed in their stage longer than its time limit: {{deals}}.</p><p>Open {{appName}} to help move them on.</p>',
   JSON_ARRAY('appName','fullName','dealCount','deals'));

DELIMITER $$

-- re-issue of V025: also the weekly status due day, for the reminder
DROP PROCEDURE IF EXISTS sp_job_settings $$
CREATE PROCEDURE sp_job_settings()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_report VARCHAR(1000);
  DECLARE v_due    VARCHAR(1000);
  CALL spi_setting_text('report.monday.time', '09:00', v_report);
  CALL spi_setting_text('weekly_status.due_day', 'FRIDAY', v_due);
  SELECT v_report AS mondayReportTime, v_due AS weeklyStatusDueDay;
END $$

DROP PROCEDURE IF EXISTS sp_job_weekly_status_reminder $$
CREATE PROCEDURE sp_job_weekly_status_reminder()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_week  DATE;
  SET v_week = v_today - INTERVAL WEEKDAY(v_today) DAY;

  DROP TEMPORARY TABLE IF EXISTS tmp_ws;
  CREATE TEMPORARY TABLE tmp_ws AS
  SELECT t.id, t.owner_user_id FROM task t
   WHERE t.task_type = 'WEEKLY_STATUS' AND t.status = 'OPEN' AND t.reminder_sent_at IS NULL
     AND t.source_ref LIKE CONCAT('WS:%:', v_week);
  UPDATE task t JOIN tmp_ws w ON w.id = t.id SET t.reminder_sent_at = UTC_TIMESTAMP(3);

  SELECT u.email, u.full_name AS fullName, COUNT(*) AS pendingCount, v_week AS weekStart
    FROM tmp_ws w JOIN `user` u ON u.id = w.owner_user_id AND u.status = 'ACTIVE'
   GROUP BY u.id, u.email, u.full_name;
  DROP TEMPORARY TABLE IF EXISTS tmp_ws;
END $$

DROP PROCEDURE IF EXISTS sp_job_monthly_close $$
CREATE PROCEDURE sp_job_monthly_close()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_month DATE;
  DECLARE v_prev  DATE;
  DECLARE v_marked INT;
  SET v_month = v_today - INTERVAL (DAY(v_today) - 1) DAY;
  SET v_prev = v_month - INTERVAL 1 MONTH;

  -- month end: achieved = the deal was won in that month
  UPDATE monthly_commit mc JOIN opportunity o ON o.id = mc.opportunity_id
     SET mc.achieved = (o.stage_code = 'WON'
                        AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_prev AND LAST_DAY(v_prev)),
         mc.updated_at = UTC_TIMESTAMP(3)
   WHERE mc.commit_month = v_prev AND mc.achieved IS NULL;
  SET v_marked = ROW_COUNT();

  -- 1st of the month: one commit task per owner with open deals, due the 5th 18:00 IST
  INSERT IGNORE INTO task (task_type, title, description, owner_user_id, due_at, status, source_ref)
  SELECT 'MONTHLY_COMMIT', CONCAT('Monthly closure commit for ', DATE_FORMAT(v_month, '%b %Y')),
         'Commit this month''s deals, the next-month forecast and the best case (Forecast, Monthly closure).',
         o.owner_user_id, TIMESTAMP(v_month + INTERVAL 4 DAY, '12:30:00'), 'OPEN',
         CONCAT('MC:', o.owner_user_id, ':', DATE_FORMAT(v_month, '%Y-%m'))
    FROM opportunity o
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
    JOIN `user` u ON u.id = o.owner_user_id AND u.status = 'ACTIVE'
   WHERE o.is_active = 1
   GROUP BY o.owner_user_id;

  SELECT v_marked AS achievedMarked, ROW_COUNT() AS tasks;
END $$

DROP PROCEDURE IF EXISTS sp_job_wake_up $$
CREATE PROCEDURE sp_job_wake_up()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  DROP TEMPORARY TABLE IF EXISTS tmp_wake;
  CREATE TEMPORARY TABLE tmp_wake AS
  SELECT o.id, o.owner_user_id, o.opportunity_no, o.title, CONCAT('WAKE:', o.id, ':', o.wake_up_date) AS ref
    FROM opportunity o
   WHERE o.is_active = 1 AND o.stage_code = 'DORMANT' AND o.wake_up_date IS NOT NULL
     AND o.wake_up_date <= v_today
     AND NOT EXISTS (SELECT 1 FROM task t WHERE t.source_ref = CONCAT('WAKE:', o.id, ':', o.wake_up_date));
  INSERT IGNORE INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref)
  SELECT 'OPP', w.id, 'WAKE_UP', LEFT(CONCAT('Wake up ', w.opportunity_no, ' · ', w.title), 250),
         w.owner_user_id, UTC_TIMESTAMP(3), 'OPEN', w.ref
    FROM tmp_wake w;

  SELECT w.id, w.opportunity_no AS opportunityNo, w.title, u.email, u.full_name AS fullName
    FROM tmp_wake w JOIN `user` u ON u.id = w.owner_user_id AND u.status = 'ACTIVE';
  DROP TEMPORARY TABLE IF EXISTS tmp_wake;
END $$

DROP PROCEDURE IF EXISTS sp_job_invoice_due $$
CREATE PROCEDURE sp_job_invoice_due()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_overdue INT;

  UPDATE invoice SET status = 'OVERDUE', updated_at = UTC_TIMESTAMP(3)
   WHERE status IN ('OPEN', 'PART_PAID') AND due_date < v_today;
  SET v_overdue = ROW_COUNT();

  INSERT IGNORE INTO task (entity_type, entity_id, task_type, title, description, owner_user_id, due_at,
                           status, source_ref)
  SELECT 'INVOICE', i.id, 'INVOICE_DUE',
         LEFT(CONCAT(IF(i.due_date < v_today, 'Overdue: ', 'Due soon: '), 'invoice ', i.invoice_no,
                     ' · ', a.name), 250),
         CONCAT('Due ', DATE_FORMAT(i.due_date, '%d %b %Y'), '; follow up the payment with the customer.'),
         o.owner_user_id, TIMESTAMP(GREATEST(i.due_date, v_today), '04:30:00'), 'OPEN', CONCAT('INV:', i.id)
    FROM invoice i
    JOIN sales_order so ON so.id = i.order_id
    JOIN opportunity o ON o.id = so.opportunity_id
    JOIN account a ON a.id = so.account_id
   WHERE i.status <> 'PAID' AND i.due_date <= v_today + INTERVAL 3 DAY;

  SELECT v_overdue AS overdue, ROW_COUNT() AS tasks;
END $$

DROP PROCEDURE IF EXISTS sp_job_engagement_reminder $$
CREATE PROCEDURE sp_job_engagement_reminder()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  DROP TEMPORARY TABLE IF EXISTS tmp_er;
  CREATE TEMPORARY TABLE tmp_er AS
  SELECT t.id, t.owner_user_id, t.entity_id AS partner_id, t.description AS plan FROM task t
   WHERE t.task_type = 'ENGAGEMENT' AND t.status = 'OPEN' AND t.reminder_sent_at IS NULL
     AND DATE(t.due_at + INTERVAL 330 MINUTE) <= v_today;
  UPDATE task t JOIN tmp_er e ON e.id = t.id SET t.reminder_sent_at = UTC_TIMESTAMP(3);

  SELECT e.partner_id AS partnerId, COALESCE(p.short_name, p.legal_name) AS partnerName, e.plan,
         u.email, u.full_name AS fullName
    FROM tmp_er e
    JOIN partner p ON p.id = e.partner_id
    JOIN `user` u ON u.id = e.owner_user_id AND u.status = 'ACTIVE';
  DROP TEMPORARY TABLE IF EXISTS tmp_er;
END $$

DROP PROCEDURE IF EXISTS sp_job_stage_ageing $$
CREATE PROCEDURE sp_job_stage_ageing()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  SELECT m.email, m.full_name AS fullName, COUNT(*) AS dealCount,
         SUBSTRING(GROUP_CONCAT(CONCAT(o.opportunity_no, ' (', s.name, ', ',
                                       DATEDIFF(v_today, DATE(o.stage_entered_at + INTERVAL 330 MINUTE)), ' days)')
                                ORDER BY o.stage_entered_at SEPARATOR '; '), 1, 2000) AS deals
    FROM opportunity o
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1 AND s.sla_days IS NOT NULL
    JOIN `user` u ON u.id = o.owner_user_id
    JOIN `user` m ON m.id = u.reporting_to_user_id AND m.status = 'ACTIVE'
   WHERE o.is_active = 1
     AND DATEDIFF(v_today, DATE(o.stage_entered_at + INTERVAL 330 MINUTE)) > s.sla_days
   GROUP BY m.id, m.email, m.full_name;
END $$

DROP PROCEDURE IF EXISTS sp_job_housekeeping $$
CREATE PROCEDURE sp_job_housekeeping()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_tokens INT;
  DECLARE v_refresh INT;
  DECLARE v_attempts INT;

  DELETE FROM password_reset_token WHERE expires_at < UTC_TIMESTAMP(3) - INTERVAL 30 DAY;
  SET v_tokens = ROW_COUNT();

  DROP TEMPORARY TABLE IF EXISTS tmp_rt;
  CREATE TEMPORARY TABLE tmp_rt (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_rt SELECT id FROM refresh_token WHERE expires_at < UTC_TIMESTAMP(3) - INTERVAL 30 DAY;
  -- the rotation chain points at older rows: unlink before deleting them
  UPDATE refresh_token r JOIN tmp_rt t ON t.id = r.replaced_by_id SET r.replaced_by_id = NULL;
  DELETE r FROM refresh_token r JOIN tmp_rt t ON t.id = r.id;
  SET v_refresh = ROW_COUNT();
  DROP TEMPORARY TABLE IF EXISTS tmp_rt;

  DELETE FROM login_attempt WHERE attempted_at < UTC_TIMESTAMP(3) - INTERVAL 90 DAY;
  SET v_attempts = ROW_COUNT();

  SELECT v_tokens AS tokens, v_refresh AS refreshTokens, v_attempts AS loginAttempts;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V039', 'Remaining scheduler jobs: reminders, monthly close, wake-up, invoices, ageing, housekeeping', UTC_TIMESTAMP());
