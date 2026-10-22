-- =============================================================================
-- V007  Sales CRM - management dashboard v1 (M03, tech doc 12.2, UM 8)   (2026-10-09)
--
--   Read-only aggregation over opportunity, stage, monthly_commit, weekly_status,
--   win_loss, opportunity_partner and target. Nothing is written.
--
--   Rules:
--     * Every number is computed inside the user's data scope (10.8): the union of
--       their roles' scope levels over the reporting tree (user_hierarchy).
--     * Leads are never counted (BR-LD-03).
--     * Values are reported in INR: value x fx_rate (OD-51). Weighted value is the
--       one maintained on the deal, already in INR (BR-OP-06, D-17). Won value = PO
--       value, else final value, else expected value. Money columns are DECIMAL(18,2),
--       so the API sends them as decimal strings with 2 decimals (OD-27).
--     * Period = a fiscal quarter or a whole fiscal year (fiscal_year.start_month,
--       OD-56). Open deals count when their expected close date is in the period;
--       won / lost deals when they closed in the period; "new" when created in it.
--     * "This month" and the monthly commitment (BR-FC-03) always use the current
--       month; "overdue status" (BR-FC-01) = an open deal, older than this week,
--       with no weekly status since last week's Monday. Business dates are IST.
--     * Targets (OD-15) are shown only without source / product / industry /
--       partner filters, because targets are set per owner, not per segment.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V006.
-- Run as the existing account that owns unigr8ways_sales_crm (the procedures use
-- temporary tables, so that account needs CREATE TEMPORARY TABLES, part of the usual
-- schema privileges).
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- spi_dashboard_period: resolve the period. Without a fiscal year: the current
-- fiscal quarter. With a fiscal year and no quarter: the whole fiscal year.
-- Fiscal year 2026 = FY 2026-27 (starts in fiscal_year.start_month of 2026).
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_dashboard_period $$
CREATE PROCEDURE spi_dashboard_period(
  IN  p_fiscal_year SMALLINT,
  IN  p_quarter     TINYINT,
  OUT o_fiscal_year SMALLINT,
  OUT o_quarter     TINYINT,
  OUT o_from        DATE,
  OUT o_to          DATE,
  OUT o_today       DATE
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_start_month INT;
  DECLARE v_fy_start    DATE;

  CALL spi_setting_int('fiscal_year.start_month', 4, v_start_month);
  SET o_today = DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  IF p_fiscal_year IS NULL THEN
    SET o_fiscal_year = IF(MONTH(o_today) >= v_start_month, YEAR(o_today), YEAR(o_today) - 1);
    SET o_quarter = FLOOR(MOD(MONTH(o_today) - v_start_month + 12, 12) / 3) + 1;
  ELSE
    SET o_fiscal_year = p_fiscal_year;
    SET o_quarter = p_quarter;
  END IF;

  IF o_fiscal_year < 2000 OR o_fiscal_year > 2100 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose a fiscal year between 2000 and 2100.', 'fiscalYear');
  END IF;
  IF o_quarter IS NOT NULL AND (o_quarter < 1 OR o_quarter > 4) THEN
    CALL spi_raise('VALIDATION_FAILED', 'The quarter must be 1 to 4.', 'quarter');
  END IF;

  SET v_fy_start = MAKEDATE(o_fiscal_year, 1) + INTERVAL (v_start_month - 1) MONTH;
  IF o_quarter IS NULL THEN
    SET o_from = v_fy_start;
    SET o_to = v_fy_start + INTERVAL 12 MONTH - INTERVAL 1 DAY;
  ELSE
    SET o_from = v_fy_start + INTERVAL (3 * (o_quarter - 1)) MONTH;
    SET o_to = o_from + INTERVAL 3 MONTH - INTERVAL 1 DAY;
  END IF;
END $$

-- -----------------------------------------------------------------------------
-- spi_dashboard_scope: (re)create tmp_dash_opp with the ids of the active deals
-- (every stage) that the user may see (10.8) and that match the filters.
--   owner filter = that person and everyone below them (a manager shows a team)
--   Finance (MODULE_LIMITED) sees deals only when OPPORTUNITIES is one of its
--   role modules.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_dashboard_scope $$
CREATE PROCEDURE spi_dashboard_scope(
  IN  p_user_id       BIGINT UNSIGNED,
  IN  p_source        VARCHAR(10),
  IN  p_product_id    BIGINT UNSIGNED,
  IN  p_industry_id   BIGINT UNSIGNED,
  IN  p_owner_user_id BIGINT UNSIGNED,
  IN  p_partner_id    BIGINT UNSIGNED,
  OUT o_all           TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;

  CALL spi_scope_flags(p_user_id, o_all, v_own, v_assigned, v_partner, v_module);
  IF o_all = 0 AND v_module = 1 AND EXISTS (
       SELECT 1 FROM user_role ur
         JOIN role_module_scope rms ON rms.role_id = ur.role_id
        WHERE ur.user_id = p_user_id AND rms.module = 'OPPORTUNITIES') THEN
    SET o_all = 1;
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
  CREATE TEMPORARY TABLE tmp_dash_opp (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);

  INSERT INTO tmp_dash_opp (id)
  SELECT o.id
    FROM opportunity o
   WHERE o.is_active = 1
     AND (o_all = 1
          OR (v_own = 1 AND EXISTS (
                SELECT 1 FROM user_hierarchy h
                 WHERE h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (o.owner_user_id, IFNULL(o.backup_owner_user_id, 0))))
          OR (v_assigned = 1 AND EXISTS (
                SELECT 1 FROM user_hierarchy h
                 WHERE h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (IFNULL(o.presales_owner_user_id, 0), IFNULL(o.sponsor_user_id, 0))))
          OR (v_partner = 1 AND EXISTS (
                SELECT 1 FROM opportunity_partner op
                  JOIN partner p ON p.id = op.partner_id
                  JOIN user_hierarchy h ON h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (p.relationship_owner_user_id, IFNULL(p.backup_owner_user_id, 0))
                 WHERE op.opportunity_id = o.id)))
     AND (p_source IS NULL OR o.source = p_source)
     AND (p_industry_id IS NULL
          OR COALESCE(o.industry_id, (SELECT a.industry_id FROM account a WHERE a.id = o.account_id)) = p_industry_id)
     AND (p_product_id IS NULL OR EXISTS (
            SELECT 1 FROM opportunity_product x WHERE x.opportunity_id = o.id AND x.product_id = p_product_id))
     AND (p_owner_user_id IS NULL OR EXISTS (
            SELECT 1 FROM user_hierarchy h2
             WHERE h2.ancestor_user_id = p_owner_user_id AND h2.descendant_user_id = o.owner_user_id))
     AND (p_partner_id IS NULL OR EXISTS (
            SELECT 1 FROM opportunity_partner y WHERE y.opportunity_id = o.id AND y.partner_id = p_partner_id));
END $$

-- -----------------------------------------------------------------------------
-- spi_dashboard_rows: one page of deal rows from tmp_dash_rows (the detail table
-- and every drill-down use the same columns)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_dashboard_rows $$
CREATE PROCEDURE spi_dashboard_rows(IN p_offset INT, IN p_limit INT)
  SQL SECURITY DEFINER
BEGIN
  SELECT o.id, o.opportunity_no AS opportunityNo, o.title,
         a.name AS accountName,
         (SELECT COALESCE(p.short_name, p.legal_name)
            FROM opportunity_partner op JOIN partner p ON p.id = op.partner_id
           WHERE op.opportunity_id = o.id
           ORDER BY op.is_primary DESC, op.id
           LIMIT 1) AS partnerName,
         u.full_name AS ownerName, o.stage_code AS stageCode, s.name AS stageName, o.source,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(o.weighted_value AS DECIMAL(18,2)) AS weighted,
         CAST(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate AS DECIMAL(18,2)) AS closedValue,
         o.expected_close_date AS expectedCloseDate, o.closed_at AS closedAt,
         (SELECT ws.status FROM weekly_status ws
           WHERE ws.opportunity_id = o.id
           ORDER BY ws.week_start DESC LIMIT 1) AS lastStatus,
         o.health
    FROM tmp_dash_rows r
    JOIN opportunity o ON o.id = r.id
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   ORDER BY r.sort_value DESC, o.id
   LIMIT p_offset, p_limit;
END $$

-- -----------------------------------------------------------------------------
-- sp_dashboard_get: every tile in one call (GET /dashboard, 14.3)
--   result sets: period, kpi, funnel, closures, bySource, lossReasons, topPartners,
--   detail, then the filter options (owners, partners, products, industries)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_dashboard_get $$
CREATE PROCEDURE sp_dashboard_get(
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
  COMMENT 'Management dashboard v1 tiles, within the user data scope (12.2)'
BEGIN
  DECLARE v_fy           SMALLINT;
  DECLARE v_q            TINYINT;
  DECLARE v_from         DATE;
  DECLARE v_to           DATE;
  DECLARE v_today        DATE;
  DECLARE v_month_start  DATE;
  DECLARE v_month_end    DATE;
  DECLARE v_week_start   DATE;
  DECLARE v_all          TINYINT;
  DECLARE v_commit_value DECIMAL(18,2) DEFAULT 0;
  DECLARE v_commit_count INT DEFAULT 0;
  DECLARE v_target       DECIMAL(18,2) DEFAULT NULL;

  CALL spi_dashboard_period(p_fiscal_year, p_quarter, v_fy, v_q, v_from, v_to, v_today);
  SET v_month_start = v_today - INTERVAL (DAY(v_today) - 1) DAY;
  SET v_month_end = LAST_DAY(v_today);
  SET v_week_start = v_today - INTERVAL WEEKDAY(v_today) DAY;

  CALL spi_dashboard_scope(p_user_id, p_source, p_product_id, p_industry_id, p_owner_user_id, p_partner_id, v_all);

  -- 1. period
  SELECT v_fy AS fiscalYear, v_q AS quarter, v_from AS fromDate, v_to AS toDate,
         v_today AS today, v_month_start AS monthStart;

  -- 2. kpi
  SELECT IFNULL(SUM(mc.commit_value * o.fx_rate), 0), COUNT(*)
    INTO v_commit_value, v_commit_count
    FROM monthly_commit mc
    JOIN tmp_dash_opp t ON t.id = mc.opportunity_id
    JOIN opportunity o ON o.id = mc.opportunity_id
   WHERE mc.commit_month = v_month_start AND mc.commit_type = 'COMMIT';

  IF p_source IS NULL AND p_product_id IS NULL AND p_industry_id IS NULL AND p_partner_id IS NULL THEN
    SELECT IFNULL(SUM(tg.target_value), 0) INTO v_target
      FROM target tg
     WHERE tg.fiscal_year = v_fy
       AND (v_q IS NULL OR tg.quarter = v_q)
       AND (p_owner_user_id IS NULL OR EXISTS (
              SELECT 1 FROM user_hierarchy h
               WHERE h.ancestor_user_id = p_owner_user_id AND h.descendant_user_id = tg.owner_user_id))
       AND (v_all = 1 OR EXISTS (
              SELECT 1 FROM user_hierarchy h
               WHERE h.ancestor_user_id = p_user_id AND h.descendant_user_id = tg.owner_user_id));
  END IF;

  SELECT CAST(IFNULL(SUM(s.is_open = 1 AND o.expected_close_date BETWEEN v_from AND v_to), 0) AS SIGNED) AS openCount,
         CAST(IFNULL(SUM(IF(s.is_open = 1 AND o.expected_close_date BETWEEN v_from AND v_to, o.expected_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS openValue,
         CAST(IFNULL(SUM(IF(s.is_open = 1 AND o.expected_close_date BETWEEN v_from AND v_to, o.weighted_value, 0)), 0) AS DECIMAL(18,2)) AS weightedValue,
         CAST(IFNULL(SUM(DATE(o.created_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to), 0) AS SIGNED) AS newCount,
         CAST(IFNULL(SUM(s.is_open = 1 AND o.expected_close_date BETWEEN v_month_start AND v_month_end), 0) AS SIGNED) AS thisMonthCount,
         CAST(IFNULL(SUM(IF(s.is_open = 1 AND o.expected_close_date BETWEEN v_month_start AND v_month_end, o.expected_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS thisMonthValue,
         v_commit_count AS committedCount,
         v_commit_value AS committedValue,
         CAST(IFNULL(SUM(s.is_open = 1 AND o.created_at < v_week_start AND NOT EXISTS (
                SELECT 1 FROM weekly_status ws
                 WHERE ws.opportunity_id = o.id AND ws.week_start >= v_week_start - INTERVAL 7 DAY)), 0) AS SIGNED) AS overdueStatusCount,
         CAST(IFNULL(SUM(o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to), 0) AS SIGNED) AS wonCount,
         CAST(IFNULL(SUM(IF(o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to,
                       COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS wonValue,
         CAST(IFNULL(SUM(o.stage_code = 'LOST' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to), 0) AS SIGNED) AS lostCount,
         CAST(IFNULL(SUM(IF(o.stage_code = 'LOST' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to,
                       o.expected_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS lostValue,
         v_target AS targetValue
    FROM tmp_dash_opp t
    JOIN opportunity o ON o.id = t.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code;

  -- 3. funnel by stage (open stages in their order, empty stages included)
  SELECT s.code AS stageCode, s.name AS stageName, s.default_confidence_pct AS confidencePct,
         s.colour_token AS colour,
         CAST(IFNULL(x.cnt, 0) AS SIGNED) AS count, CAST(IFNULL(x.val, 0) AS DECIMAL(18,2)) AS value, CAST(IFNULL(x.wt, 0) AS DECIMAL(18,2)) AS weighted
    FROM stage s
    LEFT JOIN (
      SELECT o.stage_code, COUNT(*) AS cnt,
             SUM(o.expected_value * o.fx_rate) AS val, SUM(o.weighted_value) AS wt
        FROM tmp_dash_opp t
        JOIN opportunity o ON o.id = t.id
       WHERE o.expected_close_date BETWEEN v_from AND v_to
       GROUP BY o.stage_code
    ) x ON x.stage_code = s.code
   WHERE s.entity = 'OPP' AND s.is_open = 1 AND s.is_active = 1
   ORDER BY s.sequence_no;

  -- 4. closures of the current month by owner (monthly commitment, BR-FC-03 / BR-FC-05)
  SELECT u.id AS ownerUserId, u.full_name AS ownerName,
         CAST(IFNULL(SUM(IF(mc.commit_type = 'COMMIT', mc.commit_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS committed,
         CAST(IFNULL(SUM(IF(mc.commit_type = 'UPSIDE', mc.commit_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS bestCase,
         CAST(IFNULL(SUM(IF(mc.commit_type = 'NEXT_MONTH', mc.commit_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS nextMonth
    FROM monthly_commit mc
    JOIN tmp_dash_opp t ON t.id = mc.opportunity_id
    JOIN opportunity o ON o.id = mc.opportunity_id
    JOIN `user` u ON u.id = o.owner_user_id
   WHERE mc.commit_month = v_month_start
   GROUP BY u.id, u.full_name
   ORDER BY committed DESC, bestCase DESC, u.full_name;

  -- 5. open funnel by source
  SELECT o.source, CAST(COUNT(*) AS SIGNED) AS count,
         CAST(SUM(o.expected_value * o.fx_rate) AS DECIMAL(18,2)) AS value, CAST(SUM(o.weighted_value) AS DECIMAL(18,2)) AS weighted
    FROM tmp_dash_opp t
    JOIN opportunity o ON o.id = t.id
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
   WHERE o.expected_close_date BETWEEN v_from AND v_to
   GROUP BY o.source
   ORDER BY value DESC;

  -- 6. top loss reasons in the period
  SELECT r.id AS reasonId, r.name AS reasonName, CAST(COUNT(*) AS SIGNED) AS count,
         CAST(SUM(o.expected_value * o.fx_rate) AS DECIMAL(18,2)) AS value
    FROM tmp_dash_opp t
    JOIN opportunity o ON o.id = t.id AND o.stage_code = 'LOST'
    JOIN win_loss wl ON wl.opportunity_id = o.id AND wl.outcome = 'LOST'
    JOIN reason r ON r.id = wl.loss_reason_id
   WHERE DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to
   GROUP BY r.id, r.name
   ORDER BY count DESC, value DESC
   LIMIT 6;

  -- 7. top partners: deals sourced / influenced, open pipeline, won and win % in the period
  SELECT pd.partner_id AS partnerId, COALESCE(p.short_name, p.legal_name) AS partnerName,
         CAST(SUM(pd.sourced) AS SIGNED) AS sourcedDeals, CAST(SUM(pd.influenced) AS SIGNED) AS influencedDeals,
         CAST(SUM(IF(pd.is_open_in_period = 1, pd.value, 0)) AS DECIMAL(18,2)) AS pipelineValue,
         CAST(SUM(pd.is_won) AS SIGNED) AS wonCount,
         CAST(SUM(IF(pd.is_won = 1, pd.closed_value, 0)) AS DECIMAL(18,2)) AS wonValue,
         IF(SUM(pd.is_won) + SUM(pd.is_lost) = 0, NULL,
            ROUND(100 * SUM(pd.is_won) / (SUM(pd.is_won) + SUM(pd.is_lost)), 1)) AS winRatePct
    FROM (
      SELECT op.partner_id, o.id,
             MAX(op.partner_role = 'SOURCED') AS sourced,
             MAX(op.partner_role = 'INFLUENCED') AS influenced,
             MAX(s.is_open = 1 AND o.expected_close_date BETWEEN v_from AND v_to) AS is_open_in_period,
             MAX(o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to) AS is_won,
             MAX(o.stage_code = 'LOST' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to) AS is_lost,
             MAX(o.expected_value * o.fx_rate) AS value,
             MAX(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate) AS closed_value
        FROM tmp_dash_opp t
        JOIN opportunity o ON o.id = t.id
        JOIN opportunity_partner op ON op.opportunity_id = o.id
        LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
       GROUP BY op.partner_id, o.id
    ) pd
    JOIN partner p ON p.id = pd.partner_id
   WHERE pd.is_open_in_period = 1 OR pd.is_won = 1 OR pd.is_lost = 1
   GROUP BY pd.partner_id, p.short_name, p.legal_name
   ORDER BY wonValue + pipelineValue DESC
   LIMIT 8;

  -- 8. detail: the ten biggest open deals of the period by weighted value
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_rows;
  CREATE TEMPORARY TABLE tmp_dash_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY, sort_value DECIMAL(18,2) NOT NULL);
  INSERT INTO tmp_dash_rows (id, sort_value)
  SELECT o.id, o.weighted_value
    FROM tmp_dash_opp t
    JOIN opportunity o ON o.id = t.id
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
   WHERE o.expected_close_date BETWEEN v_from AND v_to;
  CALL spi_dashboard_rows(0, 10);
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_rows;

  -- 9-12. filter options, from the user's scope without the filters
  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);

  SELECT DISTINCT u.id, u.full_name AS name
    FROM tmp_dash_opp t
    JOIN opportunity o ON o.id = t.id
    JOIN user_hierarchy h ON h.descendant_user_id = o.owner_user_id
    JOIN `user` u ON u.id = h.ancestor_user_id
   WHERE v_all = 1 OR EXISTS (
           SELECT 1 FROM user_hierarchy me
            WHERE me.ancestor_user_id = p_user_id AND me.descendant_user_id = u.id)
   ORDER BY u.full_name;

  SELECT DISTINCT p.id, COALESCE(p.short_name, p.legal_name) AS name
    FROM tmp_dash_opp t
    JOIN opportunity_partner op ON op.opportunity_id = t.id
    JOIN partner p ON p.id = op.partner_id
   ORDER BY name;

  SELECT id, name FROM product WHERE is_active = 1 ORDER BY sort_order, name;
  SELECT id, name FROM industry WHERE is_active = 1 ORDER BY sort_order, name;

  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

-- -----------------------------------------------------------------------------
-- sp_dashboard_drill: the deals behind a tile, paged (GET /dashboard/drill/{tile})
--   OPEN, STAGE (key = stage code), SOURCE (key = source), NEW, THIS_MONTH,
--   COMMIT (key = COMMIT | UPSIDE | NEXT_MONTH), OVERDUE, WON, LOST,
--   LOSS_REASON (key = reason id), PARTNER (key = partner id)
--   result sets: rows, then { total }
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_dashboard_drill $$
CREATE PROCEDURE sp_dashboard_drill(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_tile          VARCHAR(20),
  IN p_key           VARCHAR(40),
  IN p_fiscal_year   SMALLINT,
  IN p_quarter       TINYINT,
  IN p_source        VARCHAR(10),
  IN p_product_id    BIGINT UNSIGNED,
  IN p_industry_id   BIGINT UNSIGNED,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_offset        INT,
  IN p_limit         INT
)
  SQL SECURITY DEFINER
  COMMENT 'Deals behind a dashboard tile, within the user data scope (12.2)'
BEGIN
  DECLARE v_fy          SMALLINT;
  DECLARE v_q           TINYINT;
  DECLARE v_from        DATE;
  DECLARE v_to          DATE;
  DECLARE v_today       DATE;
  DECLARE v_month_start DATE;
  DECLARE v_month_end   DATE;
  DECLARE v_week_start  DATE;
  DECLARE v_all         TINYINT;
  DECLARE v_tile        VARCHAR(20) DEFAULT UPPER(TRIM(p_tile));
  DECLARE v_key         VARCHAR(40) DEFAULT UPPER(TRIM(p_key));
  DECLARE v_key_id      BIGINT UNSIGNED DEFAULT NULL;

  IF v_tile NOT IN ('OPEN', 'STAGE', 'SOURCE', 'NEW', 'THIS_MONTH', 'COMMIT', 'OVERDUE',
                    'WON', 'LOST', 'LOSS_REASON', 'PARTNER') THEN
    CALL spi_raise('NOT_FOUND', 'Unknown dashboard tile.', 'tile');
  END IF;
  IF v_tile IN ('STAGE', 'SOURCE', 'COMMIT', 'LOSS_REASON', 'PARTNER') AND NULLIF(TRIM(p_key), '') IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'This tile needs a key.', 'key');
  END IF;
  IF v_tile IN ('LOSS_REASON', 'PARTNER') AND TRIM(p_key) NOT REGEXP '^[0-9]{1,18}$' THEN
    CALL spi_raise('VALIDATION_FAILED', 'The key must be an id.', 'key');
  END IF;
  IF v_tile IN ('LOSS_REASON', 'PARTNER') THEN
    SET v_key_id = CAST(v_key AS UNSIGNED);
  END IF;

  CALL spi_dashboard_period(p_fiscal_year, p_quarter, v_fy, v_q, v_from, v_to, v_today);
  SET v_month_start = v_today - INTERVAL (DAY(v_today) - 1) DAY;
  SET v_month_end = LAST_DAY(v_today);
  SET v_week_start = v_today - INTERVAL WEEKDAY(v_today) DAY;

  CALL spi_dashboard_scope(p_user_id, p_source, p_product_id, p_industry_id, p_owner_user_id, p_partner_id, v_all);

  DROP TEMPORARY TABLE IF EXISTS tmp_dash_rows;
  CREATE TEMPORARY TABLE tmp_dash_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY, sort_value DECIMAL(18,2) NOT NULL);

  INSERT INTO tmp_dash_rows (id, sort_value)
  SELECT o.id,
         IF(v_tile IN ('WON', 'LOST', 'LOSS_REASON'),
            COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate,
            o.weighted_value)
    FROM tmp_dash_opp t
    JOIN opportunity o ON o.id = t.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE CASE v_tile
           WHEN 'OPEN' THEN s.is_open = 1 AND o.expected_close_date BETWEEN v_from AND v_to
           WHEN 'STAGE' THEN s.is_open = 1 AND o.expected_close_date BETWEEN v_from AND v_to
                             AND o.stage_code = v_key
           WHEN 'SOURCE' THEN s.is_open = 1 AND o.expected_close_date BETWEEN v_from AND v_to
                              AND o.source = v_key
           WHEN 'NEW' THEN DATE(o.created_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to
           WHEN 'THIS_MONTH' THEN s.is_open = 1 AND o.expected_close_date BETWEEN v_month_start AND v_month_end
           WHEN 'COMMIT' THEN EXISTS (
                  SELECT 1 FROM monthly_commit mc
                   WHERE mc.opportunity_id = o.id AND mc.commit_month = v_month_start
                     AND mc.commit_type = v_key)
           WHEN 'OVERDUE' THEN s.is_open = 1 AND o.created_at < v_week_start AND NOT EXISTS (
                  SELECT 1 FROM weekly_status ws
                   WHERE ws.opportunity_id = o.id AND ws.week_start >= v_week_start - INTERVAL 7 DAY)
           WHEN 'WON' THEN o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to
           WHEN 'LOST' THEN o.stage_code = 'LOST' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to
           WHEN 'LOSS_REASON' THEN o.stage_code = 'LOST'
                  AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to
                  AND EXISTS (SELECT 1 FROM win_loss wl
                               WHERE wl.opportunity_id = o.id AND wl.loss_reason_id = v_key_id)
           WHEN 'PARTNER' THEN EXISTS (
                  SELECT 1 FROM opportunity_partner op
                   WHERE op.opportunity_id = o.id AND op.partner_id = v_key_id)
                  AND ((s.is_open = 1 AND o.expected_close_date BETWEEN v_from AND v_to)
                       OR (o.stage_code IN ('WON', 'LOST')
                           AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to))
           ELSE 0
         END;

  CALL spi_dashboard_rows(GREATEST(IFNULL(p_offset, 0), 0), LEAST(GREATEST(IFNULL(p_limit, 25), 1), 100));
  SELECT COUNT(*) AS total FROM tmp_dash_rows;

  DROP TEMPORARY TABLE IF EXISTS tmp_dash_rows;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

DELIMITER ;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V007', 'Management dashboard v1 procedures', 'V007__sp_dashboard.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
