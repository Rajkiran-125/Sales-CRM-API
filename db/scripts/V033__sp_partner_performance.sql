-- =============================================================================
-- V033  Sales CRM - partner performance: weighted score, snapshots, recompute (2026-10-14)
--
--   settings perf.weight.*         OD-42 default weights, editable in Settings (PERFORMANCE).
--   spi_partner_scorecards         Re-issue of V009: unchanged measures; the provisional
--                                  four-signal score (D-28) becomes the weighted score of the
--                                  eight OD-42 measures, 0-100, five rating bands (BR-PP-02).
--   spi_partner_snapshot_write     Upsert one quarter into partner_performance_snapshot; frozen
--                                  rows are never overwritten.
--   sp_partner_performance_recompute  Nightly job / POST /partner-performance/recompute: the
--                                  current quarter (open snapshot), the previous quarter
--                                  (frozen once: the quarter-end snapshot) and the fiscal-year
--                                  values on partner.perf_* (12.11).
--
-- Re-runnable (DROP + CREATE; settings INSERT IGNORE). Prerequisite: V001-V032.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

INSERT IGNORE INTO setting (setting_key, setting_value, value_type, min_value, max_value, allowed_values, module, description) VALUES
  ('perf.weight.win_pct',                 '25', 'DECIMAL', 0, 100, NULL, 'PERFORMANCE', 'Partner score weight: win % (OD-42)'),
  ('perf.weight.revenue',                 '20', 'DECIMAL', 0, 100, NULL, 'PERFORMANCE', 'Partner score weight: revenue, relative to the best partner (OD-42)'),
  ('perf.weight.timely_payment',          '15', 'DECIMAL', 0, 100, NULL, 'PERFORMANCE', 'Partner score weight: on-time payment % (OD-42)'),
  ('perf.weight.repeat_business',         '10', 'DECIMAL', 0, 100, NULL, 'PERFORMANCE', 'Partner score weight: repeat business (OD-42)'),
  ('perf.weight.new_logos',               '10', 'DECIMAL', 0, 100, NULL, 'PERFORMANCE', 'Partner score weight: new logos (OD-42)'),
  ('perf.weight.strategic',               '5',  'DECIMAL', 0, 100, NULL, 'PERFORMANCE', 'Partner score weight: strategic accounts (OD-42)'),
  ('perf.weight.competition_replacement', '5',  'DECIMAL', 0, 100, NULL, 'PERFORMANCE', 'Partner score weight: competition replacement (OD-42)'),
  ('perf.weight.update_discipline',       '10', 'DECIMAL', 0, 100, NULL, 'PERFORMANCE', 'Partner score weight: weekly status discipline (OD-42)');

DELIMITER $$

DROP PROCEDURE IF EXISTS spi_partner_scorecards $$
CREATE PROCEDURE spi_partner_scorecards(IN p_from DATE, IN p_to DATE)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  DECLARE v_max_rev DECIMAL(18,2) DEFAULT 0;
  DECLARE w_win, w_rev, w_pay, w_rep, w_new, w_str, w_cmp, w_upd, w_sum DECIMAL(16,2);

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

  -- the weighted score (OD-42 default weights, editable settings perf.weight.*): each signal
  -- scores 0..1 and the sum is scaled to 0..100. Counts: 2 or more repeat / new-logo deals,
  -- 1 or more strategic / replacement deal score full (OD-43 defaults, D-50).
  CALL spi_setting_decimal('perf.weight.win_pct', 25, w_win);
  CALL spi_setting_decimal('perf.weight.revenue', 20, w_rev);
  CALL spi_setting_decimal('perf.weight.timely_payment', 15, w_pay);
  CALL spi_setting_decimal('perf.weight.repeat_business', 10, w_rep);
  CALL spi_setting_decimal('perf.weight.new_logos', 10, w_new);
  CALL spi_setting_decimal('perf.weight.strategic', 5, w_str);
  CALL spi_setting_decimal('perf.weight.competition_replacement', 5, w_cmp);
  CALL spi_setting_decimal('perf.weight.update_discipline', 10, w_upd);
  SET w_sum = w_win + w_rev + w_pay + w_rep + w_new + w_str + w_cmp + w_upd;
  SELECT IFNULL(MAX(revenue), 0) INTO v_max_rev FROM tmp_card;
  UPDATE tmp_card
     SET score = ROUND(100 * (
                   w_win * IFNULL(win_pct, 50) / 100
                 + w_rev * IF(v_max_rev > 0, LEAST(1, revenue / v_max_rev), 0)
                 + w_pay * IFNULL(on_time_payment_pct, 75) / 100
                 + w_rep * LEAST(1, repeat_business / 2)
                 + w_new * LEAST(1, new_logos / 2)
                 + w_str * LEAST(1, strategic_accounts)
                 + w_cmp * LEAST(1, competition_replacement)
                 + w_upd * IFNULL(update_discipline_pct, 0) / 100) / NULLIF(w_sum, 0), 1)
   WHERE active_deals + closed_deals > 0;
  -- five bands (OD-42) and the tier recommendation (OD-38 tiers)
  UPDATE tmp_card
     SET rating = CASE WHEN score >= 80 THEN 5 WHEN score >= 65 THEN 4 WHEN score >= 50 THEN 3 WHEN score >= 35 THEN 2 ELSE 1 END,
         tier_recommendation = CASE WHEN score >= 65 THEN 'STRATEGIC' WHEN score >= 45 THEN 'GROWTH' ELSE 'TRANSACTIONAL' END
   WHERE score IS NOT NULL;
END $$


-- ---------------------------------------------------------------------------
-- spi_partner_snapshot_write: tmp_card (from spi_partner_scorecards) → one quarter
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_partner_snapshot_write $$
CREATE PROCEDURE spi_partner_snapshot_write(IN p_fy SMALLINT, IN p_q TINYINT, IN p_frozen TINYINT(1))
  SQL SECURITY DEFINER
BEGIN
  -- open rows are replaced; INSERT IGNORE keeps the frozen ones as they were
  DELETE FROM partner_performance_snapshot WHERE fiscal_year = p_fy AND quarter = p_q AND is_frozen = 0;
  INSERT IGNORE INTO partner_performance_snapshot (
    partner_id, fiscal_year, quarter, sourced_count, sourced_value, influenced_count, influenced_value,
    active_deals, closed_deals, won_deals, lost_deals, win_pct, avg_deal_size, revenue, gm_pct, np_pct,
    lead_to_deal_days, order_to_book_days, on_time_payment_pct, avg_payment_delay_days,
    repeat_business_count, new_logo_count, strategic_account_count, competition_replacement_count,
    tender_readiness_pct, tender_pipeline_count, tender_pipeline_value, gtm_activity_count,
    cec_engagement_count, product_mix_count, update_discipline_pct, score, rating, tier_recommendation,
    is_frozen, computed_at)
  SELECT c.partner_id, p_fy, p_q, c.sourced_count, c.sourced_value, c.influenced_count, c.influenced_value,
         c.active_deals, c.closed_deals, c.won_deals, c.lost_deals, c.win_pct, c.avg_deal_size, c.revenue,
         c.gm_pct, c.np_pct, c.lead_to_deal_days, c.order_to_book_days, c.on_time_payment_pct,
         c.avg_payment_delay_days, c.repeat_business, c.new_logos, c.strategic_accounts,
         c.competition_replacement, c.tender_readiness_pct, c.tender_pipeline_count, c.tender_pipeline_value,
         c.gtm_activities, c.cec_engagements, c.product_mix, c.update_discipline_pct, c.score, c.rating,
         c.tier_recommendation, p_frozen, UTC_TIMESTAMP(3)
    FROM tmp_card c;
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_performance_recompute
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_performance_recompute $$
CREATE PROCEDURE sp_partner_performance_recompute()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_fy    SMALLINT;
  DECLARE v_q     TINYINT;
  DECLARE v_from  DATE;
  DECLARE v_to    DATE;
  DECLARE v_today DATE;
  DECLARE v_pfy   SMALLINT;
  DECLARE v_pq    TINYINT;
  DECLARE v_count INT DEFAULT 0;
  DECLARE v_fyf   SMALLINT;
  DECLARE v_fyq   TINYINT;

  -- the current quarter: an open snapshot, replaced on every run
  CALL spi_dashboard_period(NULL, NULL, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_partner_scorecards(v_from, v_to);
  CALL spi_partner_snapshot_write(v_fy, v_q, 0);
  SELECT COUNT(*) INTO v_count FROM tmp_card;

  -- the previous quarter: frozen at its first run after the quarter ended
  SET v_pfy = IF(v_q = 1, v_fy - 1, v_fy);
  SET v_pq = IF(v_q = 1, 4, v_q - 1);
  CALL spi_dashboard_period(v_pfy, v_pq, v_pfy, v_pq, v_from, v_to, v_today);
  CALL spi_partner_scorecards(v_from, v_to);
  CALL spi_partner_snapshot_write(v_pfy, v_pq, 1);

  -- the fiscal year to date: the current values on the partner (lists, workspace)
  CALL spi_dashboard_period(v_fy, NULL, v_fyf, v_fyq, v_from, v_to, v_today);
  CALL spi_partner_scorecards(v_from, v_to);
  UPDATE partner p JOIN tmp_card c ON c.partner_id = p.id
     SET p.perf_pipeline_value = c.pipeline, p.perf_deals_won = c.won_deals, p.perf_win_pct = c.win_pct,
         p.perf_score = c.score, p.perf_rating = c.rating, p.perf_computed_at = UTC_TIMESTAMP(3);

  DROP TEMPORARY TABLE IF EXISTS tmp_card;
  DROP TEMPORARY TABLE IF EXISTS tmp_pd;
  SELECT v_count AS partners, v_fy AS fiscalYear, v_q AS quarter;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V033', 'Partner performance: weighted score, quarter snapshots, recompute', UTC_TIMESTAMP());
