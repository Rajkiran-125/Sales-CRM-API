-- =============================================================================
-- V009  Sales CRM - partners, partner performance and tenders, read side
--       (M08, M09, M12)                                              (2026-10-12)
--
--   Partners (list "my partners", the partner workspace with the five sections of UM 7.1),
--   Partner performance (one scorecard per partner and period, UM 7.2) and Tenders (list
--   by status with the submission countdown, tender page with the readiness checklist).
--   Read-only: create / edit come later (decision D-27).
--
--   Scope (10.8): partners whose relationship owner or backup is in the user's tree (all
--   for ALL); tenders owned by the tree, bid with a partner of the tree, or linked to a
--   visible deal. Deals listed on a partner page are only the user's visible deals.
--
--   Scorecard measures are computed live from deals, orders, invoices / payments, tenders
--   and engagements for the period (fiscal quarter or year). The score is PROVISIONAL
--   (decision D-28) until OD-42 fixes the weights: four signals of 25 points each -
--   win % (no closed deal = 50 %), revenue relative to the best partner, on-time payment
--   (no payment yet = 75 %), and the "third layer" (repeat business + new logos +
--   strategic accounts + competition replacement, 4 or more = full). Rating 1-5 stars
--   at 35 / 50 / 65 / 80; tier recommendation Strategic >= 65, Growth >= 45.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V008.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- spi_visible_partners: tmp_vis_ptr = the active partners the user may see
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_visible_partners $$
CREATE PROCEDURE spi_visible_partners(IN p_user_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all      TINYINT;
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;

  CALL spi_scope_flags(p_user_id, v_all, v_own, v_assigned, v_partner, v_module);

  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  CREATE TEMPORARY TABLE tmp_vis_ptr (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_vis_ptr (id)
  SELECT p.id
    FROM partner p
   WHERE p.is_active = 1 AND p.deleted_at IS NULL
     AND (v_all = 1
          OR (v_own = 1 AND EXISTS (
                SELECT 1 FROM user_hierarchy h
                 WHERE h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (p.relationship_owner_user_id, IFNULL(p.backup_owner_user_id, 0)))));
END $$

-- -----------------------------------------------------------------------------
-- spi_partner_scorecards: tmp_card = the UM 7.2 measures of every active partner for
-- the period [p_from, p_to], with the provisional score, rating and tier (D-28)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_partner_scorecards $$
CREATE PROCEDURE spi_partner_scorecards(IN p_from DATE, IN p_to DATE)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_max_rev DECIMAL(18,2) DEFAULT 0;

  -- one row per partner and deal (a partner can hold several roles on a deal)
  DROP TEMPORARY TABLE IF EXISTS tmp_pd;
  CREATE TEMPORARY TABLE tmp_pd (
    partner_id   BIGINT UNSIGNED NOT NULL,
    opp_id       BIGINT UNSIGNED NOT NULL,
    src          TINYINT, inf TINYINT, open_now TINYINT, won_in TINYINT, lost_in TINYINT, rel TINYINT,
    value        DECIMAL(18,2), closed_value DECIMAL(18,2),
    account_id   BIGINT UNSIGNED, strategic TINYINT, replaced TINYINT, lead_days INT NULL,
    created_on   DATE,
    PRIMARY KEY (partner_id, opp_id)
  );
  INSERT INTO tmp_pd
  SELECT op.partner_id, o.id,
         MAX(op.partner_role = 'SOURCED'), MAX(op.partner_role = 'INFLUENCED'),
         MAX(IFNULL(s.is_open, 0)),
         MAX(o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN p_from AND p_to),
         MAX(o.stage_code = 'LOST' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN p_from AND p_to),
         0,
         MAX(o.expected_value * o.fx_rate),
         MAX(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate),
         MAX(o.account_id), MAX(a.is_strategic), MAX(IFNULL(wl.competition_replaced, 0)),
         MAX(IF(l.id IS NULL, NULL, DATEDIFF(DATE(o.created_at + INTERVAL 330 MINUTE), DATE(l.created_at + INTERVAL 330 MINUTE)))),
         MAX(DATE(o.created_at + INTERVAL 330 MINUTE))
    FROM opportunity_partner op
    JOIN opportunity o ON o.id = op.opportunity_id AND o.is_active = 1
    JOIN account a ON a.id = o.account_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
    LEFT JOIN win_loss wl ON wl.opportunity_id = o.id
    LEFT JOIN sales_lead l ON l.id = o.lead_id
   GROUP BY op.partner_id, o.id;
  -- "in the period": open now, or closed in the period
  UPDATE tmp_pd SET rel = (open_now = 1 OR won_in = 1 OR lost_in = 1);

  DROP TEMPORARY TABLE IF EXISTS tmp_card;
  CREATE TEMPORARY TABLE tmp_card (
    partner_id              BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    sourced_count           INT NOT NULL DEFAULT 0, sourced_value DECIMAL(18,2) NOT NULL DEFAULT 0,
    influenced_count        INT NOT NULL DEFAULT 0, influenced_value DECIMAL(18,2) NOT NULL DEFAULT 0,
    active_deals            INT NOT NULL DEFAULT 0, pipeline DECIMAL(18,2) NOT NULL DEFAULT 0,
    closed_deals            INT NOT NULL DEFAULT 0, won_deals INT NOT NULL DEFAULT 0, lost_deals INT NOT NULL DEFAULT 0,
    win_pct                 DECIMAL(5,2) NULL, revenue DECIMAL(18,2) NOT NULL DEFAULT 0,
    avg_deal_size           DECIMAL(18,2) NULL, lead_to_deal_days DECIMAL(8,1) NULL,
    strategic_accounts      INT NOT NULL DEFAULT 0, competition_replacement INT NOT NULL DEFAULT 0,
    product_mix             INT NOT NULL DEFAULT 0, repeat_business INT NOT NULL DEFAULT 0, new_logos INT NOT NULL DEFAULT 0,
    gtm_activities          INT NOT NULL DEFAULT 0, cec_engagements INT NOT NULL DEFAULT 0,
    tender_pipeline_count   INT NOT NULL DEFAULT 0, tender_pipeline_value DECIMAL(18,2) NOT NULL DEFAULT 0,
    tender_readiness_pct    DECIMAL(5,2) NULL, order_to_book_days DECIMAL(8,1) NULL,
    gm_pct                  DECIMAL(5,2) NULL, np_pct DECIMAL(5,2) NULL,
    on_time_payment_pct     DECIMAL(5,2) NULL, avg_payment_delay_days DECIMAL(8,1) NULL,
    update_discipline_pct   DECIMAL(5,2) NULL,
    score                   DECIMAL(5,1) NULL, rating TINYINT NULL, tier_recommendation VARCHAR(15) NULL
  );
  INSERT INTO tmp_card (partner_id, sourced_count, sourced_value, influenced_count, influenced_value, active_deals,
                        pipeline, closed_deals, won_deals, lost_deals, win_pct, revenue, avg_deal_size,
                        lead_to_deal_days, strategic_accounts, competition_replacement)
  SELECT p.id,
         IFNULL(SUM(d.src = 1 AND d.rel = 1), 0), IFNULL(SUM(IF(d.src = 1 AND d.rel = 1, d.value, 0)), 0),
         IFNULL(SUM(d.inf = 1 AND d.rel = 1), 0), IFNULL(SUM(IF(d.inf = 1 AND d.rel = 1, d.value, 0)), 0),
         IFNULL(SUM(d.open_now), 0), IFNULL(SUM(IF(d.open_now = 1, d.value, 0)), 0),
         IFNULL(SUM(d.won_in + d.lost_in), 0), IFNULL(SUM(d.won_in), 0), IFNULL(SUM(d.lost_in), 0),
         IF(IFNULL(SUM(d.won_in + d.lost_in), 0) = 0, NULL, ROUND(100 * SUM(d.won_in) / SUM(d.won_in + d.lost_in), 2)),
         IFNULL(SUM(IF(d.won_in = 1, d.closed_value, 0)), 0),
         IF(IFNULL(SUM(d.won_in), 0) = 0, NULL, ROUND(SUM(IF(d.won_in = 1, d.closed_value, 0)) / SUM(d.won_in), 2)),
         ROUND(AVG(IF(d.rel = 1, d.lead_days, NULL)), 1),
         COUNT(DISTINCT IF(d.rel = 1 AND d.strategic = 1, d.account_id, NULL)),
         IFNULL(SUM(d.won_in = 1 AND d.replaced = 1), 0)
    FROM partner p
    LEFT JOIN tmp_pd d ON d.partner_id = p.id
   WHERE p.is_active = 1 AND p.deleted_at IS NULL
   GROUP BY p.id;

  -- product mix: products across the partner's deals in the period
  UPDATE tmp_card c
    JOIN (SELECT d.partner_id, COUNT(DISTINCT opr.product_id) AS n
            FROM tmp_pd d JOIN opportunity_product opr ON opr.opportunity_id = d.opp_id
           WHERE d.rel = 1 GROUP BY d.partner_id) x ON x.partner_id = c.partner_id
     SET c.product_mix = x.n;

  -- repeat business: customers with a second won deal through the partner (lifetime)
  UPDATE tmp_card c
    JOIN (SELECT y.partner_id, COUNT(*) AS n
            FROM (SELECT op.partner_id, o.account_id
                    FROM opportunity_partner op JOIN opportunity o ON o.id = op.opportunity_id
                   WHERE o.stage_code = 'WON'
                   GROUP BY op.partner_id, o.account_id
                  HAVING COUNT(DISTINCT o.id) >= 2) y
           GROUP BY y.partner_id) x ON x.partner_id = c.partner_id
     SET c.repeat_business = x.n;

  -- new logos: first-ever wins at a customer, through the partner, in the period
  UPDATE tmp_card c
    JOIN (SELECT op.partner_id, COUNT(DISTINCT a.id) AS n
            FROM opportunity_partner op
            JOIN opportunity o ON o.id = op.opportunity_id AND o.stage_code = 'WON'
            JOIN account a ON a.id = o.account_id
           WHERE a.first_won_on BETWEEN p_from AND p_to
             AND DATE(o.closed_at + INTERVAL 330 MINUTE) = a.first_won_on
           GROUP BY op.partner_id) x ON x.partner_id = c.partner_id
     SET c.new_logos = x.n;

  -- GTM activities and CEC engagements logged in the period
  UPDATE tmp_card c
    JOIN (SELECT pe.partner_id,
                 SUM(pe.engagement_type IN ('GTM_ACTIVITY', 'EVENT', 'TRAINING', 'JOINT_VISIT')) AS gtm,
                 SUM(pe.engagement_type = 'CEC_VISIT') AS cec
            FROM partner_engagement pe
           WHERE pe.engagement_on BETWEEN p_from AND p_to
           GROUP BY pe.partner_id) x ON x.partner_id = c.partner_id
     SET c.gtm_activities = x.gtm, c.cec_engagements = x.cec;

  -- tender pipeline and readiness (tenders bid with the partner)
  UPDATE tmp_card c
    JOIN (SELECT t.bidder_partner_id AS partner_id,
                 SUM(t.status NOT IN ('AWARDED', 'NOT_AWARDED', 'CANCELLED')) AS n,
                 SUM(IF(t.status NOT IN ('AWARDED', 'NOT_AWARDED', 'CANCELLED'), IFNULL(t.estimated_value, 0), 0)) AS val,
                 AVG(t.readiness_pct) AS readiness
            FROM tender t
           WHERE t.is_active = 1 AND t.bidder_partner_id IS NOT NULL
           GROUP BY t.bidder_partner_id) x ON x.partner_id = c.partner_id
     SET c.tender_pipeline_count = x.n, c.tender_pipeline_value = x.val, c.tender_readiness_pct = ROUND(x.readiness, 2);

  -- orders of the partner's deals booked in the period: order-to-book, GM, NP
  UPDATE tmp_card c
    JOIN (SELECT op.partner_id, AVG(so.order_to_book_days) AS otb, AVG(so.gross_margin_pct) AS gm,
                 AVG(so.net_profit_pct) AS np
            FROM sales_order so
            JOIN (SELECT DISTINCT partner_id, opportunity_id FROM opportunity_partner) op ON op.opportunity_id = so.opportunity_id
           WHERE so.po_date BETWEEN p_from AND p_to
           GROUP BY op.partner_id) x ON x.partner_id = c.partner_id
     SET c.order_to_book_days = ROUND(x.otb, 1), c.gm_pct = ROUND(x.gm, 2), c.np_pct = ROUND(x.np, 2);

  -- customer payments received in the period: on time and average delay
  UPDATE tmp_card c
    JOIN (SELECT op.partner_id,
                 100 * SUM(IFNULL(pm.delay_days, 0) <= 0) / COUNT(*) AS on_time,
                 AVG(GREATEST(IFNULL(pm.delay_days, 0), 0)) AS delay
            FROM payment pm
            JOIN sales_order so ON so.id = pm.order_id
            JOIN (SELECT DISTINCT partner_id, opportunity_id FROM opportunity_partner) op ON op.opportunity_id = so.opportunity_id
           WHERE pm.direction = 'RECEIVED' AND pm.paid_on BETWEEN p_from AND p_to
           GROUP BY op.partner_id) x ON x.partner_id = c.partner_id
     SET c.on_time_payment_pct = ROUND(x.on_time, 2), c.avg_payment_delay_days = ROUND(x.delay, 1);

  -- weekly update discipline: statuses in the last 8 weeks / weeks the open deals existed
  UPDATE tmp_card c
    JOIN (SELECT d.partner_id,
                 SUM((SELECT COUNT(*) FROM weekly_status ws
                       WHERE ws.opportunity_id = d.opp_id AND ws.week_start >= v_today - INTERVAL 56 DAY)) AS done,
                 SUM(LEAST(8, GREATEST(1, FLOOR(DATEDIFF(v_today, d.created_on) / 7)))) AS expected
            FROM tmp_pd d
           WHERE d.open_now = 1
           GROUP BY d.partner_id) x ON x.partner_id = c.partner_id
     SET c.update_discipline_pct = LEAST(100, ROUND(100 * x.done / x.expected, 2));

  -- the provisional score (D-28)
  SELECT IFNULL(MAX(revenue), 0) INTO v_max_rev FROM tmp_card;
  UPDATE tmp_card
     SET score = ROUND(IFNULL(win_pct, 50) * 0.25
                       + 25 * IF(v_max_rev > 0, LEAST(1, revenue / v_max_rev), 0)
                       + IFNULL(on_time_payment_pct, 75) * 0.25
                       + 25 * LEAST(1, (repeat_business + new_logos + strategic_accounts + competition_replacement) / 4), 1)
   WHERE active_deals + closed_deals > 0;
  UPDATE tmp_card
     SET rating = CASE WHEN score >= 80 THEN 5 WHEN score >= 65 THEN 4 WHEN score >= 50 THEN 3 WHEN score >= 35 THEN 2 ELSE 1 END,
         tier_recommendation = CASE WHEN score >= 65 THEN 'STRATEGIC' WHEN score >= 45 THEN 'GROWTH' ELSE 'TRANSACTIONAL' END
   WHERE score IS NOT NULL;
END $$

-- -----------------------------------------------------------------------------
-- sp_partner_list: "my partners" with the current fiscal year's figures; { total }
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_list $$
CREATE PROCEDURE sp_partner_list(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_search        VARCHAR(100),
  IN p_type          VARCHAR(30),
  IN p_tier          VARCHAR(15),
  IN p_agreement     VARCHAR(15),
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_sort          VARCHAR(30),
  IN p_offset        INT,
  IN p_limit         INT
)
  SQL SECURITY DEFINER
  COMMENT 'Partner list with this fiscal year scorecard (12.7)'
BEGIN
  DECLARE v_search VARCHAR(100);
  DECLARE v_like   VARCHAR(310);
  DECLARE v_fy     SMALLINT;
  DECLARE v_q      TINYINT;
  DECLARE v_from   DATE;
  DECLARE v_to     DATE;
  DECLARE v_today  DATE;

  CALL spi_like(p_search, v_search, v_like);
  CALL spi_dashboard_period(NULL, NULL, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_dashboard_period(v_fy, NULL, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_visible_partners(p_user_id);
  CALL spi_partner_scorecards(v_from, v_to);

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  CREATE TEMPORARY TABLE tmp_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_rows (id)
  SELECT p.id
    FROM partner p
    JOIN tmp_vis_ptr v ON v.id = p.id
   WHERE (v_search IS NULL OR p.legal_name LIKE v_like OR p.short_name LIKE v_like OR p.partner_no LIKE v_like
          OR p.city LIKE v_like OR p.gst_no LIKE v_like)
     AND (p_type IS NULL OR EXISTS (SELECT 1 FROM partner_type_map m JOIN partner_type t ON t.id = m.partner_type_id
                                     WHERE m.partner_id = p.id AND t.code = p_type))
     AND (p_tier IS NULL OR p.tier = p_tier)
     AND (p_agreement IS NULL OR p.agreement_status = p_agreement)
     AND (p_owner_user_id IS NULL OR EXISTS (
            SELECT 1 FROM user_hierarchy h
             WHERE h.ancestor_user_id = p_owner_user_id AND h.descendant_user_id = p.relationship_owner_user_id));

  SELECT p.id, p.partner_no AS partnerNo, COALESCE(p.short_name, p.legal_name) AS name, p.legal_name AS legalName,
         (SELECT GROUP_CONCAT(t.name ORDER BY t.sort_order SEPARATOR ', ')
            FROM partner_type_map m JOIN partner_type t ON t.id = m.partner_type_id WHERE m.partner_id = p.id) AS types,
         p.tier, p.city, u.full_name AS ownerName, p.agreement_status AS agreementStatus,
         p.agreement_valid_till AS agreementValidTill, p.profile_completeness_pct AS completenessPct,
         CAST(IFNULL(c.active_deals, 0) AS SIGNED) AS activeDeals,
         CAST(IFNULL(c.pipeline, 0) AS DECIMAL(18,2)) AS pipeline,
         CAST(IFNULL(c.revenue, 0) AS DECIMAL(18,2)) AS wonValue,
         CAST(IFNULL(c.won_deals, 0) AS SIGNED) AS wonDeals,
         c.win_pct AS winPct, c.score, c.rating,
         p.last_engagement_on AS lastEngagementOn, p.next_engagement_on AS nextEngagementOn,
         p.next_engagement_plan AS nextEngagementPlan
    FROM partner p
    JOIN tmp_rows r ON r.id = p.id
    JOIN `user` u ON u.id = p.relationship_owner_user_id
    LEFT JOIN tmp_card c ON c.partner_id = p.id
   ORDER BY
     CASE WHEN p_sort = 'name'              THEN COALESCE(p.short_name, p.legal_name) END ASC,
     CASE WHEN p_sort = '-wonValue'         THEN IFNULL(c.revenue, 0) END DESC,
     CASE WHEN p_sort = '-rating'           THEN IFNULL(c.score, -1) END DESC,
     CASE WHEN p_sort = 'nextEngagementOn'  THEN IFNULL(p.next_engagement_on, '9999-12-31') END ASC,
     IFNULL(c.pipeline, 0) DESC, p.id
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total FROM tmp_rows;
  SELECT v_fy AS fiscalYear, v_from AS fromDate, v_to AS toDate;

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  DROP TEMPORARY TABLE IF EXISTS tmp_card;
  DROP TEMPORARY TABLE IF EXISTS tmp_pd;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
END $$

-- -----------------------------------------------------------------------------
-- sp_partner_get: the partner workspace (UM 7.1). Result sets:
--   partner, types, industries, certifications, customerCodes, contacts,
--   scorecard (this fiscal year), deals (visible ones), engagements, accountMap, activities
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_get $$
CREATE PROCEDURE sp_partner_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Partner workspace, read side (12.7)'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;
  DECLARE v_all     TINYINT;
  DECLARE v_fy      SMALLINT;
  DECLARE v_q       TINYINT;
  DECLARE v_from    DATE;
  DECLARE v_to      DATE;
  DECLARE v_today   DATE;

  CALL spi_visible_partners(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_ptr WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Partner not found.', 'id');
  END IF;

  SELECT p.id, p.partner_no AS partnerNo, COALESCE(p.short_name, p.legal_name) AS name, p.legal_name AS legalName,
         p.short_name AS shortName, p.country, p.address, p.city, p.website, p.email, p.phone,
         p.registration_no AS registrationNo, p.gst_no AS gstNo, p.pan_no AS panNo, p.currency,
         CAST(p.annual_revenue AS DECIMAL(18,2)) AS annualRevenue, p.revenue_fy AS revenueFy,
         p.credit_rating AS creditRating, p.financial_status AS financialStatus,
         p.agreement_status AS agreementStatus, p.agreement_valid_till AS agreementValidTill, p.tier,
         p.top_customers AS topCustomers, p.our_share_pct AS ourSharePct, p.sme_count AS smeCount,
         p.can_run_poc AS canRunPoc, p.certified_engineers AS certifiedEngineers,
         p.sales_force_size AS salesForceSize, p.uses_crm AS usesCrm, p.sales_coverage AS salesCoverage,
         p.influencer_connect AS influencerConnect, p.dmu_impact AS dmuImpact, p.dmu_impact_notes AS dmuImpactNotes,
         p.top_management AS topManagement, p.partner_dmu AS partnerDmu,
         u.full_name AS ownerName, b.full_name AS backupOwnerName,
         p.tech_onboarding_status AS techOnboardingStatus, p.gtm_plan_status AS gtmPlanStatus,
         p.poc_investment_count AS pocInvestmentCount, CAST(p.poc_investment_value AS DECIMAL(18,2)) AS pocInvestmentValue,
         p.last_engagement_on AS lastEngagementOn, p.next_engagement_on AS nextEngagementOn,
         p.next_engagement_plan AS nextEngagementPlan, p.customer_feedback_rating AS customerFeedbackRating,
         p.customer_feedback_notes AS customerFeedbackNotes, p.publications,
         p.profile_completeness_pct AS completenessPct, p.created_at AS createdAt
    FROM partner p
    JOIN `user` u ON u.id = p.relationship_owner_user_id
    LEFT JOIN `user` b ON b.id = p.backup_owner_user_id
   WHERE p.id = p_id;

  SELECT t.code, t.name FROM partner_type_map m JOIN partner_type t ON t.id = m.partner_type_id
   WHERE m.partner_id = p_id ORDER BY t.sort_order;
  SELECT i.code, i.name FROM partner_industry_map m JOIN industry i ON i.id = m.industry_id
   WHERE m.partner_id = p_id ORDER BY i.sort_order;
  SELECT COALESCE(ct.name, pc.other_name) AS name FROM partner_certification pc
    LEFT JOIN certification_type ct ON ct.id = pc.certification_type_id WHERE pc.partner_id = p_id ORDER BY name;
  SELECT COALESCE(a.name, cc.customer_name) AS customer, cc.code
    FROM partner_customer_code cc LEFT JOIN account a ON a.id = cc.account_id WHERE cc.partner_id = p_id ORDER BY customer;
  SELECT c.id, c.name, c.designation, c.email, c.phone, c.spoc_type AS spocType
    FROM contact c WHERE c.partner_id = p_id AND c.is_active = 1
   ORDER BY FIELD(IFNULL(c.spoc_type, 'ZZZ'), 'TOP_MGMT', 'DMU', 'COMMERCIAL', 'TECH', 'FINANCE', 'LEGAL', 'ZZZ'), c.name;

  -- scorecard for the current fiscal year
  CALL spi_dashboard_period(NULL, NULL, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_dashboard_period(v_fy, NULL, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_partner_scorecards(v_from, v_to);
  SELECT v_fy AS fiscalYear, v_from AS fromDate, v_to AS toDate,
         c.sourced_count AS sourcedCount, CAST(c.sourced_value AS DECIMAL(18,2)) AS sourcedValue,
         c.influenced_count AS influencedCount, CAST(c.influenced_value AS DECIMAL(18,2)) AS influencedValue,
         c.active_deals AS activeDeals, CAST(c.pipeline AS DECIMAL(18,2)) AS pipeline,
         c.closed_deals AS closedDeals, c.won_deals AS wonDeals, c.lost_deals AS lostDeals, c.win_pct AS winPct,
         CAST(c.revenue AS DECIMAL(18,2)) AS revenue, CAST(c.avg_deal_size AS DECIMAL(18,2)) AS avgDealSize,
         c.lead_to_deal_days AS leadToDealDays, c.order_to_book_days AS orderToBookDays,
         c.gm_pct AS gmPct, c.np_pct AS npPct, c.on_time_payment_pct AS onTimePaymentPct,
         c.avg_payment_delay_days AS avgPaymentDelayDays, c.repeat_business AS repeatBusiness,
         c.new_logos AS newLogos, c.strategic_accounts AS strategicAccounts,
         c.competition_replacement AS competitionReplacement, c.product_mix AS productMix,
         c.tender_pipeline_count AS tenderPipelineCount, CAST(c.tender_pipeline_value AS DECIMAL(18,2)) AS tenderPipelineValue,
         c.tender_readiness_pct AS tenderReadinessPct, c.gtm_activities AS gtmActivities,
         c.cec_engagements AS cecEngagements, c.update_discipline_pct AS updateDisciplinePct,
         c.score, c.rating, c.tier_recommendation AS tierRecommendation
    FROM tmp_card c WHERE c.partner_id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_card;
  DROP TEMPORARY TABLE IF EXISTS tmp_pd;

  -- the partner's deals the user may see
  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);
  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName,
         GROUP_CONCAT(op.partner_role ORDER BY op.partner_role SEPARATOR ', ') AS roles,
         o.stage_code AS stageCode, s.name AS stageName, s.is_open AS isOpen, u.full_name AS ownerName,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate AS DECIMAL(18,2)) AS closedValue,
         o.expected_close_date AS expectedCloseDate, o.closed_at AS closedAt
    FROM opportunity_partner op
    JOIN tmp_dash_opp t ON t.id = op.opportunity_id
    JOIN opportunity o ON o.id = op.opportunity_id
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE op.partner_id = p_id
   GROUP BY o.id, o.opportunity_no, o.title, a.name, o.stage_code, s.name, s.is_open, s.sequence_no, u.full_name,
            o.expected_value, o.fx_rate, o.po_value, o.final_value, o.expected_close_date, o.closed_at
   ORDER BY s.is_open DESC, s.sequence_no DESC, o.expected_close_date;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;

  SELECT pe.id, pe.engagement_type AS engagementType, pe.engagement_on AS engagementOn, pe.with_whom AS withWhom,
         u.full_name AS byName, pe.notes, pe.outcome, pe.next_action AS nextAction, pe.next_action_on AS nextActionOn,
         a.name AS accountName
    FROM partner_engagement pe
    JOIN `user` u ON u.id = pe.by_user_id
    LEFT JOIN account a ON a.id = pe.account_id
   WHERE pe.partner_id = p_id
   ORDER BY pe.engagement_on DESC, pe.id DESC;

  SELECT m.id, a.id AS accountId, a.name AS accountName, m.plan_period AS planPeriod, m.status, m.notes
    FROM partner_account_map m JOIN account a ON a.id = m.account_id
   WHERE m.partner_id = p_id
   ORDER BY m.plan_period DESC, FIELD(m.status, 'OPPORTUNITY', 'ENGAGED', 'PLANNED', 'DROPPED'), a.name;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject, ac.notes,
         ac.outcome, ac.people_met AS peopleMet, u.full_name AS byName
    FROM activity ac JOIN `user` u ON u.id = ac.by_user_id
   WHERE ac.is_active = 1 AND (ac.partner_id = p_id OR (ac.entity_type = 'PARTNER' AND ac.entity_id = p_id))
   ORDER BY ac.activity_at DESC
   LIMIT 50;
END $$

-- -----------------------------------------------------------------------------
-- sp_partner_performance: scorecards of the visible partners for a fiscal quarter or
-- year (UM 7.2). Result sets: period, totals, scorecards
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_performance $$
CREATE PROCEDURE sp_partner_performance(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_fiscal_year   SMALLINT,
  IN p_quarter       TINYINT,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_type          VARCHAR(30)
)
  SQL SECURITY DEFINER
  COMMENT 'Partner scorecards for a period (12.11)'
BEGIN
  DECLARE v_fy    SMALLINT;
  DECLARE v_q     TINYINT;
  DECLARE v_from  DATE;
  DECLARE v_to    DATE;
  DECLARE v_today DATE;

  CALL spi_dashboard_period(p_fiscal_year, p_quarter, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_visible_partners(p_user_id);
  CALL spi_partner_scorecards(v_from, v_to);

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  CREATE TEMPORARY TABLE tmp_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_rows (id)
  SELECT p.id FROM partner p JOIN tmp_vis_ptr v ON v.id = p.id
   WHERE (p_type IS NULL OR EXISTS (SELECT 1 FROM partner_type_map m JOIN partner_type t ON t.id = m.partner_type_id
                                     WHERE m.partner_id = p.id AND t.code = p_type))
     AND (p_owner_user_id IS NULL OR EXISTS (
            SELECT 1 FROM user_hierarchy h
             WHERE h.ancestor_user_id = p_owner_user_id AND h.descendant_user_id = p.relationship_owner_user_id));

  SELECT v_fy AS fiscalYear, v_q AS quarter, v_from AS fromDate, v_to AS toDate;

  SELECT CAST(COUNT(*) AS SIGNED) AS partners,
         CAST(IFNULL(SUM(c.sourced_count), 0) AS SIGNED) AS sourcedDeals,
         CAST(IFNULL(SUM(c.sourced_value), 0) AS DECIMAL(18,2)) AS sourcedValue,
         CAST(IFNULL(SUM(c.influenced_count), 0) AS SIGNED) AS influencedDeals,
         CAST(IFNULL(SUM(c.pipeline), 0) AS DECIMAL(18,2)) AS pipeline,
         CAST(IFNULL(SUM(c.revenue), 0) AS DECIMAL(18,2)) AS revenue,
         CAST(IFNULL(SUM(c.won_deals), 0) AS SIGNED) AS wonDeals,
         CAST(IFNULL(SUM(c.lost_deals), 0) AS SIGNED) AS lostDeals,
         IF(IFNULL(SUM(c.won_deals + c.lost_deals), 0) = 0, NULL,
            ROUND(100 * SUM(c.won_deals) / SUM(c.won_deals + c.lost_deals), 1)) AS winPct
    FROM tmp_card c JOIN tmp_rows r ON r.id = c.partner_id;

  SELECT p.id AS partnerId, p.partner_no AS partnerNo, COALESCE(p.short_name, p.legal_name) AS partnerName,
         (SELECT GROUP_CONCAT(t.name ORDER BY t.sort_order SEPARATOR ', ')
            FROM partner_type_map m JOIN partner_type t ON t.id = m.partner_type_id WHERE m.partner_id = p.id) AS types,
         p.tier, u.full_name AS ownerName,
         c.sourced_count AS sourcedCount, CAST(c.sourced_value AS DECIMAL(18,2)) AS sourcedValue,
         c.influenced_count AS influencedCount, CAST(c.influenced_value AS DECIMAL(18,2)) AS influencedValue,
         c.active_deals AS activeDeals, CAST(c.pipeline AS DECIMAL(18,2)) AS pipeline,
         c.closed_deals AS closedDeals, c.won_deals AS wonDeals, c.lost_deals AS lostDeals, c.win_pct AS winPct,
         CAST(c.revenue AS DECIMAL(18,2)) AS revenue, CAST(c.avg_deal_size AS DECIMAL(18,2)) AS avgDealSize,
         c.lead_to_deal_days AS leadToDealDays, c.order_to_book_days AS orderToBookDays,
         c.gm_pct AS gmPct, c.on_time_payment_pct AS onTimePaymentPct, c.avg_payment_delay_days AS avgPaymentDelayDays,
         c.repeat_business AS repeatBusiness, c.new_logos AS newLogos, c.strategic_accounts AS strategicAccounts,
         c.competition_replacement AS competitionReplacement, c.product_mix AS productMix,
         c.tender_pipeline_count AS tenderPipelineCount, c.tender_readiness_pct AS tenderReadinessPct,
         c.gtm_activities AS gtmActivities, c.cec_engagements AS cecEngagements,
         c.update_discipline_pct AS updateDisciplinePct,
         c.score, c.rating, c.tier_recommendation AS tierRecommendation
    FROM tmp_card c
    JOIN tmp_rows r ON r.id = c.partner_id
    JOIN partner p ON p.id = c.partner_id
    JOIN `user` u ON u.id = p.relationship_owner_user_id
   ORDER BY IFNULL(c.score, -1) DESC, c.revenue DESC, partnerName;

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  DROP TEMPORARY TABLE IF EXISTS tmp_card;
  DROP TEMPORARY TABLE IF EXISTS tmp_pd;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
END $$

-- -----------------------------------------------------------------------------
-- sp_partner_performance_get: one partner's period detail - loss reasons, the deals
-- of the period and the engagements of the period (the expanded scorecard row)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_performance_get $$
CREATE PROCEDURE sp_partner_performance_get(
  IN p_user_id     BIGINT UNSIGNED,
  IN p_partner_id  BIGINT UNSIGNED,
  IN p_fiscal_year SMALLINT,
  IN p_quarter     TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;
  DECLARE v_fy      SMALLINT;
  DECLARE v_q       TINYINT;
  DECLARE v_from    DATE;
  DECLARE v_to      DATE;
  DECLARE v_today   DATE;

  CALL spi_visible_partners(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_ptr WHERE id = p_partner_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Partner not found.', 'id');
  END IF;
  CALL spi_dashboard_period(p_fiscal_year, p_quarter, v_fy, v_q, v_from, v_to, v_today);

  SELECT r.name AS reasonName, CAST(COUNT(*) AS SIGNED) AS count,
         CAST(SUM(o.expected_value * o.fx_rate) AS DECIMAL(18,2)) AS value
    FROM opportunity_partner op
    JOIN opportunity o ON o.id = op.opportunity_id AND o.stage_code = 'LOST'
    JOIN win_loss wl ON wl.opportunity_id = o.id
    JOIN reason r ON r.id = wl.loss_reason_id
   WHERE op.partner_id = p_partner_id
     AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to
   GROUP BY r.name
   ORDER BY count DESC;

  SELECT DISTINCT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName, op.partner_role AS role,
         o.stage_code AS stageCode, s.name AS stageName,
         CAST(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate AS DECIMAL(18,2)) AS value
    FROM opportunity_partner op
    JOIN opportunity o ON o.id = op.opportunity_id AND o.is_active = 1
    JOIN account a ON a.id = o.account_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE op.partner_id = p_partner_id
     AND (s.is_open = 1 OR DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to)
   ORDER BY stageCode, value DESC;

  SELECT pe.engagement_type AS engagementType, pe.engagement_on AS engagementOn, pe.with_whom AS withWhom,
         pe.outcome, u.full_name AS byName
    FROM partner_engagement pe JOIN `user` u ON u.id = pe.by_user_id
   WHERE pe.partner_id = p_partner_id AND pe.engagement_on BETWEEN v_from AND v_to
   ORDER BY pe.engagement_on DESC;
END $$

-- =============================================================================
-- TENDERS (M09)
-- =============================================================================

-- spi_visible_tenders: tmp_vis_tender = tenders owned by the tree, bid with a partner of
-- the tree, linked to a visible deal, or all (ALL)
DROP PROCEDURE IF EXISTS spi_visible_tenders $$
CREATE PROCEDURE spi_visible_tenders(IN p_user_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all      TINYINT;
  DECLARE v_deal_all TINYINT;
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;

  CALL spi_scope_flags(p_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_deal_all);

  DROP TEMPORARY TABLE IF EXISTS tmp_vis_tender;
  CREATE TEMPORARY TABLE tmp_vis_tender (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_vis_tender (id)
  SELECT t.id
    FROM tender t
   WHERE t.is_active = 1
     AND (v_all = 1
          OR (v_own = 1 AND EXISTS (
                SELECT 1 FROM user_hierarchy h
                 WHERE h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (t.owner_user_id, IFNULL(t.backup_owner_user_id, 0))))
          OR (v_partner = 1 AND t.bidder_partner_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM partner p
                  JOIN user_hierarchy h ON h.ancestor_user_id = p_user_id
                   AND h.descendant_user_id IN (p.relationship_owner_user_id, IFNULL(p.backup_owner_user_id, 0))
                 WHERE p.id = t.bidder_partner_id))
          OR (t.opportunity_id IS NOT NULL AND t.opportunity_id IN (SELECT id FROM tmp_dash_opp)));
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

-- sp_tender_list: rows with the submission countdown, { total }, counts per status
DROP PROCEDURE IF EXISTS sp_tender_list $$
CREATE PROCEDURE sp_tender_list(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_search        VARCHAR(100),
  IN p_status        VARCHAR(14),
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_sort          VARCHAR(30),
  IN p_offset        INT,
  IN p_limit         INT
)
  SQL SECURITY DEFINER
  COMMENT 'Tenders inside the user scope (12.8)'
BEGIN
  DECLARE v_search VARCHAR(100);
  DECLARE v_like   VARCHAR(310);
  DECLARE v_today  DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  CALL spi_like(p_search, v_search, v_like);
  CALL spi_visible_tenders(p_user_id);

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  CREATE TEMPORARY TABLE tmp_list (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_list (id)
  SELECT t.id FROM tender t JOIN tmp_vis_tender v ON v.id = t.id
   WHERE (v_search IS NULL OR t.tender_no LIKE v_like OR t.reference_no LIKE v_like OR t.title LIKE v_like
          OR t.authority LIKE v_like)
     AND (p_owner_user_id IS NULL OR EXISTS (
            SELECT 1 FROM user_hierarchy h
             WHERE h.ancestor_user_id = p_owner_user_id AND h.descendant_user_id = t.owner_user_id));

  SELECT t.id, t.tender_no AS tenderNo, t.reference_no AS referenceNo, t.portal, t.authority,
         a.name AS accountName, t.title, pr.name AS productName,
         CAST(t.estimated_value AS DECIMAL(18,2)) AS estimatedValue, t.our_role AS ourRole,
         COALESCE(bp.short_name, bp.legal_name) AS bidderPartnerName,
         t.pre_bid_on AS preBidOn, t.submission_on AS submissionOn, t.opening_on AS openingOn,
         IF(t.status IN ('IDENTIFIED', 'READINESS', 'CAPTURED') AND t.submission_on IS NOT NULL,
            DATEDIFF(t.submission_on, v_today), NULL) AS daysToSubmission,
         t.status, st.name AS statusName, t.readiness_pct AS readinessPct, t.result,
         u.full_name AS ownerName, t.opportunity_id AS opportunityId, o.opportunity_no AS opportunityNo
    FROM tender t
    JOIN tmp_list l ON l.id = t.id
    JOIN `user` u ON u.id = t.owner_user_id
    LEFT JOIN account a ON a.id = t.account_id
    LEFT JOIN product pr ON pr.id = t.product_id
    LEFT JOIN partner bp ON bp.id = t.bidder_partner_id
    LEFT JOIN opportunity o ON o.id = t.opportunity_id
    LEFT JOIN stage st ON st.entity = 'TENDER' AND st.code = t.status
   WHERE p_status IS NULL OR t.status = p_status
   ORDER BY
     CASE WHEN p_sort = 'submissionOn'     THEN IFNULL(t.submission_on, '9999-12-31') END ASC,
     CASE WHEN p_sort = '-estimatedValue'  THEN t.estimated_value END DESC,
     CASE WHEN p_sort = '-createdAt'       THEN t.created_at END DESC,
     st.sequence_no, IFNULL(t.submission_on, '9999-12-31'), t.id
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total FROM tender t JOIN tmp_list l ON l.id = t.id WHERE p_status IS NULL OR t.status = p_status;

  SELECT st.code AS status, st.name AS statusName, CAST(COUNT(x.id) AS SIGNED) AS count,
         CAST(IFNULL(SUM(x.estimated_value), 0) AS DECIMAL(18,2)) AS value
    FROM stage st
    LEFT JOIN (SELECT t.id, t.status, t.estimated_value FROM tender t JOIN tmp_list l ON l.id = t.id) x
      ON x.status = st.code
   WHERE st.entity = 'TENDER'
   GROUP BY st.code, st.name, st.sequence_no
   ORDER BY st.sequence_no;

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_tender;
END $$

-- sp_tender_get: tender, stepper, checklist, linked deal, activities
DROP PROCEDURE IF EXISTS sp_tender_get $$
CREATE PROCEDURE sp_tender_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Tender page, read side (12.8)'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  CALL spi_visible_tenders(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_tender WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_tender;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Tender not found.', 'id');
  END IF;

  SELECT t.id, t.tender_no AS tenderNo, t.reference_no AS referenceNo, t.portal, t.authority,
         t.account_id AS accountId, a.name AS accountName, t.title, pr.name AS productName,
         CAST(t.estimated_value AS DECIMAL(18,2)) AS estimatedValue, t.our_role AS ourRole,
         t.bidder_partner_id AS bidderPartnerId, COALESCE(bp.short_name, bp.legal_name) AS bidderPartnerName,
         t.pre_bid_on AS preBidOn, t.submission_on AS submissionOn, t.opening_on AS openingOn,
         IF(t.status IN ('IDENTIFIED', 'READINESS', 'CAPTURED') AND t.submission_on IS NOT NULL,
            DATEDIFF(t.submission_on, v_today), NULL) AS daysToSubmission,
         t.status, st.name AS statusName, t.spec_influenced AS specInfluenced, t.rfp_influenced AS rfpInfluenced,
         t.prebid_queries_filed AS prebidQueriesFiled, t.intelligence_notes AS intelligenceNotes,
         t.readiness_pct AS readinessPct, t.result, CAST(t.l1_price AS DECIMAL(18,2)) AS l1Price,
         CAST(t.our_price AS DECIMAL(18,2)) AS ourPrice, t.winner, r.name AS lossReason,
         t.opportunity_id AS opportunityId, o.opportunity_no AS opportunityNo, o.title AS opportunityTitle,
         os.name AS opportunityStage, u.full_name AS ownerName, b.full_name AS backupOwnerName,
         t.created_at AS createdAt
    FROM tender t
    JOIN `user` u ON u.id = t.owner_user_id
    LEFT JOIN `user` b ON b.id = t.backup_owner_user_id
    LEFT JOIN account a ON a.id = t.account_id
    LEFT JOIN product pr ON pr.id = t.product_id
    LEFT JOIN partner bp ON bp.id = t.bidder_partner_id
    LEFT JOIN reason r ON r.id = t.loss_reason_id
    LEFT JOIN opportunity o ON o.id = t.opportunity_id
    LEFT JOIN stage os ON os.entity = 'OPP' AND os.code = o.stage_code
    LEFT JOIN stage st ON st.entity = 'TENDER' AND st.code = t.status
   WHERE t.id = p_id;

  SELECT code, name, sequence_no AS sequenceNo, is_open AS isOpen, is_won AS isWon, is_lost AS isLost
    FROM stage WHERE entity = 'TENDER' AND is_active = 1 ORDER BY sequence_no;

  SELECT ci.id, ci.item_text AS itemText, ci.is_mandatory AS isMandatory, ci.is_done AS isDone,
         u.full_name AS doneByName, ci.done_at AS doneAt
    FROM tender_checklist_item ci LEFT JOIN `user` u ON u.id = ci.done_by
   WHERE ci.tender_id = p_id ORDER BY ci.sort_order, ci.id;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject, ac.notes,
         ac.outcome, ac.people_met AS peopleMet, u.full_name AS byName
    FROM activity ac JOIN `user` u ON u.id = ac.by_user_id
   WHERE ac.is_active = 1 AND ac.entity_type = 'TENDER' AND ac.entity_id = p_id
   ORDER BY ac.activity_at DESC;
END $$

DELIMITER ;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V009', 'Partners, partner performance and tenders, read side', 'V009__sp_partner_views.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
