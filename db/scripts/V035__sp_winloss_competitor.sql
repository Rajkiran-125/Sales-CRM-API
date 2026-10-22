-- =============================================================================
-- V035  Sales CRM - win / loss competitor filter                        (2026-10-14)
--
--   spi_winloss_closed, sp_winloss_summary, sp_winloss_deals: re-issue of V010 with one more
--   filter, p_competitor_id (12.12: filters period, product, industry, partner, owner,
--   competitor). A deal matches when the competitor was on it or it was lost to it. Nothing
--   else changes (the build copies the V010 text).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V034.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS spi_winloss_closed $$
CREATE PROCEDURE spi_winloss_closed(
  IN  p_user_id       BIGINT UNSIGNED,
  IN  p_fiscal_year   SMALLINT,
  IN  p_quarter       TINYINT,
  IN  p_owner_user_id BIGINT UNSIGNED,
  IN  p_product_id    BIGINT UNSIGNED,
  IN  p_industry_id   BIGINT UNSIGNED,
  IN  p_partner_id    BIGINT UNSIGNED,
  IN  p_competitor_id BIGINT UNSIGNED,
  OUT o_fy            SMALLINT,
  OUT o_q             TINYINT,
  OUT o_from          DATE,
  OUT o_to            DATE
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all   TINYINT;
  DECLARE v_today DATE;

  CALL spi_dashboard_period(p_fiscal_year, p_quarter, o_fy, o_q, o_from, o_to, v_today);
  CALL spi_dashboard_scope(p_user_id, NULL, p_product_id, p_industry_id, p_owner_user_id, p_partner_id, v_all);

  DROP TEMPORARY TABLE IF EXISTS tmp_closed;
  CREATE TEMPORARY TABLE tmp_closed (
    id BIGINT UNSIGNED NOT NULL PRIMARY KEY, won TINYINT, value DECIMAL(18,2), closed_on DATE
  );
  INSERT INTO tmp_closed
  SELECT o.id, o.stage_code = 'WON',
         IF(o.stage_code = 'WON', COALESCE(o.po_value, o.final_value, o.expected_value), o.expected_value) * o.fx_rate,
         DATE(o.closed_at + INTERVAL 330 MINUTE)
    FROM opportunity o JOIN tmp_dash_opp t ON t.id = o.id
   WHERE o.stage_code IN ('WON', 'LOST') AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN o_from AND o_to
     -- the competitor was on the deal, or the deal was lost to it (12.12 filter)
     AND (p_competitor_id IS NULL
          OR EXISTS (SELECT 1 FROM opportunity_competitor oc WHERE oc.opportunity_id = o.id AND oc.competitor_id = p_competitor_id)
          OR EXISTS (SELECT 1 FROM win_loss w WHERE w.opportunity_id = o.id AND w.competitor_id = p_competitor_id));
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

DROP PROCEDURE IF EXISTS sp_winloss_summary $$
CREATE PROCEDURE sp_winloss_summary(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_fiscal_year   SMALLINT,
  IN p_quarter       TINYINT,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_product_id    BIGINT UNSIGNED,
  IN p_industry_id   BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_competitor_id BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
  COMMENT 'Win / loss analysis of the closed deals (12.12)'
BEGIN
  DECLARE v_fy   SMALLINT;
  DECLARE v_q    TINYINT;
  DECLARE v_from DATE;
  DECLARE v_to   DATE;

  CALL spi_winloss_closed(p_user_id, p_fiscal_year, p_quarter, p_owner_user_id, p_product_id, p_industry_id,
                          p_partner_id, p_competitor_id, v_fy, v_q, v_from, v_to);

  SELECT v_fy AS fiscalYear, v_q AS quarter, v_from AS fromDate, v_to AS toDate;

  SELECT CAST(IFNULL(SUM(won), 0) AS SIGNED) AS wonCount,
         CAST(IFNULL(SUM(IF(won = 1, value, 0)), 0) AS DECIMAL(18,2)) AS wonValue,
         CAST(IFNULL(SUM(won = 0), 0) AS SIGNED) AS lostCount,
         CAST(IFNULL(SUM(IF(won = 0, value, 0)), 0) AS DECIMAL(18,2)) AS lostValue,
         IF(COUNT(*) = 0, NULL, ROUND(100 * SUM(won) / COUNT(*), 1)) AS winRatePct,
         IF(COUNT(*) = 0, NULL, ROUND(100 * SUM(IF(won = 1, value, 0)) / SUM(value), 1)) AS valueWinRatePct,
         CAST(AVG(IF(won = 1, value, NULL)) AS DECIMAL(18,2)) AS avgWonValue
    FROM tmp_closed;

  SELECT DATE_FORMAT(closed_on, '%Y-%m') AS month, CAST(SUM(won) AS SIGNED) AS won,
         CAST(SUM(won = 0) AS SIGNED) AS lost, ROUND(100 * SUM(won) / COUNT(*), 1) AS winRatePct,
         CAST(SUM(IF(won = 1, value, 0)) AS DECIMAL(18,2)) AS wonValue
    FROM tmp_closed GROUP BY month ORDER BY month;

  SELECT r.name AS reason, CAST(COUNT(*) AS SIGNED) AS count, CAST(SUM(c.value) AS DECIMAL(18,2)) AS value
    FROM tmp_closed c JOIN win_loss wl ON wl.opportunity_id = c.id JOIN reason r ON r.id = wl.loss_reason_id
   WHERE c.won = 0 GROUP BY r.name ORDER BY count DESC, value DESC;

  SELECT cp.name AS competitor, CAST(COUNT(*) AS SIGNED) AS count, CAST(SUM(c.value) AS DECIMAL(18,2)) AS value
    FROM tmp_closed c JOIN win_loss wl ON wl.opportunity_id = c.id JOIN competitor cp ON cp.id = wl.competitor_id
   WHERE c.won = 0 GROUP BY cp.name ORDER BY count DESC, value DESC;

  SELECT r.name AS reason, CAST(COUNT(*) AS SIGNED) AS count
    FROM tmp_closed c JOIN win_loss_reason wr ON wr.opportunity_id = c.id JOIN reason r ON r.id = wr.reason_id
   WHERE c.won = 1 GROUP BY r.name ORDER BY count DESC, r.name;

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName, c.won AS isWon,
         wl.lesson, wl.detail, c.closed_on AS closedOn
    FROM tmp_closed c
    JOIN opportunity o ON o.id = c.id
    JOIN account a ON a.id = o.account_id
    JOIN win_loss wl ON wl.opportunity_id = c.id
   WHERE NULLIF(TRIM(wl.lesson), '') IS NOT NULL
   ORDER BY c.closed_on DESC
   LIMIT 12;

  DROP TEMPORARY TABLE IF EXISTS tmp_closed;
END $$

DROP PROCEDURE IF EXISTS sp_winloss_deals $$
CREATE PROCEDURE sp_winloss_deals(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_fiscal_year   SMALLINT,
  IN p_quarter       TINYINT,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_product_id    BIGINT UNSIGNED,
  IN p_industry_id   BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_competitor_id BIGINT UNSIGNED,
  IN p_outcome       VARCHAR(4),
  IN p_offset        INT,
  IN p_limit         INT
)
  SQL SECURITY DEFINER
  COMMENT 'Closed deals for the win / loss analysis (12.12)'
BEGIN
  DECLARE v_fy   SMALLINT;
  DECLARE v_q    TINYINT;
  DECLARE v_from DATE;
  DECLARE v_to   DATE;

  CALL spi_winloss_closed(p_user_id, p_fiscal_year, p_quarter, p_owner_user_id, p_product_id, p_industry_id,
                          p_partner_id, p_competitor_id, v_fy, v_q, v_from, v_to);

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName, u.full_name AS ownerName,
         o.stage_code AS stageCode, CAST(c.value AS DECIMAL(18,2)) AS value, c.closed_on AS closedOn,
         lr.name AS lossReason, cp.name AS competitor, wl.detail,
         (SELECT GROUP_CONCAT(r.name ORDER BY r.sort_order SEPARATOR ', ')
            FROM win_loss_reason wr JOIN reason r ON r.id = wr.reason_id WHERE wr.opportunity_id = o.id) AS winReasons,
         (SELECT GROUP_CONCAT(pr.name ORDER BY pr.sort_order SEPARATOR ', ')
            FROM opportunity_product op JOIN product pr ON pr.id = op.product_id WHERE op.opportunity_id = o.id) AS products,
         (SELECT COALESCE(p.short_name, p.legal_name) FROM opportunity_partner op JOIN partner p ON p.id = op.partner_id
           WHERE op.opportunity_id = o.id ORDER BY op.is_primary DESC LIMIT 1) AS partnerName
    FROM tmp_closed c
    JOIN opportunity o ON o.id = c.id
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN win_loss wl ON wl.opportunity_id = o.id
    LEFT JOIN reason lr ON lr.id = wl.loss_reason_id
    LEFT JOIN competitor cp ON cp.id = wl.competitor_id
   WHERE p_outcome IS NULL OR o.stage_code = p_outcome
   ORDER BY c.closed_on DESC, o.id DESC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total FROM tmp_closed c
   WHERE p_outcome IS NULL OR c.won = (p_outcome = 'WON');

  DROP TEMPORARY TABLE IF EXISTS tmp_closed;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V035', 'Win / loss competitor filter', UTC_TIMESTAMP());
