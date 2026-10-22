-- =============================================================================
-- DEMO ONLY - partners and tenders                                  (2026-10-12)
--
-- NEVER run this on a live database. Run it after demo_sales_details.sql. It adds:
--   * the five sections of the 6 demo partners (UM 7.1): entity, financials, agreement,
--     types (some partners hold two), industries, certifications, partner codes at
--     customers, technical / sales capability, DMU impact, engagement structure,
--     SPOC contacts, profile completeness
--   * an engagement log per partner (QBR, training, GTM, joint visits, CEC visits) with the
--     next engagement plan, and the 6-month account mapping
--   * tenders (UM 4.4): one for every tender-source demo deal, status matching the deal,
--     plus 3 newly identified tenders with upcoming submission dates; each with the
--     readiness checklist, market intelligence (specification / RFP / pre-bid influence)
--     and, when closed, the result
-- Dates are relative to the day you run it. Rows are inserted directly (D-26).
-- Runs once: a second run stops with "already loaded".
--
-- Prerequisites: V001-V009, `npm run seed:demo`, demo_sales_data.sql, demo_sales_details.sql.
-- =============================================================================

USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS tmp_demo_partners_tenders $$
CREATE PROCEDURE tmp_demo_partners_tenders()
BEGIN
  DECLARE v_today   DATE;
  DECLARE v_head    BIGINT UNSIGNED;
  DECLARE v_farhan  BIGINT UNSIGNED;
  DECLARE v_no      VARCHAR(30);
  DECLARE i         INT;
  DECLARE j         INT;
  DECLARE v_max     INT;
  DECLARE v_pid     BIGINT UNSIGNED;
  DECLARE v_short   VARCHAR(150);
  DECLARE v_owner   BIGINT UNSIGNED;
  -- tenders
  DECLARE v_tid     BIGINT UNSIGNED;
  DECLARE v_opp     BIGINT UNSIGNED;
  DECLARE v_stage   VARCHAR(20);
  DECLARE v_status  VARCHAR(14);
  DECLARE v_acc     BIGINT UNSIGNED;
  DECLARE v_value   DECIMAL(16,2);
  DECLARE v_prod    BIGINT UNSIGNED;
  DECLARE v_t_owner BIGINT UNSIGNED;
  DECLARE v_title   VARCHAR(250);
  DECLARE v_auth    VARCHAR(200);
  DECLARE v_sub     DATE;
  DECLARE v_done    INT;
  DECLARE v_closed  DATE;
  DECLARE v_contacts VARCHAR(500);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF EXISTS (SELECT 1 FROM partner_engagement pe JOIN partner p ON p.id = pe.partner_id
              WHERE p.relationship_owner_user_id IN (SELECT id FROM `user` WHERE email LIKE '%@cnergee.test')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Demo partners and tenders are already loaded.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM task WHERE source_ref LIKE 'demo-%') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Run demo_sales_details.sql first.';
  END IF;

  SET v_today = DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  SELECT id INTO v_head FROM `user` WHERE email = 'vikram.mehta@cnergee.test';
  SELECT id INTO v_farhan FROM `user` WHERE email = 'farhan.qureshi@cnergee.test';

  -- ---------------------------------------------------------------- partner profiles (UM 7.1)
  DROP TEMPORARY TABLE IF EXISTS demo_ptr;
  CREATE TEMPORARY TABLE demo_ptr (
    k INT PRIMARY KEY, short_name VARCHAR(150), address VARCHAR(500), website VARCHAR(255), revenue DECIMAL(16,2),
    credit VARCHAR(40), fin_status VARCHAR(20), extra_type VARCHAR(30), industries VARCHAR(100), certs VARCHAR(100),
    top_customers VARCHAR(1000), share DECIMAL(5,2), smes INT, poc TINYINT, engineers INT, sales_force INT, crm TINYINT,
    coverage VARCHAR(255), influence VARCHAR(1000), dmu VARCHAR(10), dmu_notes VARCHAR(1000), top_mgmt VARCHAR(1000),
    onboarding VARCHAR(30), gtm VARCHAR(30), poc_count INT, poc_value DECIMAL(16,2), feedback INT, feedback_notes VARCHAR(1000),
    completeness DECIMAL(5,2), contacts VARCHAR(500)
  );
  INSERT INTO demo_ptr VALUES
    (1, 'Orbit Systems', 'Unit 402, Kanakia Business Park, Andheri East', 'orbitsystems.example', 1850000000, 'CRISIL A', 'STRONG',
     NULL, 'BFSI,HEALTHCARE,IT_ITES', 'ISO_27001,ISO_9001', 'Sahyadri Co-operative Bank, Capital Care Hospitals, Coastal Finance', 18.00,
     6, 1, 9, 45, 1, 'Mumbai, Pune, Ahmedabad, Bengaluru (12 cities)', 'Close to the CIOs of two co-operative banks; RBI-connected consultants.',
     'HIGH', 'Ran the reference visit that won Sahyadri Bank.', 'R. Nair (MD), S. Kapoor (Sales Director)', 'Trained', 'Agreed', 4, 1800000, 4,
     'Customers rate their installation team highly.', 86.00, 'Ramesh Nair:TOP_MGMT:Managing Director|Sushil Kapoor:COMMERCIAL:Sales Director|Anand Iyer:TECH:Head of Pre-sales|Meera Shah:FINANCE:Finance Manager'),
    (2, 'TeleLink', 'TeleLink Tower, Outer Ring Road', 'telelink.example', 9200000000, 'ICRA AA-', 'STRONG',
     'MSP', 'HOSPITALITY,EDUCATION,GOVT', 'ISO_27001', 'Nilgiri Hotels & Resorts, Himalaya University, Pune Municipal Services Board', 9.50,
     4, 1, 12, 120, 1, 'Pan-India (40 cities), strong in the South', 'Owns the last-mile links at most of our hotel and university customers.',
     'MEDIUM', 'Good at finding requirements early; weaker at closing.', 'V. Rao (CEO), P. Menon (VP Enterprise)', 'Trained', 'Agreed', 2, 900000, 3,
     'Fast delivery; billing disputes twice this year.', 78.00, 'Vijay Rao:TOP_MGMT:Chief Executive Officer|Priya Menon:COMMERCIAL:VP Enterprise Sales|Karan Bhat:TECH:Solutions Architect|Lalitha Reddy:FINANCE:Head of Billing'),
    (3, 'Prime IT', '14 Nehru Place', 'primeit.example', 4100000000, 'CARE A-', 'STABLE',
     NULL, 'MANUFACTURING,RETAIL', 'ISO_9001', 'Indus Manufacturing Works, Saraswati Public Schools', 6.00,
     2, 0, 3, 30, 0, 'North India (8 cities)', 'Distributor to 200 resellers in the North.',
     'LOW', 'Volume player; little direct influence at the customer.', 'A. Gupta (Director)', 'In progress', 'Draft', 0, 0, 3,
     'Reliable stock availability.', 64.00, 'Alok Gupta:TOP_MGMT:Director|Neeraj Sethi:COMMERCIAL:Channel Manager|Ritu Malhotra:FINANCE:Accounts Head'),
    (4, 'SecureEdge MSP', '7th Floor, Olympia Tech Park, Guindy', 'secureedge.example', 650000000, NULL, 'STABLE',
     NULL, 'BFSI,IT_ITES', 'ISO_27001', 'TechPark Software Services', 12.00,
     3, 1, 5, 12, 1, 'Chennai, Coimbatore', 'Runs the SOC for three mid-size banks.',
     'MEDIUM', 'Trusted by CISOs for managed security.', 'K. Subramanian (Founder)', 'Trained', 'In discussion', 1, 450000, NULL,
     NULL, 58.00, 'K. Subramanian:TOP_MGMT:Founder & CEO|Divakar Rao:TECH:SOC Head'),
    (5, 'Zenith Consulting', 'Baner Road', 'zenithconsulting.example', 280000000, NULL, 'STABLE',
     NULL, 'HEALTHCARE,BFSI', NULL, 'Malabar Health Network', NULL,
     1, 0, 1, 6, 0, 'Pune, Kochi', 'Advises hospital boards on IT strategy; writes RFPs for them.',
     'HIGH', 'Wrote the RFP for Malabar Health; strong influencer, not a reseller.', 'Dr. N. Pillai (Principal Consultant)', 'Not started', 'Not started', 0, 0, 4,
     'Customers trust their independence.', 46.00, 'Dr. Nandini Pillai:TOP_MGMT:Principal Consultant|Rohit Joshi:TECH:Senior Consultant'),
    (6, 'Bharat GovSol', 'Scope Complex, Lodhi Road', 'bharatgovsol.example', 12500000000, 'CRISIL AA', 'STRONG',
     'SI', 'GOVT,EDUCATION', 'ISO_27001,ISO_9001,CMMI', 'Yamuna State Transport Corp, Pune Municipal Services Board, Deccan Institute of Technology', 22.00,
     8, 1, 15, 60, 1, 'Pan-India government accounts', 'Registered bidder on GeM and CPPP; knows the procurement cells.',
     'HIGH', 'Bids for us on every government tender; manages EMD and compliance.', 'S. Verma (CMD), A. Ghosh (ED Projects)', 'Trained', 'Agreed', 3, 2500000, 4,
     'Strong compliance; slow payments from the government side.', 91.00, 'Sanjay Verma:TOP_MGMT:Chairman & MD|Arpita Ghosh:COMMERCIAL:ED Projects|Nikhil Saxena:TECH:Bid Manager|Deepak Chawla:LEGAL:Legal Counsel|Pooja Bansal:FINANCE:Finance Controller');

  START TRANSACTION;

  SELECT MAX(k) INTO v_max FROM demo_ptr;
  SET i = 1;
  WHILE i <= v_max DO
    SELECT p.id, p.short_name, p.relationship_owner_user_id INTO v_pid, v_short, v_owner
      FROM partner p JOIN demo_ptr d ON d.short_name = p.short_name AND d.k = i
     WHERE p.partner_no LIKE 'PTR-%' LIMIT 1;

    IF v_pid IS NOT NULL THEN
      UPDATE partner p JOIN demo_ptr d ON d.k = i
         SET p.address = d.address, p.website = d.website,
             p.email = CONCAT('alliances@', d.website), p.registration_no = CONCAT('U72200', LPAD(i, 2, '0'), '2009PTC', 100000 + i * 7919),
             p.annual_revenue = d.revenue, p.revenue_fy = '2025-26', p.credit_rating = d.credit, p.financial_status = d.fin_status,
             p.agreement_valid_till = IF(p.agreement_status = 'SIGNED', v_today + INTERVAL (120 + i * 45) DAY, NULL),
             p.top_customers = d.top_customers, p.our_share_pct = d.share, p.sme_count = d.smes, p.can_run_poc = d.poc,
             p.certified_engineers = d.engineers, p.sales_force_size = d.sales_force, p.uses_crm = d.crm,
             p.sales_coverage = d.coverage, p.influencer_connect = d.influence, p.dmu_impact = d.dmu,
             p.dmu_impact_notes = d.dmu_notes, p.top_management = d.top_mgmt,
             p.partner_dmu = 'Decisions by the MD with the sales director; technical sign-off by pre-sales.',
             p.backup_owner_user_id = IFNULL(p.backup_owner_user_id, v_head),
             p.tech_onboarding_status = d.onboarding, p.gtm_plan_status = d.gtm,
             p.poc_investment_count = d.poc_count, p.poc_investment_value = d.poc_value,
             p.customer_feedback_rating = d.feedback, p.customer_feedback_notes = d.feedback_notes,
             p.profile_completeness_pct = d.completeness, p.updated_at = UTC_TIMESTAMP(3), p.updated_by = v_owner
       WHERE p.id = v_pid;

      -- a second partner type
      INSERT INTO partner_type_map (partner_id, partner_type_id, created_by)
      SELECT v_pid, pt.id, v_owner FROM demo_ptr d JOIN partner_type pt ON pt.code = d.extra_type
       WHERE d.k = i AND d.extra_type IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM partner_type_map m WHERE m.partner_id = v_pid AND m.partner_type_id = pt.id);

      -- industry focus and certifications
      INSERT INTO partner_industry_map (partner_id, industry_id)
      SELECT v_pid, ind.id FROM demo_ptr d JOIN industry ind ON FIND_IN_SET(ind.code, d.industries) > 0 WHERE d.k = i;
      INSERT INTO partner_certification (partner_id, certification_type_id)
      SELECT v_pid, ct.id FROM demo_ptr d JOIN certification_type ct ON FIND_IN_SET(ct.code, d.certs) > 0 WHERE d.k = i;

      -- partner code at the customers of their deals
      INSERT INTO partner_customer_code (partner_id, account_id, code)
      SELECT DISTINCT v_pid, o.account_id, CONCAT(UPPER(LEFT(REPLACE(v_short, ' ', ''), 4)), '-', LPAD(o.account_id * 7 + i, 4, '0'))
        FROM opportunity_partner op JOIN opportunity o ON o.id = op.opportunity_id
       WHERE op.partner_id = v_pid AND op.partner_role IN ('SOURCED', 'FULFILMENT')
       LIMIT 3;

      -- SPOC contacts: "name:SPOC_TYPE:designation|..."
      SELECT contacts INTO v_contacts FROM demo_ptr WHERE k = i;
      SET j = 1;
      WHILE j <= 1 + LENGTH(v_contacts) - LENGTH(REPLACE(v_contacts, '|', '')) DO
        INSERT INTO contact (partner_id, name, designation, email, spoc_type, created_by)
        SELECT v_pid,
               SUBSTRING_INDEX(SUBSTRING_INDEX(SUBSTRING_INDEX(d.contacts, '|', j), '|', -1), ':', 1),
               SUBSTRING_INDEX(SUBSTRING_INDEX(SUBSTRING_INDEX(d.contacts, '|', j), '|', -1), ':', -1),
               CONCAT(LOWER(REPLACE(REPLACE(SUBSTRING_INDEX(SUBSTRING_INDEX(SUBSTRING_INDEX(d.contacts, '|', j), '|', -1), ':', 1), 'Dr. ', ''), ' ', '.')), '@', d.website),
               SUBSTRING_INDEX(SUBSTRING_INDEX(SUBSTRING_INDEX(SUBSTRING_INDEX(d.contacts, '|', j), '|', -1), ':', 2), ':', -1),
               v_owner
          FROM demo_ptr d WHERE d.k = i;
        SET j = j + 1;
      END WHILE;

      -- engagement log, oldest first; the last one carries the next engagement plan
      SET j = 1;
      WHILE j <= 6 DO
        INSERT INTO partner_engagement (partner_id, engagement_type, engagement_on, with_whom, by_user_id, notes, outcome,
                                        next_action, next_action_on, account_id, created_by)
        VALUES (v_pid,
                ELT(j, 'MEETING', 'TRAINING', 'GTM_ACTIVITY', 'JOINT_VISIT', 'CEC_VISIT', 'QBR'),
                v_today - INTERVAL (170 - j * 28 + i) DAY,
                ELT(j, 'Sales director and pre-sales team', 'Pre-sales engineers (8)', 'Marketing team',
                       'Customer IT team with the partner account manager', 'Two customer CIOs with the partner', 'MD and sales director'),
                IF(MOD(j, 2) = 0 AND i <> 4, v_owner, IFNULL((SELECT relationship_owner_user_id FROM partner WHERE id = v_pid), v_farhan)),
                ELT(j, 'Kick-off for the half-year plan and the account mapping.',
                       'Two-day technical training on SD-WAN and firewall; 6 engineers certified.',
                       'Joint webinar for BFSI customers; 120 registrations.',
                       'Joint visit to a target account to present the reference architecture.',
                       'Hosted two customers at the experience centre; live failover demo.',
                       'Quarterly business review: pipeline, wins, payments and next-quarter plan.'),
                ELT(j, 'Agreed 6 target accounts for the half-year.', '6 engineers certified.', '14 qualified leads from the webinar.',
                       'Customer asked for a proposal.', 'One customer moved to POC.', 'Agreed the Q4 plan and two joint campaigns.'),
                IF(j = 6, 'Joint pipeline review and the Q4 campaign launch', NULL),
                IF(j = 6, v_today + INTERVAL (5 + i * 2) DAY, NULL),
                IF(j IN (4, 5), (SELECT MIN(o.account_id) FROM opportunity_partner op JOIN opportunity o ON o.id = op.opportunity_id
                                 WHERE op.partner_id = v_pid), NULL),
                v_owner);
        SET j = j + 1;
      END WHILE;
      UPDATE partner
         SET last_engagement_on = v_today - INTERVAL (170 - 6 * 28 + i) DAY,
             next_engagement_on = v_today + INTERVAL (5 + i * 2) DAY,
             next_engagement_plan = 'Joint pipeline review and the Q4 campaign launch'
       WHERE id = v_pid;

      -- 6-month account mapping
      INSERT INTO partner_account_map (partner_id, account_id, plan_period, status, notes, created_by)
      SELECT v_pid, x.account_id, CONCAT(YEAR(v_today), '-H', IF(MONTH(v_today) <= 6, 1, 2)),
             ELT(1 + MOD(x.account_id + i, 4), 'OPPORTUNITY', 'ENGAGED', 'PLANNED', 'OPPORTUNITY'),
             ELT(1 + MOD(x.account_id + i, 4), 'Deal in the pipeline.', 'Meetings held with IT.', 'Intro planned next month.', 'POC running.'),
             v_owner
        FROM (SELECT DISTINCT o.account_id FROM opportunity_partner op JOIN opportunity o ON o.id = op.opportunity_id
               WHERE op.partner_id = v_pid LIMIT 4) x;
    END IF;
    SET v_pid = NULL;
    SET i = i + 1;
  END WHILE;

  -- ---------------------------------------------------------------- tenders (UM 4.4)
  DROP TEMPORARY TABLE IF EXISTS demo_tender_deal;
  CREATE TEMPORARY TABLE demo_tender_deal (k INT AUTO_INCREMENT PRIMARY KEY, opp_id BIGINT UNSIGNED);
  INSERT INTO demo_tender_deal (opp_id)
  SELECT o.id FROM opportunity o JOIN account a ON a.id = o.account_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND o.source = 'TENDER' AND o.tender_id IS NULL
   ORDER BY o.id;

  SELECT MAX(k) INTO v_max FROM demo_tender_deal;
  SET i = 1;
  WHILE i <= IFNULL(v_max, 0) + 3 DO
    IF i <= IFNULL(v_max, 0) THEN
      SELECT o.id, o.stage_code, o.account_id, o.expected_value * o.fx_rate, op.product_id, o.owner_user_id, o.title, a.name,
             DATE(o.closed_at + INTERVAL 330 MINUTE)
        INTO v_opp, v_stage, v_acc, v_value, v_prod, v_t_owner, v_title, v_auth, v_closed
        FROM demo_tender_deal d
        JOIN opportunity o ON o.id = d.opp_id
        JOIN account a ON a.id = o.account_id
        LEFT JOIN opportunity_product op ON op.opportunity_id = o.id AND op.is_primary = 1
       WHERE d.k = i;
      SET v_status = CASE
                       WHEN v_stage IN ('QUALIFIED') THEN 'READINESS'
                       WHEN v_stage IN ('TECH_ENGAGEMENT', 'POC') THEN 'CAPTURED'
                       WHEN v_stage = 'PROPOSAL' THEN 'SUBMITTED'
                       WHEN v_stage = 'NEGOTIATION' THEN 'TECH_QUALIFIED'
                       WHEN v_stage IN ('COMMERCIAL_CLOSED', 'CONTRACT_SIGNED') THEN 'L1_L2'
                       WHEN v_stage = 'WON' THEN 'AWARDED'
                       WHEN v_stage = 'LOST' THEN 'NOT_AWARDED'
                       ELSE 'CANCELLED' END;
    ELSE
      -- newly identified tenders, no deal yet
      SET v_opp = NULL, v_stage = NULL, v_status = 'IDENTIFIED', v_closed = NULL;
      SELECT a.id, a.name, a.owner_user_id INTO v_acc, v_auth, v_t_owner
        FROM account a JOIN industry ind ON ind.id = a.industry_id
       WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND ind.code IN ('GOVT', 'EDUCATION')
       ORDER BY a.id LIMIT 1 OFFSET 0;
      IF i = IFNULL(v_max, 0) + 2 THEN
        SELECT a.id, a.name, a.owner_user_id INTO v_acc, v_auth, v_t_owner
          FROM account a JOIN industry ind ON ind.id = a.industry_id
         WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND ind.code IN ('GOVT', 'EDUCATION')
         ORDER BY a.id LIMIT 1 OFFSET 2;
      ELSEIF i = IFNULL(v_max, 0) + 3 THEN
        SELECT a.id, a.name, a.owner_user_id INTO v_acc, v_auth, v_t_owner
          FROM account a JOIN industry ind ON ind.id = a.industry_id
         WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND ind.code IN ('GOVT', 'EDUCATION')
         ORDER BY a.id LIMIT 1 OFFSET 4;
      END IF;
      SET v_prod = (SELECT id FROM product WHERE code = ELT(1 + MOD(i, 3), 'FIREWALL', 'SDWAN', 'WIFI'));
      SET v_value = ELT(1 + MOD(i, 3), 18500000, 32000000, 9600000);
      SET v_title = CONCAT(ELT(1 + MOD(i, 3), 'Supply and installation of next-generation firewalls',
                                              'SD-WAN for district offices', 'Campus-wide Wi-Fi with 5 years of support'),
                           ' - ', v_auth);
    END IF;

    -- submission date: past for submitted / closed tenders, ahead for the open ones
    SET v_sub = CASE
                  WHEN v_status IN ('IDENTIFIED') THEN v_today + INTERVAL (9 + i * 5) DAY
                  WHEN v_status IN ('READINESS', 'CAPTURED') THEN v_today + INTERVAL (4 + i * 3) DAY
                  WHEN v_status IN ('AWARDED', 'NOT_AWARDED') THEN IFNULL(v_closed, v_today) - INTERVAL 40 DAY
                  ELSE v_today - INTERVAL (8 + i * 3) DAY END;
    SET v_done = CASE v_status WHEN 'IDENTIFIED' THEN 0 WHEN 'READINESS' THEN 2 WHEN 'CAPTURED' THEN 4 ELSE 5 END;

    CALL spi_next_number('TND', 1, v_no);
    INSERT INTO tender (tender_no, reference_no, portal, authority, account_id, title, product_id, estimated_value, our_role,
                        bidder_partner_id, pre_bid_on, submission_on, opening_on, status, spec_influenced, rfp_influenced,
                        prebid_queries_filed, intelligence_notes, readiness_pct, result, l1_price, our_price, winner,
                        loss_reason_id, opportunity_id, owner_user_id, backup_owner_user_id, created_at, created_by)
    SELECT v_no,
           CONCAT(ELT(1 + MOD(i, 3), 'GEM/', 'CPPP/', 'MAHATENDERS/'), YEAR(v_today), '/B/', 4100000 + i * 3571),
           ELT(1 + MOD(i, 3), 'GeM', 'CPPP', 'State e-procurement'),
           v_auth, v_acc, v_title, v_prod, ROUND(v_value * 1.05 / 100000) * 100000, IF(MOD(i, 2) = 0, 'OEM', 'CONSORTIUM'),
           (SELECT id FROM partner WHERE short_name = 'Bharat GovSol' AND partner_no LIKE 'PTR-%' LIMIT 1),
           v_sub - INTERVAL 12 DAY, v_sub, v_sub + INTERVAL 7 DAY, v_status,
           IF(MOD(i, 3) <> 0, 1, 0), IF(MOD(i, 2) = 1, 1, 0), IF(v_status <> 'IDENTIFIED', 1, 0),
           ELT(1 + MOD(i, 3),
               'We presented the reference architecture to the technical committee before the RFP; three of our specification points made it into the tender.',
               'Pre-bid: asked to relax the turnover criterion and to allow consortium bids; both accepted in the corrigendum.',
               'Competitor is pushing a bundled switching offer; the evaluation is L1 after technical qualification.'),
           ROUND(100 * v_done / 5, 2),
           CASE v_status WHEN 'L1_L2' THEN 'L1' WHEN 'AWARDED' THEN 'L1 - awarded' WHEN 'NOT_AWARDED' THEN 'L2' ELSE NULL END,
           IF(v_status IN ('L1_L2', 'AWARDED', 'NOT_AWARDED'), ROUND(v_value * IF(v_status = 'NOT_AWARDED', 0.93, 1.0) / 10000) * 10000, NULL),
           IF(v_status IN ('L1_L2', 'AWARDED', 'NOT_AWARDED'), ROUND(v_value / 10000) * 10000, NULL),
           CASE v_status WHEN 'AWARDED' THEN 'Cnergee with Bharat GovSol'
                         WHEN 'NOT_AWARDED' THEN 'A competing system integrator (Fortinet stack)' ELSE NULL END,
           IF(v_status = 'NOT_AWARDED', (SELECT id FROM reason WHERE reason_type = 'LOSS' AND code = 'PRICE'), NULL),
           v_opp, v_t_owner, v_head,
           TIMESTAMP(v_sub - INTERVAL 45 DAY, '05:00:00'), v_t_owner;
    SET v_tid = LAST_INSERT_ID();

    -- readiness checklist (OD-40 default items)
    INSERT INTO tender_checklist_item (tender_id, item_text, is_mandatory, is_done, done_by, done_at, sort_order, created_by)
    SELECT v_tid, x.item, x.mandatory, x.seq <= v_done, IF(x.seq <= v_done, v_t_owner, NULL),
           IF(x.seq <= v_done, TIMESTAMP(v_sub - INTERVAL (20 - x.seq * 2) DAY, '07:00:00'), NULL), x.seq, v_t_owner
      FROM (SELECT 1 AS seq, 'Eligibility criteria met (turnover, similar work experience)' AS item, 1 AS mandatory
            UNION ALL SELECT 2, 'Technical compliance sheet and datasheets', 1
            UNION ALL SELECT 3, 'EMD / bid security arranged', 1
            UNION ALL SELECT 4, 'OEM authorisation letter to the bidder', 1
            UNION ALL SELECT 5, 'Partner readiness: bidder documents, MAF, local presence', 1) x;

    IF v_opp IS NOT NULL THEN
      UPDATE opportunity SET tender_id = v_tid WHERE id = v_opp;
    END IF;

    INSERT INTO activity (entity_type, entity_id, activity_type, activity_at, people_met, subject, notes, outcome, by_user_id, created_by)
    VALUES ('TENDER', v_tid, 'MEETING', TIMESTAMP(v_sub - INTERVAL 12 DAY, '06:00:00'), 'Procurement cell and the technical committee',
            'Pre-bid meeting', 'Raised 6 queries on the specification and the eligibility criteria.',
            'Corrigendum expected next week.', v_t_owner, v_t_owner);
    SET i = i + 1;
  END WHILE;

  COMMIT;

  DROP TEMPORARY TABLE IF EXISTS demo_ptr;
  DROP TEMPORARY TABLE IF EXISTS demo_tender_deal;

  SELECT (SELECT COUNT(*) FROM partner_engagement) AS engagements,
         (SELECT COUNT(*) FROM contact WHERE partner_id IS NOT NULL) AS partnerContacts,
         (SELECT COUNT(*) FROM partner_account_map) AS accountMap,
         (SELECT COUNT(*) FROM tender) AS tenders,
         (SELECT COUNT(*) FROM tender_checklist_item) AS checklistItems;
END $$

DELIMITER ;

CALL tmp_demo_partners_tenders();
DROP PROCEDURE IF EXISTS tmp_demo_partners_tenders;
