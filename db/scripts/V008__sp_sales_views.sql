-- =============================================================================
-- V008  Sales CRM - sales screens, read side (M04-M07, M11)          (2026-10-12)
--
--   My day (tasks and what needs attention), Leads (list, lead page with the six
--   qualification facts), Opportunities (list, kanban, deal workspace), Accounts
--   (list, Account 360) and Forecast & status (weekly status, monthly closure,
--   hierarchy funnel). Read-only: create / edit / stage moves come with the rest of
--   Phase 1 (decision D-27).
--
--   Every list and record is limited to the user's data scope (10.8):
--     * deals:    spi_dashboard_scope (redefined here: Finance, MODULE_LIMITED on
--                 ORDERS, also sees the header of deals that have an order, OD-11)
--     * leads:    owner / backup in the user's tree, or a partner owned by the tree
--     * accounts: owner / backup in the tree, or at least one visible deal (rule 4)
--   A record outside the scope raises NOT_FOUND (rule 5: 404, no information leak).
--   Money columns are DECIMAL(18,2) in INR (OD-27, OD-51).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V007.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- spi_dashboard_scope (replaces the V007 version): + Finance sees deals with an order
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
  DECLARE v_orders   TINYINT DEFAULT 0;

  CALL spi_scope_flags(p_user_id, o_all, v_own, v_assigned, v_partner, v_module);
  IF o_all = 0 AND v_module = 1 THEN
    IF EXISTS (SELECT 1 FROM user_role ur JOIN role_module_scope rms ON rms.role_id = ur.role_id
                WHERE ur.user_id = p_user_id AND rms.module = 'OPPORTUNITIES') THEN
      SET o_all = 1;
    ELSEIF EXISTS (SELECT 1 FROM user_role ur JOIN role_module_scope rms ON rms.role_id = ur.role_id
                    WHERE ur.user_id = p_user_id AND rms.module = 'ORDERS') THEN
      SET v_orders = 1;
    END IF;
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
                 WHERE op.opportunity_id = o.id))
          OR (v_orders = 1 AND EXISTS (SELECT 1 FROM sales_order so WHERE so.opportunity_id = o.id)))
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
-- spi_visible_leads: tmp_vis_lead = the active leads the user may see
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_visible_leads $$
CREATE PROCEDURE spi_visible_leads(IN p_user_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all      TINYINT;
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;

  CALL spi_scope_flags(p_user_id, v_all, v_own, v_assigned, v_partner, v_module);

  DROP TEMPORARY TABLE IF EXISTS tmp_vis_lead;
  CREATE TEMPORARY TABLE tmp_vis_lead (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);

  INSERT INTO tmp_vis_lead (id)
  SELECT l.id
    FROM sales_lead l
   WHERE l.is_active = 1
     AND (v_all = 1
          OR (v_own = 1 AND EXISTS (
                SELECT 1 FROM user_hierarchy h
                 WHERE h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (l.owner_user_id, IFNULL(l.backup_owner_user_id, 0))))
          OR (v_partner = 1 AND l.partner_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM partner p
                  JOIN user_hierarchy h ON h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (p.relationship_owner_user_id, IFNULL(p.backup_owner_user_id, 0))
                 WHERE p.id = l.partner_id)));
END $$

-- -----------------------------------------------------------------------------
-- spi_visible_accounts: tmp_vis_acc = the accounts the user may see (rule 4);
-- also leaves tmp_dash_opp with the user's visible deals
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_visible_accounts $$
CREATE PROCEDURE spi_visible_accounts(IN p_user_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all      TINYINT;
  DECLARE v_deal_all TINYINT;
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;

  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_deal_all);
  CALL spi_scope_flags(p_user_id, v_all, v_own, v_assigned, v_partner, v_module);

  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  CREATE TEMPORARY TABLE tmp_vis_acc (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);

  INSERT INTO tmp_vis_acc (id)
  SELECT a.id
    FROM account a
   WHERE a.is_active = 1 AND a.deleted_at IS NULL
     AND (v_all = 1
          OR (v_own = 1 AND EXISTS (
                SELECT 1 FROM user_hierarchy h
                 WHERE h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (a.owner_user_id, IFNULL(a.backup_owner_user_id, 0))))
          OR EXISTS (SELECT 1 FROM opportunity o JOIN tmp_dash_opp t ON t.id = o.id WHERE o.account_id = a.id));
END $$

-- -----------------------------------------------------------------------------
-- spi_like: a LIKE pattern for a search text (wildcards in the text are escaped)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_like $$
CREATE PROCEDURE spi_like(IN p_search VARCHAR(100), OUT o_search VARCHAR(100), OUT o_like VARCHAR(310))
  SQL SECURITY DEFINER
BEGIN
  SET o_search = NULLIF(TRIM(p_search), '');
  SET o_like = CONCAT('%', REPLACE(REPLACE(REPLACE(IFNULL(o_search, ''), '\\', '\\\\'), '%', '\\%'), '_', '\\_'), '%');
END $$

-- =============================================================================
-- LEADS (M05)
-- =============================================================================

-- sp_lead_list: rows, { total }, counts per stage (for the stage chips)
DROP PROCEDURE IF EXISTS sp_lead_list $$
CREATE PROCEDURE sp_lead_list(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_search        VARCHAR(100),
  IN p_stage         VARCHAR(20),
  IN p_source        VARCHAR(10),
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_sort          VARCHAR(30),
  IN p_offset        INT,
  IN p_limit         INT
)
  SQL SECURITY DEFINER
  COMMENT 'Leads inside the user scope (12.4)'
BEGIN
  DECLARE v_search VARCHAR(100);
  DECLARE v_like   VARCHAR(310);
  DECLARE v_today  DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  CALL spi_like(p_search, v_search, v_like);
  CALL spi_visible_leads(p_user_id);

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  CREATE TEMPORARY TABLE tmp_list (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_list (id)
  SELECT l.id
    FROM sales_lead l
    JOIN tmp_vis_lead v ON v.id = l.id
    LEFT JOIN account a ON a.id = l.account_id
   WHERE (v_search IS NULL OR l.lead_no LIKE v_like OR l.contact_name LIKE v_like
          OR a.name LIKE v_like OR l.account_name_text LIKE v_like OR l.city LIKE v_like)
     AND (p_source IS NULL OR l.source = p_source)
     AND (p_owner_user_id IS NULL OR EXISTS (
            SELECT 1 FROM user_hierarchy h
             WHERE h.ancestor_user_id = p_owner_user_id AND h.descendant_user_id = l.owner_user_id));

  SELECT l.id, l.lead_no AS leadNo, l.stage_code AS stageCode, s.name AS stageName, l.source,
         p.short_name AS partnerName, l.account_id AS accountId,
         COALESCE(a.name, l.account_name_text) AS accountName,
         l.contact_name AS contactName, l.contact_designation AS contactDesignation, l.city,
         i.name AS industryName, u.full_name AS ownerName,
         CAST(l.rough_value AS DECIMAL(18,2)) AS roughValue, l.rough_timing AS roughTiming,
         l.next_action AS nextAction, l.next_action_due_on AS nextActionDueOn,
         (l.stage_code IN ('NEW', 'CONTACTED', 'QUALIFYING') AND l.next_action_due_on < v_today) AS isOverdue,
         l.qualification_pct AS qualificationPct, l.opportunity_id AS opportunityId,
         o.opportunity_no AS opportunityNo, l.created_at AS createdAt
    FROM sales_lead l
    JOIN tmp_list t ON t.id = l.id
    LEFT JOIN stage s ON s.entity = 'LEAD' AND s.code = l.stage_code
    LEFT JOIN partner p ON p.id = l.partner_id
    LEFT JOIN account a ON a.id = l.account_id
    LEFT JOIN industry i ON i.id = l.industry_id
    LEFT JOIN opportunity o ON o.id = l.opportunity_id
    JOIN `user` u ON u.id = l.owner_user_id
   WHERE p_stage IS NULL OR l.stage_code = p_stage
   ORDER BY
     CASE WHEN p_sort = 'nextActionDueOn'  THEN l.next_action_due_on END ASC,
     CASE WHEN p_sort = '-nextActionDueOn' THEN l.next_action_due_on END DESC,
     CASE WHEN p_sort = 'roughValue'       THEN l.rough_value END ASC,
     CASE WHEN p_sort = '-roughValue'      THEN l.rough_value END DESC,
     CASE WHEN p_sort = 'accountName'      THEN COALESCE(a.name, l.account_name_text) END ASC,
     CASE WHEN p_sort = 'createdAt'        THEN l.created_at END ASC,
     l.created_at DESC, l.id DESC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total
    FROM sales_lead l JOIN tmp_list t ON t.id = l.id
   WHERE p_stage IS NULL OR l.stage_code = p_stage;

  SELECT s.code AS stageCode, s.name AS stageName, CAST(COUNT(x.id) AS SIGNED) AS count
    FROM stage s
    LEFT JOIN (SELECT l.id, l.stage_code FROM sales_lead l JOIN tmp_list t ON t.id = l.id) x
      ON x.stage_code = s.code
   WHERE s.entity = 'LEAD'
   GROUP BY s.code, s.name, s.sequence_no
   ORDER BY s.sequence_no;

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_lead;
END $$

-- sp_lead_get: lead, the six facts (BR-LD-05), products, DMU, competitors,
-- activities, tasks, stage history
DROP PROCEDURE IF EXISTS sp_lead_get $$
CREATE PROCEDURE sp_lead_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Lead page with the qualification facts (12.4)'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;

  CALL spi_visible_leads(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_lead WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_lead;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Lead not found.', 'id');
  END IF;

  SELECT l.id, l.lead_no AS leadNo, l.stage_code AS stageCode, s.name AS stageName,
         l.stage_entered_at AS stageEnteredAt, l.source, l.partner_id AS partnerId,
         p.short_name AS partnerName, l.partner_contact_text AS partnerContact,
         l.account_id AS accountId, COALESCE(a.name, l.account_name_text) AS accountName,
         (l.account_id IS NULL) AS isNewAccount, i.name AS industryName,
         l.contact_name AS contactName, l.contact_designation AS contactDesignation,
         l.contact_email AS contactEmail, l.contact_phone AS contactPhone, l.city,
         l.locations_count AS locationsCount, l.need_text AS needText,
         CAST(l.rough_value AS DECIMAL(18,2)) AS roughValue, l.rough_timing AS roughTiming,
         u.full_name AS ownerName, b.full_name AS backupOwnerName,
         l.next_action AS nextAction, l.next_action_due_on AS nextActionDueOn,
         l.problem_statement AS problemStatement, pr.name AS productName, so.name AS solutionName,
         CAST(l.commercial_window_value AS DECIMAL(18,2)) AS commercialWindowValue,
         l.budget_known AS budgetKnown, CAST(l.budget_min AS DECIMAL(18,2)) AS budgetMin,
         CAST(l.budget_max AS DECIMAL(18,2)) AS budgetMax, pt.name AS procurementTypeName,
         l.procurement_steps_known AS procurementStepsKnown, l.expected_close_date AS expectedCloseDate,
         l.qualification_pct AS qualificationPct, r.name AS disqualifyReason,
         l.disqualify_note AS disqualifyNote, l.disqualified_at AS disqualifiedAt,
         l.opportunity_id AS opportunityId, o.opportunity_no AS opportunityNo,
         l.converted_at AS convertedAt, l.last_activity_at AS lastActivityAt,
         l.created_at AS createdAt, cb.full_name AS createdByName
    FROM sales_lead l
    LEFT JOIN stage s ON s.entity = 'LEAD' AND s.code = l.stage_code
    LEFT JOIN partner p ON p.id = l.partner_id
    LEFT JOIN account a ON a.id = l.account_id
    LEFT JOIN industry i ON i.id = l.industry_id
    LEFT JOIN product pr ON pr.id = l.product_id
    LEFT JOIN solution so ON so.id = l.solution_id
    LEFT JOIN procurement_type pt ON pt.id = l.procurement_type_id
    LEFT JOIN reason r ON r.id = l.disqualify_reason_id
    LEFT JOIN opportunity o ON o.id = l.opportunity_id
    LEFT JOIN `user` b ON b.id = l.backup_owner_user_id
    LEFT JOIN `user` cb ON cb.id = l.created_by
    JOIN `user` u ON u.id = l.owner_user_id
   WHERE l.id = p_id;

  -- the six qualification facts (BR-LD-05); conversion needs 6 / 6 (BR-LD-06)
  SELECT 1 AS seq, 'PROBLEM' AS code, 'Problem statement' AS label,
         (NULLIF(TRIM(l.problem_statement), '') IS NOT NULL) AS done
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 2, 'SOLUTION', 'Solution mapped (product + solution)',
         (l.product_id IS NOT NULL AND l.solution_id IS NOT NULL)
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 3, 'COMMERCIAL', 'Commercial window (value + budget)',
         (l.commercial_window_value IS NOT NULL AND l.budget_known IS NOT NULL
          AND (l.budget_known <> 'YES' OR l.budget_min IS NOT NULL OR l.budget_max IS NOT NULL))
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 4, 'DMU', 'DMU: tech buyer, commercial buyer, influencer',
         (EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_id AND d.dmu_role = 'TECH_BUYER')
          AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_id AND d.dmu_role = 'COMM_BUYER')
          AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_id AND d.dmu_role IN ('INFLUENCER_INT', 'INFLUENCER_EXT')))
  UNION ALL
  SELECT 5, 'PROCUREMENT', 'Procurement process known',
         (l.procurement_type_id IS NOT NULL AND l.procurement_steps_known = 1)
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 6, 'CLOSE_DATE', 'Expected closure date', (l.expected_close_date IS NOT NULL)
    FROM sales_lead l WHERE l.id = p_id
  ORDER BY seq;

  SELECT pr.id, pr.name FROM lead_product lp JOIN product pr ON pr.id = lp.product_id
   WHERE lp.lead_id = p_id ORDER BY pr.sort_order, pr.name;

  SELECT d.id, d.name, d.designation, d.dmu_role AS dmuRole, d.influence_level AS influenceLevel,
         d.stand, d.notes
    FROM lead_dmu d WHERE d.lead_id = p_id
   ORDER BY FIELD(d.dmu_role, 'TECH_BUYER', 'COMM_BUYER', 'INFLUENCER_INT', 'INFLUENCER_EXT'), d.id;

  SELECT c.id, c.name FROM lead_competitor lc JOIN competitor c ON c.id = lc.competitor_id
   WHERE lc.lead_id = p_id ORDER BY c.name;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject,
         ac.notes, ac.outcome, ac.people_met AS peopleMet, ac.next_action AS nextAction,
         ac.next_action_on AS nextActionOn, u.full_name AS byName
    FROM activity ac JOIN `user` u ON u.id = ac.by_user_id
   WHERE ac.is_active = 1 AND (ac.lead_id = p_id OR (ac.entity_type = 'LEAD' AND ac.entity_id = p_id))
   ORDER BY ac.activity_at DESC, ac.id DESC
   LIMIT 100;

  SELECT tk.id, tk.task_type AS taskType, tk.title, tk.due_at AS dueAt, tk.status,
         u.full_name AS ownerName
    FROM task tk JOIN `user` u ON u.id = tk.owner_user_id
   WHERE tk.entity_type = 'LEAD' AND tk.entity_id = p_id
   ORDER BY tk.status = 'OPEN' DESC, tk.due_at;

  SELECT sh.id, fs.name AS fromStage, ts.name AS toStage, u.full_name AS changedByName,
         sh.changed_at AS changedAt, sh.reason, sh.days_in_previous AS daysInPrevious
    FROM stage_history sh
    LEFT JOIN stage fs ON fs.entity = 'LEAD' AND fs.code = sh.from_stage
    LEFT JOIN stage ts ON ts.entity = 'LEAD' AND ts.code = sh.to_stage
    LEFT JOIN `user` u ON u.id = sh.changed_by
   WHERE sh.entity_type = 'LEAD' AND sh.entity_id = p_id
   ORDER BY sh.changed_at DESC, sh.id DESC;
END $$

-- =============================================================================
-- OPPORTUNITIES (M06)
-- =============================================================================

-- spi_opportunity_filter: tmp_list = visible deals matching search / source / owner / partner
DROP PROCEDURE IF EXISTS spi_opportunity_filter $$
CREATE PROCEDURE spi_opportunity_filter(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_search        VARCHAR(100),
  IN p_source        VARCHAR(10),
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all    TINYINT;
  DECLARE v_search VARCHAR(100);
  DECLARE v_like   VARCHAR(310);

  CALL spi_like(p_search, v_search, v_like);
  CALL spi_dashboard_scope(p_user_id, p_source, NULL, NULL, p_owner_user_id, p_partner_id, v_all);

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  CREATE TEMPORARY TABLE tmp_list (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_list (id)
  SELECT o.id
    FROM opportunity o
    JOIN tmp_dash_opp t ON t.id = o.id
    JOIN account a ON a.id = o.account_id
   WHERE v_search IS NULL OR o.opportunity_no LIKE v_like OR o.title LIKE v_like OR a.name LIKE v_like;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

-- sp_opportunity_list: rows, { total }, counts per view (OPEN / WON / LOST / DORMANT)
DROP PROCEDURE IF EXISTS sp_opportunity_list $$
CREATE PROCEDURE sp_opportunity_list(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_search        VARCHAR(100),
  IN p_view          VARCHAR(10),
  IN p_stage         VARCHAR(20),
  IN p_source        VARCHAR(10),
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_sort          VARCHAR(30),
  IN p_offset        INT,
  IN p_limit         INT
)
  SQL SECURITY DEFINER
  COMMENT 'Deals inside the user scope (12.5)'
BEGIN
  DECLARE v_view VARCHAR(10) DEFAULT IFNULL(NULLIF(p_view, ''), 'OPEN');

  CALL spi_opportunity_filter(p_user_id, p_search, p_source, p_owner_user_id, p_partner_id);

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  CREATE TEMPORARY TABLE tmp_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_rows (id)
  SELECT o.id
    FROM opportunity o
    JOIN tmp_list t ON t.id = o.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE (v_view = 'ALL'
          OR (v_view = 'OPEN' AND s.is_open = 1)
          OR o.stage_code = v_view)
     AND (p_stage IS NULL OR o.stage_code = p_stage);

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, o.account_id AS accountId,
         a.name AS accountName,
         (SELECT COALESCE(p.short_name, p.legal_name)
            FROM opportunity_partner op JOIN partner p ON p.id = op.partner_id
           WHERE op.opportunity_id = o.id ORDER BY op.is_primary DESC, op.id LIMIT 1) AS partnerName,
         (SELECT GROUP_CONCAT(pr.name ORDER BY opr.is_primary DESC, pr.name SEPARATOR ', ')
            FROM opportunity_product opr JOIN product pr ON pr.id = opr.product_id
           WHERE opr.opportunity_id = o.id) AS products,
         u.full_name AS ownerName, ps.full_name AS presalesName,
         o.stage_code AS stageCode, s.name AS stageName, o.source,
         COALESCE(o.confidence_override_pct, s.default_confidence_pct) AS confidencePct,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(o.weighted_value AS DECIMAL(18,2)) AS weighted,
         CAST(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate AS DECIMAL(18,2)) AS closedValue,
         o.expected_close_date AS expectedCloseDate, o.closed_at AS closedAt,
         o.validation_status AS validationStatus, o.health, o.last_activity_at AS lastActivityAt,
         (SELECT ws.status FROM weekly_status ws WHERE ws.opportunity_id = o.id
           ORDER BY ws.week_start DESC LIMIT 1) AS lastStatus,
         o.created_at AS createdAt
    FROM opportunity o
    JOIN tmp_rows r ON r.id = o.id
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN `user` ps ON ps.id = o.presales_owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   ORDER BY
     CASE WHEN p_sort = 'value'              THEN o.expected_value * o.fx_rate END ASC,
     CASE WHEN p_sort = '-value'             THEN o.expected_value * o.fx_rate END DESC,
     CASE WHEN p_sort = '-weighted'          THEN o.weighted_value END DESC,
     CASE WHEN p_sort = 'expectedCloseDate'  THEN o.expected_close_date END ASC,
     CASE WHEN p_sort = '-expectedCloseDate' THEN o.expected_close_date END DESC,
     CASE WHEN p_sort = '-closedAt'          THEN o.closed_at END DESC,
     CASE WHEN p_sort = 'title'              THEN o.title END ASC,
     CASE WHEN p_sort = '-createdAt'         THEN o.created_at END DESC,
     o.weighted_value DESC, o.id DESC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total FROM tmp_rows;

  SELECT CAST(IFNULL(SUM(s.is_open = 1), 0) AS SIGNED) AS open,
         CAST(IFNULL(SUM(o.stage_code = 'WON'), 0) AS SIGNED) AS won,
         CAST(IFNULL(SUM(o.stage_code = 'LOST'), 0) AS SIGNED) AS lost,
         CAST(IFNULL(SUM(o.stage_code = 'DORMANT'), 0) AS SIGNED) AS dormant,
         CAST(COUNT(*) AS SIGNED) AS `all`,
         CAST(IFNULL(SUM(IF(s.is_open = 1, o.expected_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS openValue,
         CAST(IFNULL(SUM(IF(s.is_open = 1, o.weighted_value, 0)), 0) AS DECIMAL(18,2)) AS openWeighted
    FROM opportunity o
    JOIN tmp_list t ON t.id = o.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code;

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  DROP TEMPORARY TABLE IF EXISTS tmp_list;
END $$

-- sp_opportunity_kanban: open-stage columns with totals, and up to 50 cards per column
DROP PROCEDURE IF EXISTS sp_opportunity_kanban $$
CREATE PROCEDURE sp_opportunity_kanban(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_search        VARCHAR(100),
  IN p_source        VARCHAR(10),
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
  COMMENT 'Kanban by stage, no drag across stages (12.5)'
BEGIN
  CALL spi_opportunity_filter(p_user_id, p_search, p_source, p_owner_user_id, p_partner_id);

  SELECT s.code AS stageCode, s.name AS stageName, s.default_confidence_pct AS confidencePct,
         CAST(IFNULL(x.cnt, 0) AS SIGNED) AS count,
         CAST(IFNULL(x.val, 0) AS DECIMAL(18,2)) AS value,
         CAST(IFNULL(x.wt, 0) AS DECIMAL(18,2)) AS weighted
    FROM stage s
    LEFT JOIN (
      SELECT o.stage_code, COUNT(*) AS cnt, SUM(o.expected_value * o.fx_rate) AS val, SUM(o.weighted_value) AS wt
        FROM opportunity o JOIN tmp_list t ON t.id = o.id
       GROUP BY o.stage_code
    ) x ON x.stage_code = s.code
   WHERE s.entity = 'OPP' AND s.is_open = 1 AND s.is_active = 1
   ORDER BY s.sequence_no;

  SELECT k.* FROM (
    SELECT o.id, o.stage_code AS stageCode, o.opportunity_no AS opportunityNo, o.title,
           a.name AS accountName, u.full_name AS ownerName,
           (SELECT COALESCE(p.short_name, p.legal_name)
              FROM opportunity_partner op JOIN partner p ON p.id = op.partner_id
             WHERE op.opportunity_id = o.id ORDER BY op.is_primary DESC, op.id LIMIT 1) AS partnerName,
           CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
           CAST(o.weighted_value AS DECIMAL(18,2)) AS weighted,
           o.expected_close_date AS expectedCloseDate, o.health, o.validation_status AS validationStatus,
           ROW_NUMBER() OVER (PARTITION BY o.stage_code ORDER BY o.expected_value * o.fx_rate DESC, o.id) AS rn
      FROM opportunity o
      JOIN tmp_list t ON t.id = o.id
      JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
      JOIN account a ON a.id = o.account_id
      JOIN `user` u ON u.id = o.owner_user_id
  ) k
   WHERE k.rn <= 50
   ORDER BY k.stageCode, k.rn;

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
END $$

-- sp_opportunity_get: the deal workspace (12.5). Result sets:
--   deal, stages, products, dmu, partners, competitors, poc, offers, partnerCommercials,
--   activities, weeklyStatus, monthlyCommits, stageHistory, winLoss, tasks
DROP PROCEDURE IF EXISTS sp_opportunity_get $$
CREATE PROCEDURE sp_opportunity_get(
  IN p_user_id            BIGINT UNSIGNED,
  IN p_id                 BIGINT UNSIGNED,
  IN p_can_see_commercial TINYINT
)
  SQL SECURITY DEFINER
  COMMENT 'Deal workspace, read side (12.5)'
BEGIN
  DECLARE v_all     TINYINT;
  DECLARE v_visible TINYINT DEFAULT 0;
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);
  SELECT COUNT(*) INTO v_visible FROM tmp_dash_opp WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
  END IF;

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, o.account_id AS accountId,
         a.name AS accountName, a.is_strategic AS accountStrategic, o.source,
         i.name AS industryName, so.name AS solutionName,
         (SELECT GROUP_CONCAT(pr.name ORDER BY opr.is_primary DESC, pr.name SEPARATOR ', ')
            FROM opportunity_product opr JOIN product pr ON pr.id = opr.product_id
           WHERE opr.opportunity_id = o.id) AS products,
         o.problem_statement AS problemStatement, o.technical_requirement AS technicalRequirement,
         o.locations_count AS locationsCount,
         o.stage_code AS stageCode, s.name AS stageName, s.is_open AS isOpen,
         o.stage_entered_at AS stageEnteredAt,
         DATEDIFF(v_today, DATE(o.stage_entered_at + INTERVAL 330 MINUTE)) AS daysInStage,
         s.sla_days AS stageSlaDays,
         COALESCE(o.confidence_override_pct, s.default_confidence_pct) AS confidencePct,
         o.confidence_override_reason AS confidenceOverrideReason,
         o.currency, o.fx_rate AS fxRate,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(o.weighted_value AS DECIMAL(18,2)) AS weighted,
         o.expected_close_date AS expectedCloseDate, o.close_date_change_count AS closeDateChangeCount,
         CAST(o.commercial_window_value AS DECIMAL(18,2)) AS commercialWindowValue,
         o.commercial_window_accepted AS commercialWindowAccepted, o.budget_known AS budgetKnown,
         CAST(o.budget_min AS DECIMAL(18,2)) AS budgetMin, CAST(o.budget_max AS DECIMAL(18,2)) AS budgetMax,
         pt.name AS procurementTypeName, pst.name AS procurementStepName,
         o.validation_status AS validationStatus, vb.full_name AS validatedByName,
         o.validated_at AS validatedAt, o.validation_remark AS validationRemark,
         u.full_name AS ownerName, bu.full_name AS backupOwnerName,
         ps.full_name AS presalesName, sp.full_name AS sponsorName,
         o.partner_tbm AS partnerTbm, o.no_competition AS noCompetition,
         CAST(o.final_value AS DECIMAL(18,2)) AS finalValue, o.payment_terms AS paymentTerms,
         o.po_number AS poNumber, o.po_date AS poDate, CAST(o.po_value AS DECIMAL(18,2)) AS poValue,
         o.closed_at AS closedAt, dr.name AS dormantReason, o.dormant_note AS dormantNote,
         o.wake_up_date AS wakeUpDate, o.bundle_tag AS bundleTag, o.health,
         o.last_activity_at AS lastActivityAt, o.last_status_at AS lastStatusAt,
         o.lead_id AS leadId, l.lead_no AS leadNo,
         (SELECT so2.id FROM sales_order so2 WHERE so2.opportunity_id = o.id LIMIT 1) AS orderId,
         o.created_at AS createdAt, cb.full_name AS createdByName
    FROM opportunity o
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
    LEFT JOIN industry i ON i.id = COALESCE(o.industry_id, a.industry_id)
    LEFT JOIN solution so ON so.id = o.solution_id
    LEFT JOIN procurement_type pt ON pt.id = o.procurement_type_id
    LEFT JOIN procurement_step pst ON pst.id = o.current_procurement_step_id
    LEFT JOIN `user` vb ON vb.id = o.validated_by
    LEFT JOIN `user` bu ON bu.id = o.backup_owner_user_id
    LEFT JOIN `user` ps ON ps.id = o.presales_owner_user_id
    LEFT JOIN `user` sp ON sp.id = o.sponsor_user_id
    LEFT JOIN `user` cb ON cb.id = o.created_by
    LEFT JOIN reason dr ON dr.id = o.dormant_reason_id
    LEFT JOIN sales_lead l ON l.id = o.lead_id
   WHERE o.id = p_id;

  -- the stepper
  SELECT code, name, sequence_no AS sequenceNo, default_confidence_pct AS confidencePct,
         is_open AS isOpen, is_won AS isWon, is_lost AS isLost
    FROM stage WHERE entity = 'OPP' AND is_active = 1 ORDER BY sequence_no;

  SELECT pr.id, pr.name, opr.is_primary AS isPrimary
    FROM opportunity_product opr JOIN product pr ON pr.id = opr.product_id
   WHERE opr.opportunity_id = p_id ORDER BY opr.is_primary DESC, pr.name;

  SELECT d.id, c.id AS contactId, c.name, c.designation, c.department, c.email, c.phone,
         d.dmu_role AS dmuRole, d.influence_level AS influenceLevel, d.stand, d.notes
    FROM opportunity_dmu d JOIN contact c ON c.id = d.contact_id
   WHERE d.opportunity_id = p_id
   ORDER BY FIELD(d.dmu_role, 'TECH_BUYER', 'COMM_BUYER', 'SPONSOR', 'INFLUENCER_INT', 'INFLUENCER_EXT'), d.id;

  SELECT op.id, p.id AS partnerId, p.partner_no AS partnerNo,
         COALESCE(p.short_name, p.legal_name) AS partnerName, p.tier,
         op.partner_role AS partnerRole, op.engagement_level AS engagementLevel,
         op.is_primary AS isPrimary, op.commercial_confirmed AS commercialConfirmed, op.notes
    FROM opportunity_partner op JOIN partner p ON p.id = op.partner_id
   WHERE op.opportunity_id = p_id
   ORDER BY op.is_primary DESC, op.id;

  SELECT oc.id, c.name, CAST(oc.their_price AS DECIMAL(18,2)) AS theirPrice,
         oc.their_strength AS theirStrength, oc.our_differentiator AS ourDifferentiator
    FROM opportunity_competitor oc JOIN competitor c ON c.id = oc.competitor_id
   WHERE oc.opportunity_id = p_id ORDER BY c.name;

  SELECT pc.id, pc.external_poc_ref AS externalPocRef, pc.status, pc.start_date AS startDate,
         pc.end_date AS endDate, pc.success_criteria AS successCriteria, pc.exit_criteria AS exitCriteria,
         c.name AS customerLeadName, u.full_name AS cnergeeLeadName, pc.result,
         pc.customer_validated AS customerValidated, pc.readout_date AS readoutDate,
         pc.skipped, pc.skip_reason AS skipReason, pc.notes
    FROM opportunity_poc pc
    LEFT JOIN contact c ON c.id = pc.customer_lead_contact_id
    LEFT JOIN `user` u ON u.id = pc.cnergee_lead_user_id
   WHERE pc.opportunity_id = p_id;

  SELECT f.id, f.version_no AS versionNo, f.offer_no AS offerNo,
         CAST(f.offer_value AS DECIMAL(18,2)) AS offerValue, CAST(f.list_value AS DECIMAL(18,2)) AS listValue,
         f.discount_pct AS discountPct, f.value_adds AS valueAdds, f.payment_terms AS paymentTerms,
         f.valid_till AS validTill, f.status, f.approval_required AS approvalRequired,
         sb.full_name AS submittedByName, f.submitted_at AS submittedAt,
         ab.full_name AS approvedByName, f.approved_at AS approvedAt, f.approval_remark AS approvalRemark,
         f.sent_at AS sentAt, f.sent_to AS sentTo, f.customer_response AS customerResponse,
         f.customer_responded_at AS customerRespondedAt, f.created_at AS createdAt
    FROM offer f
    LEFT JOIN `user` sb ON sb.id = f.submitted_by
    LEFT JOIN `user` ab ON ab.id = f.approved_by
   WHERE f.opportunity_id = p_id
   ORDER BY f.version_no DESC;

  -- partner commercial: only for holders of partner_commercial.view (BR-OP-13, OD-31)
  SELECT pc.id, COALESCE(p.short_name, p.legal_name) AS partnerName, pc.partner_role AS partnerRole,
         pc.version_no AS versionNo, pc.deal_size_basis AS dealSizeBasis,
         CAST(pc.price_to_partner AS DECIMAL(18,2)) AS priceToPartner,
         pc.partner_margin_pct AS partnerMarginPct, pc.payment_terms AS paymentTerms,
         pc.pay_partner_after_customer AS payPartnerAfterCustomer, pc.valid_till AS validTill,
         pc.remarks, pc.created_at AS createdAt, u.full_name AS createdByName
    FROM partner_commercial pc
    JOIN partner p ON p.id = pc.partner_id
    LEFT JOIN `user` u ON u.id = pc.created_by
   WHERE pc.opportunity_id = p_id AND p_can_see_commercial = 1
   ORDER BY p.short_name, pc.version_no DESC;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject,
         ac.notes, ac.outcome, ac.people_met AS peopleMet, ac.next_action AS nextAction,
         ac.next_action_on AS nextActionOn, u.full_name AS byName
    FROM activity ac JOIN `user` u ON u.id = ac.by_user_id
   WHERE ac.is_active = 1 AND (ac.opportunity_id = p_id OR (ac.entity_type = 'OPP' AND ac.entity_id = p_id))
   ORDER BY ac.activity_at DESC, ac.id DESC
   LIMIT 100;

  SELECT ws.id, ws.week_start AS weekStart, ws.status, ws.this_week AS thisWeek, ws.next_step AS nextStep,
         ws.expected_close_date AS expectedCloseDate, ws.close_change_reason AS closeChangeReason,
         CAST(ws.expected_value AS DECIMAL(18,2)) AS expectedValue, s.name AS stageName,
         u.full_name AS submittedByName, ws.submitted_at AS submittedAt
    FROM weekly_status ws
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = ws.stage_code
    LEFT JOIN `user` u ON u.id = ws.submitted_by
   WHERE ws.opportunity_id = p_id
   ORDER BY ws.week_start DESC
   LIMIT 26;

  SELECT mc.id, mc.commit_month AS commitMonth, mc.commit_type AS commitType,
         CAST(mc.commit_value AS DECIMAL(18,2)) AS commitValue, mc.achieved
    FROM monthly_commit mc WHERE mc.opportunity_id = p_id ORDER BY mc.commit_month DESC;

  SELECT sh.id, fs.name AS fromStage, ts.name AS toStage, sh.to_stage AS toStageCode,
         u.full_name AS changedByName, sh.changed_at AS changedAt, sh.reason,
         sh.days_in_previous AS daysInPrevious, sh.was_override AS wasOverride
    FROM stage_history sh
    LEFT JOIN stage fs ON fs.entity = 'OPP' AND fs.code = sh.from_stage
    LEFT JOIN stage ts ON ts.entity = 'OPP' AND ts.code = sh.to_stage
    LEFT JOIN `user` u ON u.id = sh.changed_by
   WHERE sh.entity_type = 'OPP' AND sh.entity_id = p_id
   ORDER BY sh.changed_at DESC, sh.id DESC;

  SELECT wl.outcome, lr.name AS lossReason, c.name AS competitorName, wl.detail, wl.lesson,
         wl.competition_replaced AS competitionReplaced, wl.remarks,
         (SELECT GROUP_CONCAT(r.name ORDER BY r.sort_order SEPARATOR ', ')
            FROM win_loss_reason wr JOIN reason r ON r.id = wr.reason_id
           WHERE wr.opportunity_id = wl.opportunity_id) AS winReasons,
         u.full_name AS recordedByName, wl.recorded_at AS recordedAt
    FROM win_loss wl
    LEFT JOIN reason lr ON lr.id = wl.loss_reason_id
    LEFT JOIN competitor c ON c.id = wl.competitor_id
    LEFT JOIN `user` u ON u.id = wl.recorded_by
   WHERE wl.opportunity_id = p_id;

  SELECT tk.id, tk.task_type AS taskType, tk.title, tk.due_at AS dueAt, tk.status,
         u.full_name AS ownerName
    FROM task tk JOIN `user` u ON u.id = tk.owner_user_id
   WHERE tk.entity_type = 'OPP' AND tk.entity_id = p_id
   ORDER BY tk.status = 'OPEN' DESC, tk.due_at;
END $$

-- =============================================================================
-- ACCOUNTS (M07)
-- =============================================================================

-- sp_account_list: rows (with pipeline figures from the visible deals), { total }
DROP PROCEDURE IF EXISTS sp_account_list $$
CREATE PROCEDURE sp_account_list(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_search        VARCHAR(100),
  IN p_type          VARCHAR(12),
  IN p_industry_id   BIGINT UNSIGNED,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_sort          VARCHAR(30),
  IN p_offset        INT,
  IN p_limit         INT
)
  SQL SECURITY DEFINER
  COMMENT 'Accounts inside the user scope (12.6)'
BEGIN
  DECLARE v_search VARCHAR(100);
  DECLARE v_like   VARCHAR(310);

  CALL spi_like(p_search, v_search, v_like);
  CALL spi_visible_accounts(p_user_id);

  -- pipeline per account from the visible deals only
  DROP TEMPORARY TABLE IF EXISTS tmp_acc_agg;
  CREATE TEMPORARY TABLE tmp_acc_agg (
    account_id BIGINT UNSIGNED NOT NULL PRIMARY KEY, open_count INT, open_value DECIMAL(18,2),
    won_count INT, won_value DECIMAL(18,2), last_won DATE
  );
  INSERT INTO tmp_acc_agg
  SELECT o.account_id,
         SUM(s.is_open = 1), SUM(IF(s.is_open = 1, o.expected_value * o.fx_rate, 0)),
         SUM(o.stage_code = 'WON'),
         SUM(IF(o.stage_code = 'WON', COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate, 0)),
         MAX(IF(o.stage_code = 'WON', DATE(o.closed_at + INTERVAL 330 MINUTE), NULL))
    FROM opportunity o
    JOIN tmp_dash_opp t ON t.id = o.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   GROUP BY o.account_id;

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  CREATE TEMPORARY TABLE tmp_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_rows (id)
  SELECT a.id
    FROM account a
    JOIN tmp_vis_acc v ON v.id = a.id
   WHERE (v_search IS NULL OR a.name LIKE v_like OR a.account_no LIKE v_like OR a.city LIKE v_like
          OR a.gst_no LIKE v_like)
     AND (p_type IS NULL OR a.account_type = p_type OR (p_type = 'STRATEGIC' AND a.is_strategic = 1))
     AND (p_industry_id IS NULL OR a.industry_id = p_industry_id)
     AND (p_owner_user_id IS NULL OR EXISTS (
            SELECT 1 FROM user_hierarchy h
             WHERE h.ancestor_user_id = p_owner_user_id AND h.descendant_user_id = a.owner_user_id));

  SELECT a.id, a.account_no AS accountNo, a.name, i.name AS industryName, a.city, a.state,
         a.account_type AS accountType, a.is_strategic AS isStrategic, u.full_name AS ownerName,
         CAST(IFNULL(g.open_count, 0) AS SIGNED) AS openDeals,
         CAST(IFNULL(g.open_value, 0) AS DECIMAL(18,2)) AS openPipeline,
         CAST(IFNULL(g.won_count, 0) AS SIGNED) AS wonDeals,
         CAST(IFNULL(g.won_value, 0) AS DECIMAL(18,2)) AS wonValue,
         g.last_won AS lastWonOn, a.first_won_on AS firstWonOn,
         (SELECT COUNT(*) FROM contact c WHERE c.account_id = a.id AND c.is_active = 1) AS contacts
    FROM account a
    JOIN tmp_rows r ON r.id = a.id
    JOIN `user` u ON u.id = a.owner_user_id
    LEFT JOIN industry i ON i.id = a.industry_id
    LEFT JOIN tmp_acc_agg g ON g.account_id = a.id
   ORDER BY
     CASE WHEN p_sort = 'name'          THEN a.name END ASC,
     CASE WHEN p_sort = '-name'         THEN a.name END DESC,
     CASE WHEN p_sort = '-openPipeline' THEN IFNULL(g.open_value, 0) END DESC,
     CASE WHEN p_sort = '-wonValue'     THEN IFNULL(g.won_value, 0) END DESC,
     IFNULL(g.open_value, 0) DESC, a.name ASC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total FROM tmp_rows;

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  DROP TEMPORARY TABLE IF EXISTS tmp_acc_agg;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

-- sp_account_get: Account 360 (UM 8). Result sets:
--   account, kpis, contacts, opportunities, orders, partners, activities
DROP PROCEDURE IF EXISTS sp_account_get $$
CREATE PROCEDURE sp_account_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Account 360, read side (12.6)'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;

  CALL spi_visible_accounts(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_acc WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  IF v_visible = 0 THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
    CALL spi_raise('NOT_FOUND', 'Account not found.', 'id');
  END IF;

  -- the visible deals of this account
  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  CREATE TEMPORARY TABLE tmp_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_rows (id)
  SELECT o.id FROM opportunity o JOIN tmp_dash_opp t ON t.id = o.id WHERE o.account_id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;

  SELECT a.id, a.account_no AS accountNo, a.name, a.legal_name AS legalName, i.name AS industryName,
         a.segment, a.account_type AS accountType, a.is_strategic AS isStrategic, a.country, a.state,
         a.city, a.address, a.website, a.gst_no AS gstNo, a.locations_count AS locationsCount,
         a.existing_vendor AS existingVendor, u.full_name AS ownerName, b.full_name AS backupOwnerName,
         a.first_won_on AS firstWonOn, a.notes, a.created_at AS createdAt
    FROM account a
    JOIN `user` u ON u.id = a.owner_user_id
    LEFT JOIN `user` b ON b.id = a.backup_owner_user_id
    LEFT JOIN industry i ON i.id = a.industry_id
   WHERE a.id = p_id;

  SELECT CAST(IFNULL(SUM(s.is_open = 1), 0) AS SIGNED) AS openDeals,
         CAST(IFNULL(SUM(IF(s.is_open = 1, o.expected_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS openPipeline,
         CAST(IFNULL(SUM(IF(s.is_open = 1, o.weighted_value, 0)), 0) AS DECIMAL(18,2)) AS weightedPipeline,
         CAST(IFNULL(SUM(o.stage_code = 'WON'), 0) AS SIGNED) AS wonDeals,
         CAST(IFNULL(SUM(IF(o.stage_code = 'WON', COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS wonLifetime,
         CAST(IFNULL(SUM(o.stage_code = 'LOST'), 0) AS SIGNED) AS lostDeals,
         MAX(IF(o.stage_code = 'WON', DATE(o.closed_at + INTERVAL 330 MINUTE), NULL)) AS lastWonOn
    FROM opportunity o
    JOIN tmp_rows r ON r.id = o.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code;

  SELECT c.id, c.name, c.designation, c.department, c.email, c.phone, c.seniority,
         c.influence_level AS influenceLevel, c.stand, c.intel_notes AS intelNotes
    FROM contact c WHERE c.account_id = p_id AND c.is_active = 1
   ORDER BY c.influence_level IS NULL, c.influence_level DESC, c.name;

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, o.stage_code AS stageCode, s.name AS stageName,
         s.is_open AS isOpen, u.full_name AS ownerName, o.source,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(o.weighted_value AS DECIMAL(18,2)) AS weighted,
         CAST(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate AS DECIMAL(18,2)) AS closedValue,
         o.expected_close_date AS expectedCloseDate, o.closed_at AS closedAt, o.health
    FROM opportunity o
    JOIN tmp_rows r ON r.id = o.id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   ORDER BY s.is_open DESC, s.sequence_no DESC, o.expected_close_date;

  SELECT so.id, so.order_no AS orderNo, o.opportunity_no AS opportunityNo, o.title, so.po_number AS poNumber,
         so.po_date AS poDate, CAST(so.po_value AS DECIMAL(18,2)) AS poValue, so.status,
         CAST(so.invoiced_value AS DECIMAL(18,2)) AS invoicedValue,
         CAST(so.received_value AS DECIMAL(18,2)) AS receivedValue
    FROM sales_order so
    JOIN tmp_rows r ON r.id = so.opportunity_id
    JOIN opportunity o ON o.id = so.opportunity_id
   ORDER BY so.po_date DESC;

  SELECT p.id AS partnerId, COALESCE(p.short_name, p.legal_name) AS partnerName, p.tier,
         GROUP_CONCAT(DISTINCT op.partner_role ORDER BY op.partner_role SEPARATOR ', ') AS roles,
         CAST(COUNT(DISTINCT op.opportunity_id) AS SIGNED) AS deals
    FROM opportunity_partner op
    JOIN tmp_rows r ON r.id = op.opportunity_id
    JOIN partner p ON p.id = op.partner_id
   GROUP BY p.id, p.short_name, p.legal_name, p.tier
   ORDER BY deals DESC, partnerName;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject, ac.notes,
         ac.outcome, ac.people_met AS peopleMet, u.full_name AS byName,
         o.opportunity_no AS opportunityNo, o.title AS opportunityTitle
    FROM activity ac
    JOIN `user` u ON u.id = ac.by_user_id
    LEFT JOIN opportunity o ON o.id = ac.opportunity_id
   WHERE ac.is_active = 1
     AND (ac.account_id = p_id OR (ac.entity_type = 'ACCOUNT' AND ac.entity_id = p_id))
     AND (ac.opportunity_id IS NULL OR ac.opportunity_id IN (SELECT id FROM tmp_rows))
   ORDER BY ac.activity_at DESC, ac.id DESC
   LIMIT 50;

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
END $$

-- =============================================================================
-- MY DAY (M04)
-- =============================================================================

-- sp_task_my_day: summary, tasks (open, overdue or due within 7 days),
-- attention (own open deals that need something), validations, offers
DROP PROCEDURE IF EXISTS sp_task_my_day $$
CREATE PROCEDURE sp_task_my_day(
  IN p_user_id     BIGINT UNSIGNED,
  IN p_can_validate TINYINT,
  IN p_can_approve  TINYINT
)
  SQL SECURITY DEFINER
  COMMENT 'My day: tasks and what needs attention (12.3)'
BEGIN
  DECLARE v_all        TINYINT;
  DECLARE v_now_ist    DATETIME(3) DEFAULT UTC_TIMESTAMP(3) + INTERVAL 330 MINUTE;
  DECLARE v_today      DATE;
  DECLARE v_week_start DATE;
  DECLARE v_validations INT DEFAULT 0;
  DECLARE v_offers      INT DEFAULT 0;

  SET v_today = DATE(v_now_ist);
  SET v_week_start = v_today - INTERVAL WEEKDAY(v_today) DAY;

  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);

  -- deals waiting for validation and offers waiting for approval, inside the scope
  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  CREATE TEMPORARY TABLE tmp_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY, kind CHAR(1) NOT NULL);
  IF p_can_validate = 1 THEN
    INSERT INTO tmp_rows (id, kind)
    SELECT o.id, 'V' FROM opportunity o JOIN tmp_dash_opp t ON t.id = o.id
     WHERE o.stage_code = 'QUALIFIED' AND o.validation_status = 'PENDING';
  END IF;
  DROP TEMPORARY TABLE IF EXISTS tmp_offer;
  CREATE TEMPORARY TABLE tmp_offer (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  IF p_can_approve = 1 THEN
    INSERT INTO tmp_offer (id)
    SELECT f.id FROM offer f JOIN tmp_dash_opp t ON t.id = f.opportunity_id
     WHERE f.status = 'PENDING_APPROVAL';
  END IF;
  SELECT COUNT(*) INTO v_validations FROM tmp_rows WHERE kind = 'V';
  SELECT COUNT(*) INTO v_offers FROM tmp_offer;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;

  SELECT CAST(IFNULL(SUM(DATE(tk.due_at + INTERVAL 330 MINUTE) < v_today), 0) AS SIGNED) AS overdue,
         CAST(IFNULL(SUM(DATE(tk.due_at + INTERVAL 330 MINUTE) = v_today), 0) AS SIGNED) AS dueToday,
         CAST(IFNULL(SUM(DATE(tk.due_at + INTERVAL 330 MINUTE) BETWEEN v_today + INTERVAL 1 DAY AND v_today + INTERVAL 7 DAY), 0) AS SIGNED) AS dueThisWeek,
         (SELECT COUNT(*) FROM opportunity o JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
           WHERE o.is_active = 1 AND o.owner_user_id = p_user_id) AS myOpenDeals,
         (SELECT COUNT(*) FROM opportunity o JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
           WHERE o.is_active = 1 AND o.owner_user_id = p_user_id
             AND NOT EXISTS (SELECT 1 FROM weekly_status ws WHERE ws.opportunity_id = o.id AND ws.week_start = v_week_start)) AS statusPending,
         (SELECT COUNT(*) FROM opportunity o JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
           WHERE o.is_active = 1 AND o.owner_user_id = p_user_id AND o.health <> 'ON_TRACK') AS atRisk,
         v_validations AS validationsPending, v_offers AS offersAwaitingApproval,
         v_week_start AS weekStart, v_today AS today
    FROM task tk
   WHERE tk.owner_user_id = p_user_id AND tk.status = 'OPEN';

  SELECT tk.id, tk.task_type AS taskType, tk.title, tk.description, tk.due_at AS dueAt,
         CASE WHEN DATE(tk.due_at + INTERVAL 330 MINUTE) < v_today THEN 'OVERDUE'
              WHEN DATE(tk.due_at + INTERVAL 330 MINUTE) = v_today THEN 'TODAY'
              ELSE 'UPCOMING' END AS bucket,
         tk.entity_type AS entityType, tk.entity_id AS entityId,
         CASE tk.entity_type
           WHEN 'OFFER' THEN 'OPP'
           WHEN 'INVOICE' THEN 'ORDER'
           ELSE tk.entity_type END AS linkType,
         CASE tk.entity_type
           WHEN 'OFFER' THEN (SELECT f.opportunity_id FROM offer f WHERE f.id = tk.entity_id)
           WHEN 'INVOICE' THEN (SELECT i.order_id FROM invoice i WHERE i.id = tk.entity_id)
           ELSE tk.entity_id END AS linkId,
         CASE tk.entity_type
           WHEN 'OPP' THEN (SELECT CONCAT(o.opportunity_no, ' · ', o.title) FROM opportunity o WHERE o.id = tk.entity_id)
           WHEN 'LEAD' THEN (SELECT CONCAT(l.lead_no, ' · ', COALESCE(a.name, l.account_name_text))
                               FROM sales_lead l LEFT JOIN account a ON a.id = l.account_id WHERE l.id = tk.entity_id)
           WHEN 'ACCOUNT' THEN (SELECT a.name FROM account a WHERE a.id = tk.entity_id)
           WHEN 'PARTNER' THEN (SELECT COALESCE(p.short_name, p.legal_name) FROM partner p WHERE p.id = tk.entity_id)
           WHEN 'OFFER' THEN (SELECT CONCAT(f.offer_no, ' · ', o.title) FROM offer f JOIN opportunity o ON o.id = f.opportunity_id WHERE f.id = tk.entity_id)
           WHEN 'TENDER' THEN (SELECT CONCAT(t.tender_no, ' · ', t.title) FROM tender t WHERE t.id = tk.entity_id)
           WHEN 'ORDER' THEN (SELECT CONCAT(so.order_no, ' · ', a.name) FROM sales_order so
                                JOIN account a ON a.id = so.account_id WHERE so.id = tk.entity_id)
           WHEN 'INVOICE' THEN (SELECT CONCAT(i.invoice_no, ' · ', so.order_no, ' · ', a.name) FROM invoice i
                                  JOIN sales_order so ON so.id = i.order_id
                                  JOIN account a ON a.id = so.account_id WHERE i.id = tk.entity_id)
           ELSE NULL END AS entityLabel
    FROM task tk
   WHERE tk.owner_user_id = p_user_id AND tk.status = 'OPEN'
     AND DATE(tk.due_at + INTERVAL 330 MINUTE) <= v_today + INTERVAL 7 DAY
   ORDER BY tk.due_at, tk.id;

  -- own open deals that need something: slipped close date, health, or no status this week
  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName, s.name AS stageName,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         o.expected_close_date AS expectedCloseDate, o.health,
         (o.expected_close_date < v_today) AS closeDatePassed,
         NOT EXISTS (SELECT 1 FROM weekly_status ws WHERE ws.opportunity_id = o.id AND ws.week_start = v_week_start) AS statusPending
    FROM opportunity o
    JOIN account a ON a.id = o.account_id
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
   WHERE o.is_active = 1 AND o.owner_user_id = p_user_id
     AND (o.health <> 'ON_TRACK' OR o.expected_close_date < v_today
          OR NOT EXISTS (SELECT 1 FROM weekly_status ws WHERE ws.opportunity_id = o.id AND ws.week_start = v_week_start))
   ORDER BY o.expected_close_date < v_today DESC, o.health = 'ON_TRACK', o.expected_value DESC
   LIMIT 20;

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName, u.full_name AS ownerName,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value, o.created_at AS createdAt
    FROM opportunity o
    JOIN tmp_rows r ON r.id = o.id AND r.kind = 'V'
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
   ORDER BY o.created_at;

  SELECT f.id, f.offer_no AS offerNo, o.id AS opportunityId, o.title, a.name AS accountName,
         CAST(f.offer_value AS DECIMAL(18,2)) AS offerValue, f.discount_pct AS discountPct,
         u.full_name AS submittedByName, f.submitted_at AS submittedAt
    FROM offer f
    JOIN tmp_offer x ON x.id = f.id
    JOIN opportunity o ON o.id = f.opportunity_id
    JOIN account a ON a.id = o.account_id
    LEFT JOIN `user` u ON u.id = f.submitted_by
   ORDER BY f.submitted_at;

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  DROP TEMPORARY TABLE IF EXISTS tmp_offer;
END $$

-- =============================================================================
-- FORECAST & STATUS (M11)
-- =============================================================================

-- spi_forecast_deals: tmp_rows = open (or all, p_open_only = 0) deals of the user
-- (p_team = 0: owner or backup) or of the whole visible tree (p_team = 1)
DROP PROCEDURE IF EXISTS spi_forecast_deals $$
CREATE PROCEDURE spi_forecast_deals(IN p_user_id BIGINT UNSIGNED, IN p_team TINYINT)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all TINYINT;

  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);
  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  CREATE TEMPORARY TABLE tmp_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_rows (id)
  SELECT o.id FROM opportunity o JOIN tmp_dash_opp t ON t.id = o.id
   WHERE p_team = 1 OR o.owner_user_id = p_user_id OR o.backup_owner_user_id = p_user_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

-- sp_forecast_weekly: week, open deals with this week's and last week's status, summary
DROP PROCEDURE IF EXISTS sp_forecast_weekly $$
CREATE PROCEDURE sp_forecast_weekly(IN p_user_id BIGINT UNSIGNED, IN p_week_start DATE, IN p_team TINYINT)
  SQL SECURITY DEFINER
  COMMENT 'Weekly status grid (12.10, BR-FC-01)'
BEGIN
  DECLARE v_today DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_week  DATE;

  SET v_week = IFNULL(p_week_start, v_today);
  SET v_week = v_week - INTERVAL WEEKDAY(v_week) DAY;
  CALL spi_forecast_deals(p_user_id, p_team);

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  CREATE TEMPORARY TABLE tmp_list (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_list (id)
  SELECT o.id FROM opportunity o JOIN tmp_rows r ON r.id = o.id
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code AND s.is_open = 1
   WHERE DATE(o.created_at + INTERVAL 330 MINUTE) < v_week + INTERVAL 7 DAY;

  SELECT v_week AS weekStart, v_week + INTERVAL 6 DAY AS weekEnd, v_today AS today,
         (v_week = v_today - INTERVAL WEEKDAY(v_today) DAY) AS isCurrentWeek;

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName, u.full_name AS ownerName,
         s.name AS stageName, CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         o.expected_close_date AS expectedCloseDate, o.health,
         ws.status, ws.this_week AS thisWeek, ws.next_step AS nextStep,
         ws.expected_close_date AS statusCloseDate, ws.close_change_reason AS closeChangeReason,
         ws.submitted_at AS submittedAt, sb.full_name AS submittedByName,
         (SELECT p.status FROM weekly_status p WHERE p.opportunity_id = o.id AND p.week_start = v_week - INTERVAL 7 DAY) AS previousStatus
    FROM opportunity o
    JOIN tmp_list t ON t.id = o.id
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
    LEFT JOIN weekly_status ws ON ws.opportunity_id = o.id AND ws.week_start = v_week
    LEFT JOIN `user` sb ON sb.id = ws.submitted_by
   ORDER BY ws.id IS NOT NULL, u.full_name, o.expected_close_date;

  SELECT CAST(COUNT(*) AS SIGNED) AS deals,
         CAST(IFNULL(SUM(ws.id IS NOT NULL), 0) AS SIGNED) AS updated,
         CAST(IFNULL(SUM(ws.id IS NULL), 0) AS SIGNED) AS pending,
         CAST(IFNULL(SUM(ws.status = 'ON_TRACK'), 0) AS SIGNED) AS onTrack,
         CAST(IFNULL(SUM(ws.status = 'AT_RISK'), 0) AS SIGNED) AS atRisk,
         CAST(IFNULL(SUM(ws.status IN ('SLIPPED', 'STALLED')), 0) AS SIGNED) AS slipped
    FROM tmp_list t
    LEFT JOIN weekly_status ws ON ws.opportunity_id = t.id AND ws.week_start = v_week;

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
END $$

-- sp_forecast_monthly: month, deals (committed, closing this month or won this month), totals
DROP PROCEDURE IF EXISTS sp_forecast_monthly $$
CREATE PROCEDURE sp_forecast_monthly(IN p_user_id BIGINT UNSIGNED, IN p_month DATE, IN p_team TINYINT)
  SQL SECURITY DEFINER
  COMMENT 'Monthly closure: committed / best case / next month vs achieved (12.10, BR-FC-03)'
BEGIN
  DECLARE v_today DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_month DATE;
  DECLARE v_end   DATE;

  SET v_month = IFNULL(p_month, v_today);
  SET v_month = v_month - INTERVAL (DAY(v_month) - 1) DAY;
  SET v_end = LAST_DAY(v_month);
  CALL spi_forecast_deals(p_user_id, p_team);

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  CREATE TEMPORARY TABLE tmp_list (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_list (id)
  SELECT o.id FROM opportunity o JOIN tmp_rows r ON r.id = o.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE EXISTS (SELECT 1 FROM monthly_commit mc WHERE mc.opportunity_id = o.id AND mc.commit_month = v_month)
      OR (s.is_open = 1 AND o.expected_close_date BETWEEN v_month AND v_end)
      OR (o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_month AND v_end);

  SELECT v_month AS month, v_end AS monthEnd, v_today AS today;

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName, u.full_name AS ownerName,
         o.stage_code AS stageCode, s.name AS stageName,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         o.expected_close_date AS expectedCloseDate,
         mc.commit_type AS commitType, CAST(mc.commit_value AS DECIMAL(18,2)) AS commitValue,
         (o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_month AND v_end) AS achieved,
         CAST(IF(o.stage_code = 'WON', COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate, NULL) AS DECIMAL(18,2)) AS wonValue,
         (o.expected_close_date = v_end) AS monthEndFlag
    FROM opportunity o
    JOIN tmp_list t ON t.id = o.id
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
    LEFT JOIN monthly_commit mc ON mc.opportunity_id = o.id AND mc.commit_month = v_month
   ORDER BY FIELD(IFNULL(mc.commit_type, 'ZZZ'), 'COMMIT', 'UPSIDE', 'NEXT_MONTH', 'ZZZ'), o.expected_value DESC;

  SELECT CAST(IFNULL(SUM(IF(mc.commit_type = 'COMMIT', mc.commit_value, 0)), 0) AS DECIMAL(18,2)) AS committed,
         CAST(IFNULL(SUM(IF(mc.commit_type = 'UPSIDE', mc.commit_value, 0)), 0) AS DECIMAL(18,2)) AS bestCase,
         CAST(IFNULL(SUM(IF(mc.commit_type = 'NEXT_MONTH', mc.commit_value, 0)), 0) AS DECIMAL(18,2)) AS nextMonth,
         CAST(IFNULL(SUM(IF(o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_month AND v_end,
                            COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS achieved,
         CAST(IFNULL(SUM(mc.commit_type = 'COMMIT'), 0) AS SIGNED) AS committedDeals,
         CAST(IFNULL(SUM(mc.commit_type = 'COMMIT' AND o.stage_code = 'WON'), 0) AS SIGNED) AS committedWon,
         CAST(IFNULL(SUM(o.expected_close_date = v_end), 0) AS SIGNED) AS monthEndDeals
    FROM tmp_list t
    JOIN opportunity o ON o.id = t.id
    LEFT JOIN monthly_commit mc ON mc.opportunity_id = o.id AND mc.commit_month = v_month;

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
END $$

-- sp_forecast_hierarchy: one row per person in the visible tree, with team roll-ups
-- (the person and everyone below them): open funnel, weighted, this month's commitment,
-- won this month, quarter target and won this quarter (12.10 "hierarchy funnel")
DROP PROCEDURE IF EXISTS sp_forecast_hierarchy $$
CREATE PROCEDURE sp_forecast_hierarchy(IN p_user_id BIGINT UNSIGNED, IN p_month DATE)
  SQL SECURITY DEFINER
  COMMENT 'Hierarchy funnel: owner -> team (12.10)'
BEGIN
  DECLARE v_all     TINYINT;
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_month   DATE;
  DECLARE v_end     DATE;
  DECLARE v_fy      SMALLINT;
  DECLARE v_q       TINYINT;
  DECLARE v_q_from  DATE;
  DECLARE v_q_to    DATE;
  DECLARE v_dummy   DATE;
  DECLARE v_start_month INT;

  SET v_month = IFNULL(p_month, v_today);
  SET v_month = v_month - INTERVAL (DAY(v_month) - 1) DAY;
  SET v_end = LAST_DAY(v_month);
  CALL spi_setting_int('fiscal_year.start_month', 4, v_start_month);
  SET v_fy = IF(MONTH(v_month) >= v_start_month, YEAR(v_month), YEAR(v_month) - 1);
  SET v_q = FLOOR(MOD(MONTH(v_month) - v_start_month + 12, 12) / 3) + 1;
  CALL spi_dashboard_period(v_fy, v_q, v_fy, v_q, v_q_from, v_q_to, v_dummy);

  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);

  -- the people: owners of visible deals and everyone above them, inside the user's tree
  DROP TEMPORARY TABLE IF EXISTS tmp_h_users;
  CREATE TEMPORARY TABLE tmp_h_users (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT IGNORE INTO tmp_h_users (id)
  SELECT DISTINCT h.ancestor_user_id
    FROM opportunity o
    JOIN tmp_dash_opp t ON t.id = o.id
    JOIN user_hierarchy h ON h.descendant_user_id = o.owner_user_id
   WHERE v_all = 1 OR EXISTS (SELECT 1 FROM user_hierarchy me
                               WHERE me.ancestor_user_id = p_user_id AND me.descendant_user_id = h.ancestor_user_id);

  -- deal figures per person, rolled up over the team (closure table)
  DROP TEMPORARY TABLE IF EXISTS tmp_h_deal;
  CREATE TEMPORARY TABLE tmp_h_deal (
    user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY, open_count INT, open_value DECIMAL(18,2),
    weighted DECIMAL(18,2), won_month DECIMAL(18,2), won_quarter DECIMAL(18,2)
  );
  INSERT INTO tmp_h_deal
  SELECT hu.id,
         SUM(s.is_open = 1),
         SUM(IF(s.is_open = 1, o.expected_value * o.fx_rate, 0)),
         SUM(IF(s.is_open = 1, o.weighted_value, 0)),
         SUM(IF(o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_month AND v_end,
                COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate, 0)),
         SUM(IF(o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_q_from AND v_q_to,
                COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate, 0))
    FROM tmp_h_users hu
    JOIN user_hierarchy h ON h.ancestor_user_id = hu.id
    JOIN opportunity o ON o.owner_user_id = h.descendant_user_id
    JOIN tmp_dash_opp t ON t.id = o.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   GROUP BY hu.id;

  DROP TEMPORARY TABLE IF EXISTS tmp_h_commit;
  CREATE TEMPORARY TABLE tmp_h_commit (user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY, committed DECIMAL(18,2));
  INSERT INTO tmp_h_commit
  SELECT hu.id, SUM(IF(mc.commit_type = 'COMMIT', mc.commit_value, 0))
    FROM tmp_h_users hu
    JOIN user_hierarchy h ON h.ancestor_user_id = hu.id
    JOIN opportunity o ON o.owner_user_id = h.descendant_user_id
    JOIN monthly_commit mc ON mc.opportunity_id = o.id AND mc.commit_month = v_month
   WHERE o.id IN (SELECT id FROM tmp_dash_opp)
   GROUP BY hu.id;

  SELECT v_month AS month, v_fy AS fiscalYear, v_q AS quarter, v_q_from AS quarterFrom, v_q_to AS quarterTo;

  SELECT u.id AS userId, u.full_name AS name, u.designation, u.reporting_to_user_id AS reportingToUserId,
         CAST(IFNULL(d.open_count, 0) AS SIGNED) AS openDeals,
         CAST(IFNULL(d.open_value, 0) AS DECIMAL(18,2)) AS openValue,
         CAST(IFNULL(d.weighted, 0) AS DECIMAL(18,2)) AS weighted,
         CAST(IFNULL(c.committed, 0) AS DECIMAL(18,2)) AS committed,
         CAST(IFNULL(d.won_month, 0) AS DECIMAL(18,2)) AS achieved,
         CAST((SELECT IFNULL(SUM(tg.target_value), 0) FROM target tg
                JOIN user_hierarchy h ON h.ancestor_user_id = u.id AND h.descendant_user_id = tg.owner_user_id
               WHERE tg.fiscal_year = v_fy AND tg.quarter = v_q) AS DECIMAL(18,2)) AS quarterTarget,
         CAST(IFNULL(d.won_quarter, 0) AS DECIMAL(18,2)) AS quarterWon
    FROM tmp_h_users hu
    JOIN `user` u ON u.id = hu.id
    LEFT JOIN tmp_h_deal d ON d.user_id = hu.id
    LEFT JOIN tmp_h_commit c ON c.user_id = hu.id
   ORDER BY u.full_name;

  DROP TEMPORARY TABLE IF EXISTS tmp_h_commit;
  DROP TEMPORARY TABLE IF EXISTS tmp_h_deal;
  DROP TEMPORARY TABLE IF EXISTS tmp_h_users;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

DELIMITER ;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V008', 'Sales screens, read side: my day, leads, opportunities, accounts, forecast', 'V008__sp_sales_views.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
