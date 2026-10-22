-- =============================================================================
-- V040  Sales CRM - dashboard v2: cycle times, targets                   (2026-10-15)
--
--   sp_dashboard_cycle_times  the "cycle times" tile (12.2): lead-to-deal, deal-to-win and
--                             order-to-book days, over the deals the dashboard scope and
--                             filters select (spi_dashboard_scope), in the period.
--   sp_target_list            GET /targets?fiscalYear=&quarter=: every active user with the
--                             quarter's target (OD-15), for the Targets screen.
--   sp_target_save            PUT /targets: value / count / new-logo targets per owner and
--                             quarter (target.manage); a zero value and count removes it.
--                             The dashboard and the hierarchy funnel read them (V007, V008).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V039.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_dashboard_cycle_times $$
CREATE PROCEDURE sp_dashboard_cycle_times(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_fiscal_year   SMALLINT,
  IN p_quarter       TINYINT,
  IN p_source        VARCHAR(10),
  IN p_product_id    BIGINT UNSIGNED,
  IN p_industry_id   BIGINT UNSIGNED,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_fy    SMALLINT;
  DECLARE v_q     TINYINT;
  DECLARE v_from  DATE;
  DECLARE v_to    DATE;
  DECLARE v_today DATE;
  DECLARE v_all   TINYINT;
  DECLARE v_lead  DECIMAL(8,1);
  DECLARE v_win   DECIMAL(8,1);
  DECLARE v_book  DECIMAL(8,1);

  CALL spi_dashboard_period(p_fiscal_year, p_quarter, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_dashboard_scope(p_user_id, p_source, p_product_id, p_industry_id, p_owner_user_id, p_partner_id, v_all);

  -- one statement per figure: MySQL cannot open a temporary table twice in one statement
  -- deals created in the period from a lead: days from the lead to the deal
  SELECT ROUND(AVG(DATEDIFF(o.created_at, l.created_at)), 1) INTO v_lead
    FROM opportunity o JOIN tmp_dash_opp t ON t.id = o.id JOIN sales_lead l ON l.id = o.lead_id
   WHERE DATE(o.created_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to;
  -- deals won in the period: days from the deal to the win
  SELECT ROUND(AVG(DATEDIFF(o.closed_at, o.created_at)), 1) INTO v_win
    FROM opportunity o JOIN tmp_dash_opp t ON t.id = o.id
   WHERE o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to;
  -- orders with the PO in the period: PO to first invoice (BR-OR-03)
  SELECT ROUND(AVG(so.order_to_book_days), 1) INTO v_book
    FROM sales_order so JOIN tmp_dash_opp t ON t.id = so.opportunity_id
   WHERE so.po_date BETWEEN v_from AND v_to AND so.order_to_book_days IS NOT NULL;

  SELECT v_lead AS leadToDealDays, v_win AS dealToWinDays, v_book AS orderToBookDays;

  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

DROP PROCEDURE IF EXISTS sp_target_list $$
CREATE PROCEDURE sp_target_list(IN p_fiscal_year SMALLINT, IN p_quarter TINYINT)
  SQL SECURITY DEFINER
BEGIN
  SELECT u.id AS userId, u.full_name AS name, u.designation, u.reporting_to_user_id AS reportingToUserId,
         CAST(IFNULL(t.target_value, 0) AS DECIMAL(18,2)) AS targetValue,
         IFNULL(t.target_count, 0) AS targetCount, t.new_logo_target AS newLogoTarget
    FROM `user` u
    LEFT JOIN target t ON t.owner_user_id = u.id AND t.fiscal_year = p_fiscal_year AND t.quarter = p_quarter
   WHERE u.status = 'ACTIVE'
   ORDER BY u.full_name;
END $$

DROP PROCEDURE IF EXISTS sp_target_save $$
CREATE PROCEDURE sp_target_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_fiscal_year   SMALLINT,
  IN p_quarter       TINYINT,
  IN p_items         JSON        -- [{ownerUserId, targetValue, targetCount, newLogoTarget}]
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  DROP TEMPORARY TABLE IF EXISTS tmp_tg;
  CREATE TEMPORARY TABLE tmp_tg AS
  SELECT j.uid, j.val, j.cnt, j.logos
    FROM JSON_TABLE(p_items, '$[*]' COLUMNS (
           uid   BIGINT UNSIGNED PATH '$.ownerUserId',
           val   DECIMAL(16,2)   PATH '$.targetValue',
           cnt   INT UNSIGNED    PATH '$.targetCount',
           logos INT UNSIGNED    PATH '$.newLogoTarget')) j;
  IF EXISTS (SELECT 1 FROM tmp_tg t LEFT JOIN `user` u ON u.id = t.uid WHERE u.id IS NULL) THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_tg;
    CALL spi_raise('VALIDATION_FAILED', 'Unknown user in the targets.', 'items');
  END IF;

  START TRANSACTION;
  DELETE tg FROM target tg JOIN tmp_tg t ON t.uid = tg.owner_user_id
   WHERE tg.fiscal_year = p_fiscal_year AND tg.quarter = p_quarter
     AND IFNULL(t.val, 0) = 0 AND IFNULL(t.cnt, 0) = 0 AND t.logos IS NULL;
  INSERT INTO target (owner_user_id, fiscal_year, quarter, target_value, target_count, new_logo_target, created_by)
  SELECT t.uid, p_fiscal_year, p_quarter, IFNULL(t.val, 0), IFNULL(t.cnt, 0), t.logos, p_actor_user_id
    FROM tmp_tg t
   WHERE NOT (IFNULL(t.val, 0) = 0 AND IFNULL(t.cnt, 0) = 0 AND t.logos IS NULL)
  ON DUPLICATE KEY UPDATE target_value = IFNULL(t.val, 0), target_count = IFNULL(t.cnt, 0),
                          new_logo_target = t.logos, updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  SELECT 'user', t.uid, 'TARGET_SET',
         JSON_OBJECT('fiscalYear', p_fiscal_year, 'quarter', p_quarter, 'value', t.val, 'count', t.cnt, 'newLogos', t.logos),
         p_actor_user_id, p_ip, p_request_id
    FROM tmp_tg t;
  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_tg;

  SELECT COUNT(*) AS targets FROM target WHERE fiscal_year = p_fiscal_year AND quarter = p_quarter;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V040', 'Dashboard v2: cycle times; targets list and save', UTC_TIMESTAMP());
