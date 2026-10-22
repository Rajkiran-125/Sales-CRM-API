-- =============================================================================
-- DEMO ONLY - sample sales data for the management dashboard        (2026-10-09)
--
-- NEVER run this on a live database. It loads, for the demo team created by
-- `npm run seed:demo`:
--   15 customer accounts, 6 partners, 64 deals (40 open across every stage, 12 won,
--   8 lost with reasons, 4 dormant), partners on deals, weekly status, this month's
--   closure commitment, win / loss records, stage history, 10 leads (4 converted)
--   and quarterly targets for the current fiscal year.
-- Dates are relative to the day you run it, so the dashboard always looks current.
-- Values are in INR. Every demo account is marked "Demo data" in its notes.
--
-- Rows are inserted directly (Phase 1 screens and their procedures do not exist yet),
-- so they are not in the audit log. Business numbers come from the same generator as
-- the app (ACC-0001, PTR-0001, LD-2026-0001, OPP-2026-0001).
--
-- Prerequisites: V001-V007 and `npm run seed:demo` (the demo users own the deals).
-- Runs once: stops with "Demo sales data is already loaded" on a second run.
-- =============================================================================

USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS tmp_demo_sales_data $$
CREATE PROCEDURE tmp_demo_sales_data()
BEGIN
  DECLARE v_today       DATE;
  DECLARE v_fy          SMALLINT;
  DECLARE v_q           TINYINT;
  DECLARE v_q_start     DATE;
  DECLARE v_q_end       DATE;
  DECLARE v_month_start DATE;
  DECLARE v_next_month  DATE;
  DECLARE v_week_start  DATE;
  DECLARE v_head        BIGINT UNSIGNED;
  DECLARE v_sanjay      BIGINT UNSIGNED;
  DECLARE v_ananya      BIGINT UNSIGNED;
  DECLARE v_no          VARCHAR(30);
  DECLARE i             INT;
  DECLARE n             INT;
  -- per deal
  DECLARE v_letter      CHAR(1);
  DECLARE v_stage       VARCHAR(20);
  DECLARE v_seq         INT;
  DECLARE v_conf        DECIMAL(5,2);
  DECLARE v_override    DECIMAL(5,2);
  DECLARE v_acc         INT;
  DECLARE v_acc_id      BIGINT UNSIGNED;
  DECLARE v_acc_short   VARCHAR(60);
  DECLARE v_industry    VARCHAR(30);
  DECLARE v_owner       BIGINT UNSIGNED;
  DECLARE v_backup      BIGINT UNSIGNED;
  DECLARE v_prod        INT;
  DECLARE v_prod_id     BIGINT UNSIGNED;
  DECLARE v_sol_id      BIGINT UNSIGNED;
  DECLARE v_value       DECIMAL(16,2);
  DECLARE v_weighted    DECIMAL(16,2);
  DECLARE v_source      VARCHAR(10);
  DECLARE v_created     DATE;
  DECLARE v_close       DATE;
  DECLARE v_closed      DATE;
  DECLARE v_entered     DATE;
  DECLARE v_health      VARCHAR(10);
  DECLARE v_opp_id      BIGINT UNSIGNED;
  DECLARE v_partner     INT;
  DECLARE v_role        VARCHAR(12);
  DECLARE v_days_q      INT;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF EXISTS (SELECT 1 FROM account WHERE notes = 'Demo data (demo_sales_data.sql)') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Demo sales data is already loaded.';
  END IF;
  SELECT id INTO v_head FROM `user` WHERE email = 'vikram.mehta@cnergee.test';
  SELECT id INTO v_sanjay FROM `user` WHERE email = 'sanjay.gupta@cnergee.test';
  SELECT id INTO v_ananya FROM `user` WHERE email = 'ananya.bose@cnergee.test';
  IF v_head IS NULL OR v_sanjay IS NULL OR v_ananya IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The demo team is missing: run npm run seed:demo first.';
  END IF;

  CALL spi_dashboard_period(NULL, NULL, v_fy, v_q, v_q_start, v_q_end, v_today);
  SET v_month_start = v_today - INTERVAL (DAY(v_today) - 1) DAY;
  SET v_next_month = v_month_start + INTERVAL 1 MONTH;
  SET v_week_start = v_today - INTERVAL WEEKDAY(v_today) DAY;
  SET v_days_q = GREATEST(DATEDIFF(v_today, v_q_start), 0);

  -- ---------------------------------------------------------------- reference lists
  DROP TEMPORARY TABLE IF EXISTS demo_acc;
  CREATE TEMPORARY TABLE demo_acc (
    k INT PRIMARY KEY, id BIGINT UNSIGNED NULL, name VARCHAR(200), short_name VARCHAR(60),
    industry VARCHAR(30), city VARCHAR(100), state VARCHAR(80), owner_email VARCHAR(150),
    strategic TINYINT
  );
  INSERT INTO demo_acc (k, name, short_name, industry, city, state, owner_email, strategic) VALUES
    (1,  'Sahyadri Co-operative Bank',     'Sahyadri Bank',     'BFSI',          'Pune',        'Maharashtra',    'rohan.deshpande@cnergee.test', 1),
    (2,  'Coastal Finance Ltd',            'Coastal Finance',   'BFSI',          'Mumbai',      'Maharashtra',    'sneha.patil@cnergee.test',     0),
    (3,  'Pune Municipal Services Board',  'PMSB',              'GOVT',          'Pune',        'Maharashtra',    'neha.joshi@cnergee.test',      1),
    (4,  'Konkan Logistics Pvt Ltd',       'Konkan Logistics',  'LOGISTICS',     'Navi Mumbai', 'Maharashtra',    'sneha.patil@cnergee.test',     0),
    (5,  'Malabar Health Network',         'Malabar Health',    'HEALTHCARE',    'Kochi',       'Kerala',         'divya.narayanan@cnergee.test', 0),
    (6,  'Deccan Institute of Technology', 'DIT Hyderabad',     'EDUCATION',     'Hyderabad',   'Telangana',      'arjun.rao@cnergee.test',       0),
    (7,  'Kaveri Retail Stores',           'Kaveri Retail',     'RETAIL',        'Bengaluru',   'Karnataka',      'lakshmi.iyer@cnergee.test',    0),
    (8,  'Nilgiri Hotels & Resorts',       'Nilgiri Hotels',    'HOSPITALITY',   'Coimbatore',  'Tamil Nadu',     'karthik.raman@cnergee.test',   0),
    (9,  'TechPark Software Services',     'TechPark',          'IT_ITES',       'Chennai',     'Tamil Nadu',     'divya.narayanan@cnergee.test', 1),
    (10, 'Indus Manufacturing Works',      'Indus Mfg',         'MANUFACTURING', 'Ludhiana',    'Punjab',         'pooja.sharma@cnergee.test',    0),
    (11, 'Yamuna State Transport Corp',    'YSTC',              'GOVT',          'New Delhi',   'Delhi',          'amandeep.singh@cnergee.test',  1),
    (12, 'Capital Care Hospitals',         'Capital Care',      'HEALTHCARE',    'Gurugram',    'Haryana',        'pooja.sharma@cnergee.test',    0),
    (13, 'Himalaya University',            'Himalaya Univ',     'EDUCATION',     'Dehradun',    'Uttarakhand',    'rahul.verma@cnergee.test',     0),
    (14, 'NetWave Broadband',              'NetWave',           'ISP',           'Jaipur',      'Rajasthan',      'amandeep.singh@cnergee.test',  0),
    (15, 'Saraswati Public Schools',       'Saraswati Schools', 'EDUCATION',     'Lucknow',     'Uttar Pradesh',  'pooja.sharma@cnergee.test',    0);

  DROP TEMPORARY TABLE IF EXISTS demo_ptr;
  CREATE TEMPORARY TABLE demo_ptr (
    k INT PRIMARY KEY, id BIGINT UNSIGNED NULL, legal_name VARCHAR(250), short_name VARCHAR(150),
    type_code VARCHAR(30), city VARCHAR(100), tier VARCHAR(15), owner_email VARCHAR(150)
  );
  INSERT INTO demo_ptr (k, legal_name, short_name, type_code, city, tier, owner_email) VALUES
    (1, 'Orbit Systems Integrators Pvt Ltd', 'Orbit Systems',  'SI',         'Mumbai',    'STRATEGIC',     'farhan.qureshi@cnergee.test'),
    (2, 'TeleLink Networks Ltd',             'TeleLink',       'TELCO',      'Bengaluru', 'STRATEGIC',     'farhan.qureshi@cnergee.test'),
    (3, 'Prime IT Distributors Pvt Ltd',     'Prime IT',       'VAD',        'New Delhi', 'GROWTH',        'farhan.qureshi@cnergee.test'),
    (4, 'SecureEdge Managed Services',       'SecureEdge MSP', 'MSP',        'Chennai',   'GROWTH',        'neha.joshi@cnergee.test'),
    (5, 'Zenith Technology Consulting',      'Zenith Consulting', 'CONSULTANT', 'Pune',   'TRANSACTIONAL', 'farhan.qureshi@cnergee.test'),
    (6, 'Bharat Govt Solutions Ltd',         'Bharat GovSol',  'GOVT_PSU',   'New Delhi', 'STRATEGIC',     'farhan.qureshi@cnergee.test');

  START TRANSACTION;

  -- ---------------------------------------------------------------- accounts
  SET i = 1;
  WHILE i <= 15 DO
    CALL spi_next_number('ACC', 0, v_no);
    INSERT INTO account (account_no, name, industry_id, account_type, is_strategic, country, state, city,
                         owner_user_id, backup_owner_user_id, notes, created_by)
    SELECT v_no, d.name, ind.id, 'PROSPECT', d.strategic, 'India', d.state, d.city,
           u.id, u.reporting_to_user_id, 'Demo data (demo_sales_data.sql)', u.id
      FROM demo_acc d
      JOIN industry ind ON ind.code = d.industry
      JOIN `user` u ON u.email = d.owner_email
     WHERE d.k = i;
    UPDATE demo_acc SET id = LAST_INSERT_ID() WHERE k = i;
    SET i = i + 1;
  END WHILE;

  -- ---------------------------------------------------------------- partners
  SET i = 1;
  WHILE i <= 6 DO
    CALL spi_next_number('PTR', 0, v_no);
    INSERT INTO partner (partner_no, legal_name, short_name, country, city, agreement_status, tier,
                         relationship_owner_user_id, backup_owner_user_id, profile_completeness_pct, created_by)
    SELECT v_no, d.legal_name, d.short_name, 'India', d.city, IF(d.tier = 'TRANSACTIONAL', 'IN_NEGOTIATION', 'SIGNED'),
           d.tier, u.id, u.reporting_to_user_id, 40, u.id
      FROM demo_ptr d
      JOIN `user` u ON u.email = d.owner_email
     WHERE d.k = i;
    UPDATE demo_ptr SET id = LAST_INSERT_ID() WHERE k = i;
    INSERT INTO partner_type_map (partner_id, partner_type_id)
    SELECT d.id, pt.id FROM demo_ptr d JOIN partner_type pt ON pt.code = d.type_code WHERE d.k = i;
    SET i = i + 1;
  END WHILE;

  -- ---------------------------------------------------------------- deals
  -- Q qualified, T tech engagement, P POC, R proposal, N negotiation, C commercial closed,
  -- S contract signed, W won, L lost, D dormant
  SET n = 1;
  WHILE n <= 64 DO
    SET v_letter = SUBSTRING('QSTLNQWPLNQWRLCTWRDSTWRQWPLNQWPLNQWRDCTWRDSTLNQWPLNQWPLCTWRDCTWR', n, 1);
    SET v_stage = ELT(LOCATE(v_letter, 'QTPRNCSWLD'), 'QUALIFIED', 'TECH_ENGAGEMENT', 'POC', 'PROPOSAL',
                      'NEGOTIATION', 'COMMERCIAL_CLOSED', 'CONTRACT_SIGNED', 'WON', 'LOST', 'DORMANT');
    SELECT sequence_no, default_confidence_pct INTO v_seq, v_conf FROM stage WHERE entity = 'OPP' AND code = v_stage;

    SET v_acc = 1 + MOD(n * 7, 15);
    SELECT d.id, d.short_name, d.industry, a.owner_user_id, a.backup_owner_user_id
      INTO v_acc_id, v_acc_short, v_industry, v_owner, v_backup
      FROM demo_acc d JOIN account a ON a.id = d.id WHERE d.k = v_acc;
    IF v_backup IS NULL THEN SET v_backup = v_head; END IF;

    SET v_prod = 1 + MOD(n, 4);
    SELECT id INTO v_prod_id FROM product WHERE code = ELT(v_prod, 'SDWAN', 'FIREWALL', 'WIFI', 'ENDPOINT');
    SET v_sol_id = NULL;
    SELECT MIN(id) INTO v_sol_id FROM solution WHERE product_id = v_prod_id AND is_active = 1;

    -- value: product range, government deals 1.5x, rounded to INR 50,000
    SET v_value = ELT(v_prod, 4000000, 1500000, 1000000, 800000)
                + (ELT(v_prod, 16000000, 6500000, 5000000, 3200000) * MOD(n * 37, 11) / 10);
    IF v_industry = 'GOVT' THEN SET v_value = v_value * 1.5; END IF;
    SET v_value = ROUND(v_value / 50000) * 50000;

    IF v_industry IN ('GOVT', 'EDUCATION') AND MOD(n, 2) = 0 THEN
      SET v_source = 'TENDER';
    ELSE
      SET v_source = ELT(1 + MOD(n * 3, 10), 'PARTNER', 'PARTNER', 'DIRECT', 'PARTNER', 'REFERRAL',
                         'PARTNER', 'DIRECT', 'EVENT', 'PARTNER', 'WEBSITE');
    END IF;

    SET v_override = NULL;
    SET v_closed = NULL;
    IF v_stage IN ('WON', 'LOST') THEN
      -- a third close in the current quarter (up to today), the rest in the two before
      IF MOD(n, 3) = 0 THEN
        SET v_closed = v_q_start + INTERVAL MOD(n * 5, v_days_q + 1) DAY;
      ELSE
        SET v_closed = v_q_start - INTERVAL (1 + MOD(n * 17, 180)) DAY;
      END IF;
      SET v_created = v_closed - INTERVAL (35 + MOD(n * 19, 120)) DAY;
      SET v_close = v_closed;
      SET v_entered = v_closed;
      SET v_weighted = IF(v_stage = 'WON', v_value, 0);
      SET v_health = 'ON_TRACK';
    ELSEIF v_stage = 'DORMANT' THEN
      SET v_created = v_today - INTERVAL (100 + MOD(n * 7, 60)) DAY;
      SET v_close = v_today + INTERVAL (90 + MOD(n, 60)) DAY;
      SET v_entered = v_today - INTERVAL (10 + MOD(n, 20)) DAY;
      SET v_weighted = 0;
      SET v_health = 'ON_TRACK';
    ELSE
      SET v_created = v_today - INTERVAL (3 + MOD(n * 23, 160)) DAY;
      -- slipped deals (close date already passed) stay inside the current quarter
      SET v_close = GREATEST(v_q_start, v_today + INTERVAL (MOD(n * 13, 170) - 12) DAY);
      SET v_entered = LEAST(v_today, v_created + INTERVAL (5 + v_seq * 9) DAY);
      IF MOD(n, 11) = 0 THEN SET v_override = LEAST(v_conf + 15, 95); END IF;
      SET v_weighted = ROUND(v_value * IFNULL(v_override, v_conf) / 100, 2);
      SET v_health = CASE
                       WHEN v_close < v_today THEN 'SLIPPED'
                       WHEN MOD(n, 7) = 0 THEN 'AT_RISK'
                       WHEN MOD(n, 9) = 0 THEN 'STALE'
                       ELSE 'ON_TRACK'
                     END;
    END IF;

    CALL spi_next_number('OPP', 1, v_no);
    INSERT INTO opportunity (
      opportunity_no, title, account_id, source, industry_id, solution_id, problem_statement,
      stage_code, stage_entered_at, previous_stage_code, confidence_override_pct, confidence_override_reason,
      expected_value, weighted_value, expected_close_date, commercial_window_value, commercial_window_accepted,
      budget_known, procurement_type_id, procurement_steps_known,
      validation_status, validated_by, validated_at,
      owner_user_id, backup_owner_user_id, presales_owner_user_id, partner_tbm,
      final_value, po_number, po_date, po_value, closed_at,
      dormant_reason_id, dormant_note, wake_up_date,
      health, last_activity_at, last_status_at, created_at, created_by)
    SELECT
      v_no,
      CONCAT(ELT(v_prod, 'Branch SD-WAN rollout', 'Perimeter firewall refresh', 'Campus Wi-Fi upgrade',
                 'Endpoint protection'), ' - ', v_acc_short, IF(n > 40, ' (phase 2)', '')),
      v_acc_id, v_source, (SELECT industry_id FROM account WHERE id = v_acc_id), v_sol_id,
      ELT(v_prod, 'Branch links are unreliable and MPLS costs are rising.',
                  'Ageing firewalls are out of support and audit flagged gaps.',
                  'Wi-Fi coverage and guest access do not meet current needs.',
                  'No central view of endpoint threats across sites.'),
      v_stage, TIMESTAMP(v_entered, '06:30:00'),
      IF(v_seq > 1 AND v_stage NOT IN ('DORMANT'), 'QUALIFIED', NULL),
      v_override, IF(v_override IS NULL, NULL, 'Customer confirmed the budget in writing.'),
      v_value, v_weighted, v_close,
      IF(v_seq >= 3, v_value, NULL), IF(v_seq >= 3, 1, 0),
      'YES', (SELECT id FROM procurement_type WHERE code = IF(v_source = 'TENDER', 'TENDER', IF(MOD(n, 3) = 0, 'RFP', 'DIRECT_PO'))),
      IF(v_seq >= 2, 1, 0),
      IF(v_stage = 'QUALIFIED' AND MOD(n, 2) = 1, 'PENDING', 'VALID'),
      IF(v_stage = 'QUALIFIED' AND MOD(n, 2) = 1, NULL, v_head),
      IF(v_stage = 'QUALIFIED' AND MOD(n, 2) = 1, NULL, TIMESTAMP(v_created + INTERVAL 3 DAY, '06:30:00')),
      v_owner, v_backup,
      IF(v_seq BETWEEN 2 AND 8 OR v_stage = 'LOST', IF(MOD(n, 2) = 0, v_sanjay, v_ananya), NULL),
      IF(v_source = 'PARTNER', 0, IF(MOD(n, 5) = 0, 1, 0)),
      IF(v_stage = 'WON', ROUND(v_value * (0.92 + MOD(n, 9) / 100) / 10000) * 10000, NULL),
      IF(v_stage = 'WON', CONCAT('PO/', YEAR(v_closed), '/', LPAD(n, 3, '0')), NULL),
      IF(v_stage = 'WON', v_closed, NULL),
      IF(v_stage = 'WON', ROUND(v_value * (0.92 + MOD(n, 9) / 100) / 10000) * 10000, NULL),
      IF(v_closed IS NULL, NULL, TIMESTAMP(v_closed, '06:30:00')),
      IF(v_stage = 'DORMANT', (SELECT id FROM reason WHERE reason_type = 'DORMANT' AND code = 'CUSTOMER_PAUSED'), NULL),
      IF(v_stage = 'DORMANT', 'Customer paused the project until the next budget cycle.', NULL),
      IF(v_stage = 'DORMANT', v_today + INTERVAL (30 + MOD(n, 30)) DAY, NULL),
      v_health,
      TIMESTAMP(LEAST(v_today, IFNULL(v_closed, v_today - INTERVAL MOD(n, 10) DAY)), '06:30:00'),
      IF(v_seq <= 7, TIMESTAMP(v_week_start - INTERVAL 3 DAY, '12:00:00'), NULL),
      TIMESTAMP(v_created, '05:00:00'), v_owner;
    SET v_opp_id = LAST_INSERT_ID();

    INSERT INTO opportunity_product (opportunity_id, product_id, is_primary, created_by)
    VALUES (v_opp_id, v_prod_id, 1, v_owner);

    -- partners on the deal (BR-OP-12)
    SET v_partner = NULL;
    IF v_source = 'PARTNER' THEN
      SET v_partner = 1 + MOD(n, 5); SET v_role = 'SOURCED';
    ELSEIF v_source = 'TENDER' THEN
      SET v_partner = 6; SET v_role = 'FULFILMENT';
    ELSEIF MOD(n, 4) = 0 THEN
      SET v_partner = 1 + MOD(n + 2, 5); SET v_role = 'INFLUENCED';
    END IF;
    IF v_partner IS NOT NULL THEN
      INSERT INTO opportunity_partner (opportunity_id, partner_id, partner_role, engagement_level, is_primary,
                                       commercial_confirmed, created_by)
      SELECT v_opp_id, id, v_role, ELT(1 + MOD(n, 3), 'HIGH', 'MEDIUM', 'LOW'), 1, IF(v_seq >= 4, 1, 0), v_owner
        FROM demo_ptr WHERE k = v_partner;
    END IF;

    -- stage history
    INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by, changed_at)
    VALUES ('OPP', v_opp_id, NULL, 'QUALIFIED', v_owner, TIMESTAMP(v_created, '05:00:00'));
    IF v_stage <> 'QUALIFIED' THEN
      INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by, changed_at, days_in_previous, reason)
      VALUES ('OPP', v_opp_id, 'QUALIFIED', v_stage, v_owner, TIMESTAMP(v_entered, '06:30:00'),
              GREATEST(DATEDIFF(v_entered, v_created), 0),
              IF(v_stage = 'DORMANT', 'Customer paused the project.', NULL));
    END IF;

    -- win / loss (UM 6.6)
    IF v_stage = 'WON' THEN
      INSERT INTO win_loss (opportunity_id, outcome, detail, lesson, competition_replaced, recorded_by, recorded_at)
      VALUES (v_opp_id, 'WON', 'Customer chose us after the technical evaluation and a reference visit.',
              'Early POC and a strong partner made the difference.', IF(MOD(n, 4) = 0, 1, 0), v_owner,
              TIMESTAMP(v_closed, '06:30:00'));
      INSERT INTO win_loss_reason (opportunity_id, reason_id)
      SELECT v_opp_id, id FROM reason
       WHERE reason_type = 'WIN' AND code IN (ELT(1 + MOD(n, 4), 'PRODUCT_FIT', 'RELATIONSHIP', 'POC', 'PARTNER'),
                                               ELT(1 + MOD(n, 3), 'PRICE', 'SPEED', 'REFERENCE'));
    ELSEIF v_stage = 'LOST' THEN
      INSERT INTO win_loss (opportunity_id, outcome, loss_reason_id, competitor_id, detail, lesson, recorded_by, recorded_at)
      SELECT v_opp_id, 'LOST', r.id,
             IF(r.competitor_required = 1,
                COALESCE((SELECT c.id FROM competitor c
                           WHERE c.name = ELT(1 + MOD(n, 4), 'Fortinet', 'Cisco', 'Palo Alto Networks', 'Sophos')),
                         (SELECT MIN(c.id) FROM competitor c)),
                NULL),
             ELT(1 + MOD(n, 5),
                 'The competitor offered a lower price with a bundled support contract.',
                 'The customer standardised on an existing vendor across all sites.',
                 'The budget was moved to another project this year.',
                 'The customer needed delivery before we could commit.',
                 'No decision was taken; the evaluation was put on hold.'),
             'Engage the commercial buyer earlier and confirm the budget.', v_owner,
             TIMESTAMP(v_closed, '06:30:00')
        FROM reason r
       WHERE r.reason_type = 'LOSS' AND r.code = ELT(1 + MOD(n, 5), 'PRICE', 'COMPETITOR', 'NO_BUDGET', 'TIMELINE', 'NO_DECISION');
    END IF;

    -- weekly status for open deals (BR-FC-01); every sixth deal is overdue
    IF v_seq <= 7 AND MOD(n, 6) <> 0 AND v_created < v_week_start - INTERVAL 7 DAY THEN
      INSERT INTO weekly_status (opportunity_id, week_start, status, this_week, next_step, expected_close_date,
                                 expected_value, stage_code, submitted_by, submitted_at)
      VALUES (v_opp_id, v_week_start - INTERVAL 7 DAY,
              CASE v_health WHEN 'SLIPPED' THEN 'SLIPPED' WHEN 'AT_RISK' THEN 'AT_RISK' ELSE 'ON_TRACK' END,
              ELT(1 + MOD(n, 5), 'Technical workshop held with the IT team.',
                  'Shared the revised BoQ with the customer.', 'POC environment set up; first results positive.',
                  'Commercial discussion with procurement.', 'Partner meeting to align on pricing.'),
              ELT(1 + MOD(n, 4), 'Send the final proposal.', 'Meet the commercial buyer.',
                  'Close the POC readout.', 'Confirm the PO timeline.'),
              v_close, v_value, v_stage, v_owner, TIMESTAMP(v_week_start - INTERVAL 3 DAY, '12:00:00'));
      IF MOD(n, 2) = 0 AND v_today >= v_week_start + INTERVAL 1 DAY THEN
        INSERT INTO weekly_status (opportunity_id, week_start, status, this_week, next_step, expected_close_date,
                                   expected_value, stage_code, submitted_by, submitted_at)
        VALUES (v_opp_id, v_week_start,
                CASE v_health WHEN 'SLIPPED' THEN 'SLIPPED' WHEN 'AT_RISK' THEN 'AT_RISK' ELSE 'ON_TRACK' END,
                'Follow-up call with the customer.', 'Update the deal after the review.',
                v_close, v_value, v_stage, v_owner, UTC_TIMESTAMP(3));
      END IF;
    END IF;

    -- this month's closure commitment (BR-FC-03)
    IF v_seq <= 7 AND v_close BETWEEN v_month_start AND LAST_DAY(v_month_start) THEN
      INSERT INTO monthly_commit (opportunity_id, commit_month, commit_type, commit_value, committed_by, committed_at)
      VALUES (v_opp_id, v_month_start, IF(v_seq >= 5, 'COMMIT', 'UPSIDE'), v_value, v_owner,
              TIMESTAMP(v_month_start + INTERVAL 2 DAY, '06:30:00'));
    ELSEIF v_seq BETWEEN 4 AND 7 AND v_close BETWEEN v_next_month AND LAST_DAY(v_next_month) THEN
      INSERT INTO monthly_commit (opportunity_id, commit_month, commit_type, commit_value, committed_by, committed_at)
      VALUES (v_opp_id, v_month_start, 'NEXT_MONTH', v_value, v_owner,
              TIMESTAMP(v_month_start + INTERVAL 2 DAY, '06:30:00'));
    END IF;

    SET n = n + 1;
  END WHILE;

  -- accounts with a won deal become customers (new-logo date, BR-AC-03)
  UPDATE account a
    JOIN (SELECT o.account_id, MIN(DATE(o.closed_at)) AS first_won
            FROM opportunity o WHERE o.stage_code = 'WON' GROUP BY o.account_id) w ON w.account_id = a.id
     SET a.account_type = 'CUSTOMER', a.first_won_on = w.first_won
   WHERE a.notes = 'Demo data (demo_sales_data.sql)';

  -- ---------------------------------------------------------------- leads (not on the dashboard, BR-LD-03)
  -- leads 1-4 were converted into the first four early-stage demo deals; 5-10 are still leads
  DROP TEMPORARY TABLE IF EXISTS demo_conv;
  CREATE TEMPORARY TABLE demo_conv (k INT AUTO_INCREMENT PRIMARY KEY, opp_id BIGINT UNSIGNED NOT NULL);
  INSERT INTO demo_conv (opp_id)
  SELECT o.id FROM opportunity o JOIN account a ON a.id = o.account_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND o.stage_code IN ('QUALIFIED', 'TECH_ENGAGEMENT')
   ORDER BY o.id LIMIT 4;

  SET i = 1;
  WHILE i <= 10 DO
    CALL spi_next_number('LD', 1, v_no);
    INSERT INTO sales_lead (lead_no, source, partner_id, account_id, account_name_text, industry_id, contact_name,
                            contact_designation, city, need_text, rough_value, rough_timing, owner_user_id,
                            next_action, next_action_due_on, stage_code, stage_entered_at,
                            opportunity_id, converted_at, created_at, created_by)
    SELECT v_no,
           IF(MOD(i, 2) = 0, 'PARTNER', ELT(1 + MOD(i, 3), 'DIRECT', 'EVENT', 'WEBSITE')),
           IF(MOD(i, 2) = 0, (SELECT id FROM demo_ptr WHERE k = 1 + MOD(i, 5)), NULL),
           IF(i <= 4, o.account_id, NULL),
           IF(i <= 4, NULL, ELT(i - 4, 'Vindhya Cement Ltd', 'Godavari Agro Foods', 'Sunrise Hospitals Trust',
                                       'Metro Cooperative Bank', 'Ganga Polytechnic', 'Aravalli Resorts')),
           IF(i <= 4, o.industry_id,
              (SELECT id FROM industry WHERE code = ELT(i - 4, 'MANUFACTURING', 'MANUFACTURING', 'HEALTHCARE',
                                                          'BFSI', 'EDUCATION', 'HOSPITALITY'))),
           ELT(i, 'Anil Kapoor', 'Sunita Rao', 'Manoj Pillai', 'Ritu Malhotra', 'Deepak Jain',
                  'Kavya Menon', 'Harish Gowda', 'Nisha Agarwal', 'Prakash Yadav', 'Shalini Verma'),
           ELT(1 + MOD(i, 3), 'Head of IT', 'CIO', 'IT Manager'),
           IF(i <= 4, (SELECT city FROM account WHERE id = o.account_id),
              ELT(i - 4, 'Indore', 'Nashik', 'Mysuru', 'Thane', 'Patna', 'Udaipur')),
           ELT(1 + MOD(i, 4), 'Wants to replace MPLS links at 40 branches.', 'Asked about a firewall refresh.',
               'Needs Wi-Fi across a new campus.', 'Looking for endpoint protection for 800 laptops.'),
           ELT(1 + MOD(i, 4), 6000000, 2500000, 1800000, 1200000),
           ELT(1 + MOD(i, 3), 'This quarter', 'Next quarter', 'Within 6 months'),
           IF(i <= 4, o.owner_user_id,
              (SELECT id FROM `user` WHERE email = ELT(i - 4, 'rohan.deshpande@cnergee.test', 'sneha.patil@cnergee.test',
                                                       'divya.narayanan@cnergee.test', 'arjun.rao@cnergee.test',
                                                       'pooja.sharma@cnergee.test', 'lakshmi.iyer@cnergee.test'))),
           IF(i <= 4, 'Converted to a deal.', 'Call to understand the requirement.'),
           v_today + INTERVAL (2 + i) DAY,
           IF(i <= 4, 'CONVERTED', ELT(1 + MOD(i, 3), 'NEW', 'CONTACTED', 'QUALIFYING')),
           IF(i <= 4, o.created_at, UTC_TIMESTAMP(3) - INTERVAL (2 + i) DAY),
           IF(i <= 4, o.id, NULL),
           IF(i <= 4, o.created_at, NULL),
           IF(i <= 4, o.created_at - INTERVAL (10 + 3 * i) DAY, UTC_TIMESTAMP(3) - INTERVAL (5 + i) DAY),
           (SELECT id FROM `user` WHERE email = 'vikram.mehta@cnergee.test')
      FROM (SELECT 1 AS one) x
      LEFT JOIN demo_conv dc ON dc.k = i
      LEFT JOIN opportunity o ON o.id = dc.opp_id;
    IF i <= 4 THEN
      UPDATE opportunity o JOIN sales_lead l ON l.opportunity_id = o.id
         SET o.lead_id = l.id
       WHERE l.id = LAST_INSERT_ID();
    END IF;
    SET i = i + 1;
  END WHILE;

  -- ---------------------------------------------------------------- targets for the current fiscal year (OD-15)
  INSERT INTO target (owner_user_id, fiscal_year, quarter, target_value, target_count, new_logo_target, created_by)
  SELECT u.id, v_fy, q.q,
         CASE WHEN u.designation LIKE 'Regional%' THEN 6000000
              WHEN u.designation LIKE 'Senior%' THEN 15000000
              ELSE 10000000 END,
         CASE WHEN u.designation LIKE 'Regional%' THEN 2 ELSE 3 END,
         1, v_head
    FROM `user` u
    JOIN (SELECT 1 AS q UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) q
   WHERE u.email IN ('neha.joshi@cnergee.test', 'karthik.raman@cnergee.test', 'amandeep.singh@cnergee.test',
                     'rohan.deshpande@cnergee.test', 'sneha.patil@cnergee.test', 'divya.narayanan@cnergee.test',
                     'arjun.rao@cnergee.test', 'lakshmi.iyer@cnergee.test', 'pooja.sharma@cnergee.test',
                     'rahul.verma@cnergee.test');

  COMMIT;

  DROP TEMPORARY TABLE IF EXISTS demo_acc;
  DROP TEMPORARY TABLE IF EXISTS demo_ptr;
  DROP TEMPORARY TABLE IF EXISTS demo_conv;

  SELECT (SELECT COUNT(*) FROM account WHERE notes = 'Demo data (demo_sales_data.sql)') AS accounts,
         (SELECT COUNT(*) FROM opportunity o JOIN account a ON a.id = o.account_id
           WHERE a.notes = 'Demo data (demo_sales_data.sql)') AS deals,
         (SELECT COUNT(*) FROM sales_lead l WHERE l.created_by = v_head) AS leads;
END $$

DELIMITER ;

CALL tmp_demo_sales_data();
DROP PROCEDURE IF EXISTS tmp_demo_sales_data;
