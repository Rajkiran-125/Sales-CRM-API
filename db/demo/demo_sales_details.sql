-- =============================================================================
-- DEMO ONLY - details behind the sales screens                     (2026-10-12)
--
-- NEVER run this on a live database. Run it after demo_sales_data.sql. It adds, for the
-- demo deals and accounts:
--   * 4 contacts per account (CIO, procurement head, network manager, finance controller)
--   * the DMU of every deal, competitors with their price, POC records, offer versions
--     (some waiting for approval), partner commercial versions
--   * 3-5 activities per deal (meetings, demos, calls, negotiation) and account visits
--   * 4-6 weeks of weekly-status history, part of this week already submitted
--   * last month's closure commitment (committed vs achieved)
--   * tasks for "My day": follow-ups (overdue / today / this week), weekly status,
--     deal validations and offer approvals for the Head of Sales, partner engagements
--   * 10 more leads in every stage (with qualification facts, DMU, products,
--     competitors; two disqualified with a reason) and activities on the leads
-- Dates are relative to the day you run it. Rows are inserted directly (D-26) and are
-- not in the audit log. Runs once: a second run stops with "already loaded".
--
-- Prerequisites: V001-V008, `npm run seed:demo`, demo_sales_data.sql.
-- =============================================================================

USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS tmp_demo_sales_details $$
CREATE PROCEDURE tmp_demo_sales_details()
BEGIN
  DECLARE v_today       DATE;
  DECLARE v_now         DATETIME(3) DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_week_start  DATE;
  DECLARE v_month_start DATE;
  DECLARE v_prev_month  DATE;
  DECLARE v_head        BIGINT UNSIGNED;
  DECLARE v_md          BIGINT UNSIGNED;
  DECLARE v_farhan      BIGINT UNSIGNED;
  DECLARE v_no          VARCHAR(30);
  DECLARE i             INT;
  DECLARE j             INT;
  DECLARE n             INT;
  DECLARE v_max         INT;
  -- per deal
  DECLARE v_id          BIGINT UNSIGNED;
  DECLARE v_opp_no      VARCHAR(20);
  DECLARE v_stage       VARCHAR(20);
  DECLARE v_seq         INT;
  DECLARE v_owner       BIGINT UNSIGNED;
  DECLARE v_presales    BIGINT UNSIGNED;
  DECLARE v_acc         BIGINT UNSIGNED;
  DECLARE v_prod        INT;
  DECLARE v_value       DECIMAL(16,2);
  DECLARE v_created     DATE;
  DECLARE v_end         DATE;
  DECLARE v_close       DATE;
  DECLARE v_partner     BIGINT UNSIGNED;
  DECLARE v_role        VARCHAR(12);
  DECLARE v_is_open     TINYINT;
  DECLARE v_health      VARCHAR(10);
  DECLARE v_c1          BIGINT UNSIGNED;
  DECLARE v_c2          BIGINT UNSIGNED;
  DECLARE v_c3          BIGINT UNSIGNED;
  DECLARE v_c4          BIGINT UNSIGNED;
  DECLARE v_c1_name     VARCHAR(150);
  DECLARE v_c2_name     VARCHAR(150);
  DECLARE v_c3_name     VARCHAR(150);
  DECLARE v_days        INT;
  DECLARE v_acts        INT;
  DECLARE v_at          DATE;
  DECLARE v_week        DATE;
  DECLARE v_lead_id     BIGINT UNSIGNED;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF EXISTS (SELECT 1 FROM task WHERE source_ref LIKE 'demo-%') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Demo sales details are already loaded.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM account WHERE notes = 'Demo data (demo_sales_data.sql)') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Run demo_sales_data.sql first.';
  END IF;

  SET v_today = DATE(v_now + INTERVAL 330 MINUTE);
  SET v_week_start = v_today - INTERVAL WEEKDAY(v_today) DAY;
  SET v_month_start = v_today - INTERVAL (DAY(v_today) - 1) DAY;
  SET v_prev_month = v_month_start - INTERVAL 1 MONTH;
  SELECT id INTO v_head FROM `user` WHERE email = 'vikram.mehta@cnergee.test';
  SELECT id INTO v_md FROM `user` WHERE email = 'arvind.kulkarni@cnergee.test';
  SELECT id INTO v_farhan FROM `user` WHERE email = 'farhan.qureshi@cnergee.test';

  -- ---------------------------------------------------------------- name lists
  DROP TEMPORARY TABLE IF EXISTS demo_first;
  CREATE TEMPORARY TABLE demo_first (k INT PRIMARY KEY, name VARCHAR(40));
  INSERT INTO demo_first VALUES
    (1,'Rajesh'),(2,'Anita'),(3,'Sunil'),(4,'Priya'),(5,'Mahesh'),(6,'Kavya'),(7,'Nitin'),(8,'Swati'),
    (9,'Prakash'),(10,'Meenakshi'),(11,'Girish'),(12,'Shalini'),(13,'Venkat'),(14,'Deepa'),(15,'Harish'),
    (16,'Rekha'),(17,'Ashok'),(18,'Neelam'),(19,'Vivek'),(20,'Sujata'),(21,'Ramesh'),(22,'Lata'),
    (23,'Sandeep'),(24,'Archana'),(25,'Manoj'),(26,'Pallavi'),(27,'Ajay'),(28,'Smita'),(29,'Kiran'),(30,'Usha');
  DROP TEMPORARY TABLE IF EXISTS demo_last;
  CREATE TEMPORARY TABLE demo_last (k INT PRIMARY KEY, name VARCHAR(40));
  INSERT INTO demo_last VALUES
    (1,'Kulkarni'),(2,'Menon'),(3,'Bhat'),(4,'Reddy'),(5,'Chatterjee'),(6,'Agarwal'),(7,'Pandey'),
    (8,'Naidu'),(9,'Shetty'),(10,'Sinha'),(11,'Ghosh'),(12,'Mishra'),(13,'Kapoor'),(14,'Saxena'),
    (15,'Hegde'),(16,'Thakur'),(17,'Dubey'),(18,'Mathur'),(19,'Banerjee'),(20,'Kamath');

  START TRANSACTION;

  -- ---------------------------------------------------------------- contacts (4 per demo account)
  DROP TEMPORARY TABLE IF EXISTS demo_acc;
  CREATE TEMPORARY TABLE demo_acc (k INT AUTO_INCREMENT PRIMARY KEY, id BIGINT UNSIGNED, domain VARCHAR(60), govt TINYINT);
  INSERT INTO demo_acc (id, domain, govt)
  SELECT a.id,
         CONCAT(LOWER(REGEXP_REPLACE(SUBSTRING_INDEX(a.name, ' ', 2), '[^A-Za-z]', '')), '.example'),
         (i.code IN ('GOVT', 'EDUCATION'))
    FROM account a LEFT JOIN industry i ON i.id = a.industry_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)'
   ORDER BY a.id;

  DROP TEMPORARY TABLE IF EXISTS demo_contact;
  CREATE TEMPORARY TABLE demo_contact (account_id BIGINT UNSIGNED, slot INT, contact_id BIGINT UNSIGNED, name VARCHAR(150),
                                       PRIMARY KEY (account_id, slot));
  SELECT MAX(k) INTO v_max FROM demo_acc;
  SET i = 1;
  WHILE i <= v_max DO
    SET j = 1;
    WHILE j <= 4 DO
      INSERT INTO contact (account_id, name, designation, department, email, seniority, influence_level, stand,
                           intel_notes, created_by)
      SELECT d.id,
             CONCAT(f.name, ' ', l.name),
             ELT(j, IF(d.govt, 'Joint Director (IT)', 'Chief Information Officer'),
                    IF(d.govt, 'Deputy Controller (Purchase)', 'Head - Procurement'),
                    'Network Manager', IF(d.govt, 'Accounts Officer', 'Finance Controller')),
             ELT(j, 'IT', 'Procurement', 'IT Infrastructure', 'Finance'),
             CONCAT(LOWER(f.name), '.', LOWER(l.name), '@', d.domain),
             ELT(j, 'CXO', 'Senior management', 'Middle management', 'Senior management'),
             ELT(j, 5, 4, 3, 3),
             ELT(j, IF(MOD(i, 3) = 0, 'NEUTRAL', 'CHAMPION'), IF(MOD(i, 4) = 0, 'BLOCKER', 'NEUTRAL'),
                    'CHAMPION', 'NEUTRAL'),
             ELT(j, 'Decides the technical shortlist; prefers a single dashboard for all sites.',
                    'Runs the commercial negotiation; very price sensitive, asks for 3 quotes.',
                    'Day-to-day owner of the network; our strongest internal supporter.',
                    'Controls the budget release; wants payment terms after go-live.'),
             (SELECT a.owner_user_id FROM account a WHERE a.id = d.id)
        FROM demo_acc d
        JOIN demo_first f ON f.k = 1 + MOD((i - 1) * 4 + j - 1, 30)
        JOIN demo_last l ON l.k = 1 + MOD(i * 3 + j * 7, 20)
       WHERE d.k = i;
      INSERT INTO demo_contact (account_id, slot, contact_id, name)
      SELECT d.id, j, LAST_INSERT_ID(), (SELECT c.name FROM contact c WHERE c.id = LAST_INSERT_ID())
        FROM demo_acc d WHERE d.k = i;
      SET j = j + 1;
    END WHILE;
    SET i = i + 1;
  END WHILE;

  -- ---------------------------------------------------------------- the demo deals
  DROP TEMPORARY TABLE IF EXISTS demo_deal;
  CREATE TEMPORARY TABLE demo_deal (
    k INT AUTO_INCREMENT PRIMARY KEY, id BIGINT UNSIGNED, opp_no VARCHAR(20), stage VARCHAR(20), seq INT,
    owner BIGINT UNSIGNED, presales BIGINT UNSIGNED, account_id BIGINT UNSIGNED, prod INT,
    value DECIMAL(16,2), created DATE, closed DATE, close_date DATE, is_open TINYINT, health VARCHAR(10),
    partner_id BIGINT UNSIGNED, partner_role VARCHAR(12)
  );
  INSERT INTO demo_deal (id, opp_no, stage, seq, owner, presales, account_id, prod, value, created, closed,
                         close_date, is_open, health, partner_id, partner_role)
  SELECT o.id, o.opportunity_no, o.stage_code, s.sequence_no, o.owner_user_id, o.presales_owner_user_id,
         o.account_id,
         (SELECT FIELD(p.code, 'SDWAN', 'FIREWALL', 'WIFI', 'ENDPOINT') FROM opportunity_product op
            JOIN product p ON p.id = op.product_id WHERE op.opportunity_id = o.id AND op.is_primary = 1 LIMIT 1),
         o.expected_value, DATE(o.created_at + INTERVAL 330 MINUTE), DATE(o.closed_at + INTERVAL 330 MINUTE),
         o.expected_close_date, s.is_open, o.health,
         (SELECT op.partner_id FROM opportunity_partner op WHERE op.opportunity_id = o.id ORDER BY op.is_primary DESC LIMIT 1),
         (SELECT op.partner_role FROM opportunity_partner op WHERE op.opportunity_id = o.id ORDER BY op.is_primary DESC LIMIT 1)
    FROM opportunity o
    JOIN account a ON a.id = o.account_id AND a.notes = 'Demo data (demo_sales_data.sql)'
    JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   ORDER BY o.id;

  SELECT MAX(k) INTO v_max FROM demo_deal;
  SET n = 1;
  WHILE n <= v_max DO
    SELECT id, opp_no, stage, seq, owner, presales, account_id, IFNULL(prod, 1), value, created,
           IFNULL(closed, v_today), close_date, is_open, health, partner_id, partner_role
      INTO v_id, v_opp_no, v_stage, v_seq, v_owner, v_presales, v_acc, v_prod, v_value, v_created,
           v_end, v_close, v_is_open, v_health, v_partner, v_role
      FROM demo_deal WHERE k = n;
    IF v_stage = 'DORMANT' THEN SET v_end = v_today - INTERVAL 20 DAY; END IF;
    SELECT contact_id, name INTO v_c1, v_c1_name FROM demo_contact WHERE account_id = v_acc AND slot = 1;
    SELECT contact_id, name INTO v_c2, v_c2_name FROM demo_contact WHERE account_id = v_acc AND slot = 2;
    SELECT contact_id, name INTO v_c3, v_c3_name FROM demo_contact WHERE account_id = v_acc AND slot = 3;
    SELECT contact_id INTO v_c4 FROM demo_contact WHERE account_id = v_acc AND slot = 4;
    SET v_days = GREATEST(DATEDIFF(v_end, v_created), 7);

    -- DMU (BR-OP-16): tech + commercial buyer always; influencer and sponsor once engaged
    INSERT INTO opportunity_dmu (opportunity_id, contact_id, dmu_role, influence_level, stand, notes, created_by)
    VALUES (v_id, v_c1, 'TECH_BUYER', 5, IF(MOD(n, 3) = 0, 'NEUTRAL', 'CHAMPION'),
            'Owns the technical evaluation and the final shortlist.', v_owner),
           (v_id, v_c2, 'COMM_BUYER', 4, IF(MOD(n, 4) = 0, 'BLOCKER', 'NEUTRAL'),
            'Wants a lower price than the incumbent; will run a reverse auction if possible.', v_owner);
    IF v_seq >= 2 THEN
      INSERT INTO opportunity_dmu (opportunity_id, contact_id, dmu_role, influence_level, stand, notes, created_by)
      VALUES (v_id, v_c3, 'INFLUENCER_INT', 3, 'CHAMPION', 'Ran our demo internally and supports the design.', v_owner),
             (v_id, v_c4, 'SPONSOR', 3, 'NEUTRAL', 'Approves the budget release; needs a phased payment plan.', v_owner);
    END IF;

    -- competition (2 of 3 deals)
    IF MOD(n, 3) <> 0 THEN
      INSERT INTO opportunity_competitor (opportunity_id, competitor_id, their_price, their_strength, our_differentiator, created_by)
      SELECT v_id, c.id, ROUND(v_value * (0.84 + MOD(n, 9) / 100) / 10000) * 10000,
             ELT(v_prod, 'Large installed base in the region and an aggressive bundle with switching.',
                         'Strong brand with the CISO; offers 3 years of subscriptions free.',
                         'Existing controllers at the site; claims no rip-and-replace.',
                         'Cheapest per-seat price; bundles email security.'),
             ELT(v_prod, 'Single console for SD-WAN and firewall, dual-ISP failover proven in the POC, local support team.',
                         'Higher IPS throughput in the POC, lower 5-year total cost, on-site engineer.',
                         'Better roaming results in the site survey and guest onboarding the customer liked.',
                         'Lower CPU overhead in the pilot and central reporting for audit.'),
             v_owner
        FROM competitor c
       WHERE c.name = ELT(v_prod, ELT(1 + MOD(n, 3), 'Cisco', 'Fortinet', 'Palo Alto Networks'),
                                  ELT(1 + MOD(n, 4), 'Fortinet', 'Palo Alto Networks', 'Check Point', 'Sophos'),
                                  ELT(1 + MOD(n, 2), 'Cisco', 'Juniper Networks'),
                                  ELT(1 + MOD(n, 2), 'Sophos', 'Palo Alto Networks'))
       LIMIT 1;
    END IF;

    -- POC (UM 4.3 stage 3) for deals that reached it
    IF (v_seq >= 3 AND v_stage NOT IN ('LOST', 'DORMANT')) OR (v_stage = 'WON' AND MOD(n, 2) = 0) THEN
      INSERT INTO opportunity_poc (opportunity_id, external_poc_ref, status, start_date, end_date, success_criteria,
                                   exit_criteria, customer_lead_contact_id, cnergee_lead_user_id, result,
                                   customer_validated, readout_date, notes, created_by)
      VALUES (v_id, CONCAT('POC-', SUBSTRING(v_opp_no, 5)),
              IF(v_stage = 'POC', 'IN_PROGRESS', 'COMPLETED'),
              v_created + INTERVAL (v_days DIV 3) DAY,
              IF(v_stage = 'POC', v_today + INTERVAL 10 DAY, v_created + INTERVAL (v_days DIV 3 + 21) DAY),
              ELT(v_prod, 'Branch failover under 5 seconds; 99.9 % uptime on the 3 pilot branches; central policy push in one click.',
                          '5 Gbps throughput with IPS on; no false positives on the core banking / ERP apps; HA failover tested.',
                          'Seamless roaming across 2 floors; 300 concurrent users; guest onboarding in under a minute.',
                          'All test samples detected; under 3 % CPU overhead; audit report from the central console.'),
              'Customer sign-off on the readout, or stop after 4 weeks if the criteria are not met.',
              v_c3, IFNULL(v_presales, v_owner),
              IF(v_stage = 'POC', NULL, 'SUCCESS'), IF(v_stage = 'POC', NULL, 1),
              IF(v_stage = 'POC', NULL, v_created + INTERVAL (v_days DIV 3 + 24) DAY),
              IF(v_stage = 'POC', 'Week 2 of 4: failover and policy tests done, performance test next.',
                                  'Readout presented to the CIO; all success criteria met.'),
              v_owner);
    END IF;

    -- offers (BR-OP-05): v1 at Proposal, v2 from Negotiation; approval above 15 % or INR 1 Cr
    IF (v_seq >= 4 AND v_stage NOT IN ('LOST', 'DORMANT')) OR v_stage = 'WON' OR (v_stage = 'LOST' AND MOD(n, 2) = 0) THEN
      INSERT INTO offer (opportunity_id, version_no, offer_no, offer_value, list_value, discount_pct, value_adds,
                         payment_terms, valid_till, status, approval_required, submitted_by, submitted_at,
                         approved_by, approved_at, sent_by, sent_at, sent_to, customer_response, customer_responded_at,
                         created_by, created_at)
      VALUES (v_id, 1, CONCAT(v_opp_no, '/v1'), ROUND(v_value * 1.06 / 10000) * 10000,
              ROUND(v_value * 1.06 / 0.95 / 10000) * 10000, 5.00,
              'Installation and 1 year of on-site support.', '30 % advance, 70 % on delivery',
              v_created + INTERVAL (v_days DIV 2 + 30) DAY,
              IF(v_seq = 4 AND v_stage <> 'WON' AND v_stage <> 'LOST', 'SENT', 'SUPERSEDED'),
              (v_value * 1.06 > 10000000), v_owner, TIMESTAMP(v_created + INTERVAL (v_days DIV 2) DAY, '06:00:00'),
              IF(v_value * 1.06 > 10000000, v_head, NULL),
              IF(v_value * 1.06 > 10000000, TIMESTAMP(v_created + INTERVAL (v_days DIV 2 + 1) DAY, '06:00:00'), NULL),
              v_owner, TIMESTAMP(v_created + INTERVAL (v_days DIV 2 + 1) DAY, '09:00:00'), v_c2_name,
              IF(v_seq = 4, NULL, 'Asked for a better price and a phased payment plan.'),
              IF(v_seq = 4, NULL, TIMESTAMP(v_created + INTERVAL (v_days DIV 2 + 8) DAY, '06:00:00')),
              v_owner, TIMESTAMP(v_created + INTERVAL (v_days DIV 2) DAY, '05:00:00'));
      IF v_seq >= 5 OR (v_stage = 'LOST' AND MOD(n, 2) = 0) THEN
        INSERT INTO offer (opportunity_id, version_no, offer_no, offer_value, list_value, discount_pct, value_adds,
                           payment_terms, valid_till, status, approval_required, submitted_by, submitted_at,
                           approved_by, approved_at, approval_remark, sent_by, sent_at, sent_to,
                           customer_response, customer_responded_at, created_by, created_at)
        VALUES (v_id, 2, CONCAT(v_opp_no, '/v2'), v_value,
                ROUND(v_value / IF(MOD(n, 4) = 0, 0.82, 0.89) / 10000) * 10000,
                IF(MOD(n, 4) = 0, 18.00, 11.00),
                'Installation, 3 years of on-site support, training for 10 engineers.',
                '20 % advance, 60 % on delivery, 20 % after go-live',
                v_today + INTERVAL (20 + MOD(n, 20)) DAY,
                CASE
                  WHEN v_stage = 'NEGOTIATION' AND MOD(n, 4) = 0 THEN 'PENDING_APPROVAL'
                  WHEN v_stage = 'NEGOTIATION' THEN 'SENT'
                  WHEN v_stage = 'LOST' THEN 'REJECTED'
                  ELSE 'ACCEPTED' END,
                (MOD(n, 4) = 0 OR v_value > 10000000), v_owner,
                TIMESTAMP(LEAST(v_end, v_today) - INTERVAL 6 DAY, '06:00:00'),
                IF(v_stage = 'NEGOTIATION' AND MOD(n, 4) = 0, NULL, IF(MOD(n, 4) = 0 OR v_value > 10000000, v_head, NULL)),
                IF(v_stage = 'NEGOTIATION' AND MOD(n, 4) = 0, NULL,
                   IF(MOD(n, 4) = 0 OR v_value > 10000000, TIMESTAMP(LEAST(v_end, v_today) - INTERVAL 5 DAY, '06:00:00'), NULL)),
                IF(MOD(n, 4) = 0 AND v_stage <> 'NEGOTIATION', 'Approved: strategic account, competitor below us by 9 %.', NULL),
                IF(v_stage = 'NEGOTIATION' AND MOD(n, 4) = 0, NULL, v_owner),
                IF(v_stage = 'NEGOTIATION' AND MOD(n, 4) = 0, NULL, TIMESTAMP(LEAST(v_end, v_today) - INTERVAL 4 DAY, '09:00:00')),
                IF(v_stage = 'NEGOTIATION' AND MOD(n, 4) = 0, NULL, v_c2_name),
                CASE WHEN v_stage = 'LOST' THEN 'Went with a lower bid.'
                     WHEN v_seq >= 6 OR v_stage = 'WON' THEN 'Accepted; PO to follow after board approval.'
                     ELSE NULL END,
                IF(v_seq >= 6 OR v_stage IN ('WON', 'LOST'), TIMESTAMP(LEAST(v_end, v_today) - INTERVAL 2 DAY, '06:00:00'), NULL),
                v_owner, TIMESTAMP(LEAST(v_end, v_today) - INTERVAL 7 DAY, '05:00:00'));
      END IF;
      -- the accepted offer sets the final value (12.5.3)
      IF v_seq >= 6 OR v_stage = 'WON' THEN
        UPDATE opportunity SET final_value = v_value WHERE id = v_id AND final_value IS NULL;
      END IF;
    END IF;

    -- partner commercial (BR-OP-13): versions never overwritten
    IF v_partner IS NOT NULL AND v_role IN ('SOURCED', 'FULFILMENT') AND (v_seq >= 4 OR v_stage = 'WON') AND v_stage <> 'DORMANT' THEN
      INSERT INTO partner_commercial (opportunity_id, partner_id, account_id, partner_role, version_no, deal_size_basis,
                                      price_to_partner, partner_margin_pct, payment_terms, pay_partner_after_customer,
                                      valid_till, remarks, created_by, created_at)
      VALUES (v_id, v_partner, v_acc, v_role, 1, CONCAT('Deal value INR ', FORMAT(v_value, 0, 'en_IN'), ' (offer v1)'),
              ROUND(v_value * 0.84 / 10000) * 10000, 12.00, '45 days after customer payment', 1,
              v_created + INTERVAL (v_days DIV 2 + 60) DAY, 'Standard partner discount for this tier.', v_owner,
              TIMESTAMP(v_created + INTERVAL (v_days DIV 2) DAY, '07:00:00'));
      IF v_seq >= 5 OR v_stage = 'WON' THEN
        INSERT INTO partner_commercial (opportunity_id, partner_id, account_id, partner_role, version_no, deal_size_basis,
                                        price_to_partner, partner_margin_pct, payment_terms, pay_partner_after_customer,
                                        valid_till, remarks, created_by, created_at)
        VALUES (v_id, v_partner, v_acc, v_role, 2, CONCAT('Deal value INR ', FORMAT(v_value, 0, 'en_IN'), ' (offer v2)'),
                ROUND(v_value * 0.86 / 10000) * 10000, 10.00, '30 days after customer payment', 1,
                v_today + INTERVAL 60 DAY, 'Margin reduced after the customer discount; partner agreed.', v_owner,
                TIMESTAMP(LEAST(v_end, v_today) - INTERVAL 6 DAY, '07:00:00'));
      END IF;
    END IF;

    -- activities (UM 6.3): from discovery to the latest stage
    SET v_acts = LEAST(2 + v_seq, 6);
    IF v_stage IN ('WON', 'LOST') THEN SET v_acts = 5; END IF;
    IF v_stage = 'DORMANT' THEN SET v_acts = 3; END IF;
    SET j = 1;
    WHILE j <= v_acts DO
      SET v_at = v_created + INTERVAL ROUND(v_days * (j - 1) / v_acts) + 1 DAY;
      IF v_at > v_today THEN SET v_at = v_today; END IF;
      INSERT INTO activity (entity_type, entity_id, opportunity_id, account_id, activity_type, activity_at,
                            people_met, subject, notes, outcome, next_action, next_action_on, next_action_owner_id,
                            by_user_id, created_by)
      VALUES ('OPP', v_id, v_id, v_acc,
              ELT(LEAST(j, 6), 'MEETING', 'DEMO', 'VISIT', 'EMAIL', 'NEGOTIATION', 'CALL'),
              TIMESTAMP(v_at, ELT(1 + MOD(j, 3), '05:00:00', '07:30:00', '10:00:00')),
              ELT(LEAST(j, 6), CONCAT(v_c1_name, ', ', v_c3_name), CONCAT(v_c1_name, ', ', v_c3_name), v_c3_name,
                               v_c2_name, CONCAT(v_c2_name, ', ', v_c1_name), v_c1_name),
              ELT(LEAST(j, 6), 'Discovery meeting with IT', 'Solution demo and architecture walk-through',
                               'Site survey at the main office', 'Proposal sent', 'Commercial negotiation',
                               'Follow-up call on the decision'),
              ELT(LEAST(j, 6),
                  ELT(v_prod, 'They run MPLS at all branches; renewal is due and the cost is rising.',
                              'Firewalls are 7 years old and out of support; the auditor flagged it.',
                              'Wi-Fi complaints from staff and guests; the new floor opens next quarter.',
                              'Mixed antivirus tools, no central view; two incidents last quarter.'),
                  'Showed the central console, failover and reporting. The network manager asked for a POC.',
                  'Mapped the sites and the cabling; shared the bill of quantities draft.',
                  'Sent the technical and commercial proposal with the BoQ and the implementation plan.',
                  'Customer asked for 15 % off and phased payments; we offered extended support instead of a deeper discount.',
                  'Customer confirmed the decision is with the CIO this month.'),
              ELT(LEAST(j, 6), 'Need confirmed; budget in this financial year.', 'Positive; POC requested.',
                               'BoQ agreed in principle.', 'Proposal under review.', 'Gap narrowed to 4 %.',
                               'Decision expected soon.'),
              IF(j = v_acts AND v_is_open = 1,
                 ELT(LEAST(v_seq, 7), 'Get the DMU confirmed and validate the deal', 'Plan the POC with the network team',
                     'Close the POC readout with the CIO', 'Follow up on the proposal', 'Close the commercial gap',
                     'Get the contract signed', 'Get the PO'), NULL),
              IF(j = v_acts AND v_is_open = 1, v_today + INTERVAL (MOD(n, 5) - 2) DAY, NULL),
              IF(j = v_acts AND v_is_open = 1, v_owner, NULL),
              IF(j IN (2, 3) AND v_presales IS NOT NULL, v_presales, v_owner),
              v_owner);
      SET j = j + 1;
    END WHILE;
    UPDATE opportunity SET last_activity_at = TIMESTAMP(v_at, '10:00:00') WHERE id = v_id;

    -- open deals entered their current stage part-way through their life, not today
    IF v_is_open = 1 THEN
      SET v_at = IF(v_seq = 1, v_created,
                    LEAST(v_today - INTERVAL 1 DAY,
                          v_created + INTERVAL GREATEST(1, ROUND(DATEDIFF(v_today, v_created) * (v_seq - 1) / 7)) DAY));
      UPDATE opportunity SET stage_entered_at = TIMESTAMP(v_at, '06:30:00') WHERE id = v_id;
      UPDATE stage_history
         SET changed_at = TIMESTAMP(v_at, '06:30:00'), days_in_previous = GREATEST(DATEDIFF(v_at, v_created), 0)
       WHERE entity_type = 'OPP' AND entity_id = v_id AND to_stage = v_stage AND from_stage IS NOT NULL;
    END IF;

    -- weekly status history (BR-FC-01): weeks 2 to 6 back, while the deal was open
    IF v_is_open = 1 THEN
      SET j = 2;
      WHILE j <= 6 DO
        SET v_week = v_week_start - INTERVAL (7 * j) DAY;
        IF v_week >= v_created - INTERVAL WEEKDAY(v_created) DAY + INTERVAL 7 DAY THEN
          INSERT INTO weekly_status (opportunity_id, week_start, status, this_week, next_step, expected_close_date,
                                     expected_value, stage_code, submitted_by, submitted_at)
          SELECT v_id, v_week, IF(j = 2 AND v_health IN ('AT_RISK', 'SLIPPED'), 'AT_RISK', 'ON_TRACK'),
                 ELT(1 + MOD(n + j, 5), 'Met the IT team; requirements confirmed.', 'Demo done; good feedback.',
                     'Shared the BoQ; waiting for comments.', 'Partner aligned on pricing.', 'POC progress review.'),
                 ELT(1 + MOD(n + j, 4), 'Fix the next meeting with the CIO.', 'Send the revised BoQ.',
                     'Plan the site survey.', 'Confirm the budget owner.'),
                 v_close, v_value, v_stage, v_owner, TIMESTAMP(v_week + INTERVAL 4 DAY, '11:00:00')
            FROM DUAL
           WHERE NOT EXISTS (SELECT 1 FROM weekly_status w WHERE w.opportunity_id = v_id AND w.week_start = v_week);
        END IF;
        SET j = j + 1;
      END WHILE;
      -- part of this week is already submitted (Monday morning updates)
      IF MOD(n, 3) = 1 AND v_created < v_week_start THEN
        INSERT INTO weekly_status (opportunity_id, week_start, status, this_week, next_step, expected_close_date,
                                   expected_value, stage_code, submitted_by, submitted_at)
        SELECT v_id, v_week_start,
               CASE v_health WHEN 'SLIPPED' THEN 'SLIPPED' WHEN 'AT_RISK' THEN 'AT_RISK' ELSE 'ON_TRACK' END,
               'Reviewed the deal with the team; next meeting fixed.', 'Meet the decision maker this week.',
               v_close, v_value, v_stage, v_owner, v_now - INTERVAL 2 HOUR
          FROM DUAL
         WHERE NOT EXISTS (SELECT 1 FROM weekly_status w WHERE w.opportunity_id = v_id AND w.week_start = v_week_start);
      END IF;
      UPDATE opportunity
         SET last_status_at = (SELECT TIMESTAMP(MAX(w.week_start) + INTERVAL 4 DAY, '11:00:00') FROM weekly_status w WHERE w.opportunity_id = v_id)
       WHERE id = v_id;
    END IF;

    -- last month's closure commitment: the deals won last month were committed
    IF v_stage = 'WON' AND v_end BETWEEN v_prev_month AND v_month_start - INTERVAL 1 DAY THEN
      INSERT INTO monthly_commit (opportunity_id, commit_month, commit_type, commit_value, committed_by, committed_at, achieved)
      SELECT v_id, v_prev_month, IF(MOD(n, 3) = 0, 'UPSIDE', 'COMMIT'), v_value, v_owner,
             TIMESTAMP(v_prev_month + INTERVAL 3 DAY, '06:30:00'), 1
        FROM DUAL
       WHERE NOT EXISTS (SELECT 1 FROM monthly_commit m WHERE m.opportunity_id = v_id AND m.commit_month = v_prev_month);
    ELSEIF v_is_open = 1 AND MOD(n, 7) = 3 THEN
      -- committed last month but slipped
      INSERT INTO monthly_commit (opportunity_id, commit_month, commit_type, commit_value, committed_by, committed_at, achieved)
      SELECT v_id, v_prev_month, 'COMMIT', v_value, v_owner, TIMESTAMP(v_prev_month + INTERVAL 3 DAY, '06:30:00'), 0
        FROM DUAL
       WHERE NOT EXISTS (SELECT 1 FROM monthly_commit m WHERE m.opportunity_id = v_id AND m.commit_month = v_prev_month);
    END IF;

    -- tasks for My day
    IF v_is_open = 1 THEN
      INSERT INTO task (entity_type, entity_id, task_type, title, description, owner_user_id, due_at, status, source_ref, created_by)
      VALUES ('OPP', v_id, 'FOLLOW_UP',
              ELT(LEAST(v_seq, 7), 'Get the DMU confirmed and validate the deal', 'Plan the POC with the network team',
                  'Close the POC readout with the CIO', 'Follow up on the proposal', 'Close the commercial gap',
                  'Get the contract signed', 'Get the PO'),
              CONCAT('Next action from the last activity on ', v_opp_no, '.'), v_owner,
              TIMESTAMP(v_today + INTERVAL (MOD(n, 5) - 2) DAY, '05:30:00'), 'OPEN', CONCAT('demo-fu-', v_id), v_owner);
      IF v_close < v_today THEN
        INSERT INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref, created_by)
        VALUES ('OPP', v_id, 'CLOSE_DATE', CONCAT('Close date passed: update ', v_opp_no), v_owner,
                TIMESTAMP(v_close + INTERVAL 1 DAY, '03:30:00'), 'OPEN', CONCAT('demo-cd-', v_id), v_owner);
      END IF;
      -- a done task from earlier, for the history
      INSERT INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, completed_at, completed_by,
                        source_ref, created_by)
      VALUES ('OPP', v_id, 'FOLLOW_UP', 'Send the meeting summary to the customer', v_owner,
              TIMESTAMP(v_created + INTERVAL 3 DAY, '05:30:00'), 'DONE', TIMESTAMP(v_created + INTERVAL 3 DAY, '09:00:00'),
              v_owner, CONCAT('demo-done-', v_id), v_owner);
    END IF;
    IF v_stage = 'QUALIFIED' AND EXISTS (SELECT 1 FROM opportunity WHERE id = v_id AND validation_status = 'PENDING') THEN
      INSERT INTO task (entity_type, entity_id, task_type, title, description, owner_user_id, due_at, status, source_ref, created_by)
      VALUES ('OPP', v_id, 'VALIDATION', CONCAT('Validate deal ', v_opp_no), 'Qualified deal waiting for validation (UM 6.2).',
              v_head, TIMESTAMP(GREATEST(v_created + INTERVAL 2 DAY, v_today - INTERVAL 1 DAY), '04:30:00'), 'OPEN',
              CONCAT('demo-val-', v_id), v_owner);
    END IF;

    SET n = n + 1;
  END WHILE;

  -- the budget range of the deals whose budget is known
  UPDATE opportunity o JOIN demo_deal d ON d.id = o.id
     SET o.budget_min = ROUND(o.expected_value * 0.85 / 100000) * 100000,
         o.budget_max = ROUND(o.expected_value * 1.10 / 100000) * 100000
   WHERE o.budget_known = 'YES' AND o.budget_min IS NULL;

  -- offer approvals for the Head of Sales
  INSERT INTO task (entity_type, entity_id, task_type, title, description, owner_user_id, due_at, status, source_ref, created_by)
  SELECT 'OFFER', f.id, 'APPROVAL', CONCAT('Approve offer ', f.offer_no),
         CONCAT('Discount ', f.discount_pct, ' % is above the 15 % limit.'), v_head,
         TIMESTAMP(v_today, '06:30:00'), 'OPEN', CONCAT('demo-appr-', f.id), f.submitted_by
    FROM offer f
    JOIN demo_deal d ON d.id = f.opportunity_id
   WHERE f.status = 'PENDING_APPROVAL';

  -- weekly status reminders, one per owner with deals still to update this week
  INSERT INTO task (task_type, title, description, owner_user_id, due_at, status, source_ref, created_by)
  SELECT 'WEEKLY_STATUS', CONCAT('Submit the weekly status (', COUNT(*), ' deals)'),
         'Due on Friday (BR-FC-01).', d.owner, TIMESTAMP(v_week_start + INTERVAL 4 DAY, '12:30:00'), 'OPEN',
         CONCAT('demo-ws-', d.owner, '-', v_week_start), d.owner
    FROM demo_deal d
   WHERE d.is_open = 1
     AND NOT EXISTS (SELECT 1 FROM weekly_status w WHERE w.opportunity_id = d.id AND w.week_start = v_week_start)
   GROUP BY d.owner;

  -- review meetings for the Head of Sales and the MD
  INSERT INTO task (task_type, title, description, owner_user_id, due_at, status, source_ref, created_by) VALUES
    ('CUSTOM', 'Monday pipeline review with the regional managers', 'Review slipped deals and this month''s commitment.',
     v_head, TIMESTAMP(v_today, '05:30:00'), 'OPEN', CONCAT('demo-rev-', v_today), v_head),
    ('CUSTOM', 'Quarterly business review with the MD', 'Q3 funnel, closures vs target, partner performance.',
     v_head, TIMESTAMP(v_today + INTERVAL 3 DAY, '08:30:00'), 'OPEN', CONCAT('demo-qbr-', v_today), v_head),
    ('CUSTOM', 'Approve the Q4 targets', 'Targets per owner for the next quarter (OD-15).',
     v_md, TIMESTAMP(v_today + INTERVAL 2 DAY, '06:30:00'), 'OPEN', CONCAT('demo-tgt-', v_today), v_md);

  -- partner engagements for the partner manager
  INSERT INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref, created_by)
  SELECT 'PARTNER', p.id, 'ENGAGEMENT', CONCAT('Quarterly review with ', p.short_name), p.relationship_owner_user_id,
         TIMESTAMP(v_today + INTERVAL (p.id MOD 6) DAY, '07:00:00'), 'OPEN', CONCAT('demo-eng-', p.id), v_farhan
    FROM partner p
   WHERE p.partner_no LIKE 'PTR-%' AND EXISTS (SELECT 1 FROM opportunity_partner op JOIN demo_deal d ON d.id = op.opportunity_id
                                               WHERE op.partner_id = p.id);

  -- account visits (relationship, not tied to a deal)
  INSERT INTO activity (entity_type, entity_id, account_id, activity_type, activity_at, people_met, subject, notes,
                        outcome, by_user_id, created_by)
  SELECT 'ACCOUNT', d.id, d.id, 'CEC_VISIT', TIMESTAMP(v_today - INTERVAL (10 + d.k * 3) DAY, '06:00:00'),
         (SELECT c.name FROM demo_contact c WHERE c.account_id = d.id AND c.slot = 1),
         'Customer experience centre visit', 'Walked the CIO through our NOC and the reference architecture.',
         'Interested in a 3-year managed services contract.', a.owner_user_id, a.owner_user_id
    FROM demo_acc d JOIN account a ON a.id = d.id
   WHERE MOD(d.k, 2) = 1;

  -- ---------------------------------------------------------------- 10 more leads
  DROP TEMPORARY TABLE IF EXISTS demo_lead;
  CREATE TEMPORARY TABLE demo_lead (
    k INT PRIMARY KEY, company VARCHAR(200), industry VARCHAR(30), city VARCHAR(100), contact VARCHAR(150),
    designation VARCHAR(100), source VARCHAR(10), owner_email VARCHAR(150), stage VARCHAR(20), facts INT,
    prod VARCHAR(20), value DECIMAL(16,2), need VARCHAR(500)
  );
  INSERT INTO demo_lead VALUES
    (1,  'Shivneri Urban Co-op Bank',     'BFSI',          'Satara',      'Mandar Gokhale',   'Head of IT',      'PARTNER',  'rohan.deshpande@cnergee.test', 'QUALIFYING',   6, 'SDWAN',    9500000,  'Wants to move 38 branches from MPLS to SD-WAN before the March audit.'),
    (2,  'Western Ghats Hospital',        'HEALTHCARE',    'Kolhapur',    'Dr. Seema Patil',  'Medical Director','REFERRAL', 'sneha.patil@cnergee.test',     'QUALIFYING',   4, 'WIFI',     3200000,  'Needs Wi-Fi for 3 new wards and a guest network for patients.'),
    (3,  'Coromandel Textiles',           'MANUFACTURING', 'Tiruppur',    'S. Balaji',        'IT Manager',      'DIRECT',   'divya.narayanan@cnergee.test', 'QUALIFYING',   3, 'FIREWALL', 2800000,  'Ransomware scare last month; asked for a firewall and endpoint quote.'),
    (4,  'Hampi Heritage Resorts',        'HOSPITALITY',   'Hospet',      'Ravi Kiran',       'GM - IT',         'EVENT',    'lakshmi.iyer@cnergee.test',    'CONTACTED',    1, 'WIFI',     1500000,  'Met at the hospitality IT summit; resort-wide Wi-Fi refresh.'),
    (5,  'Doaba Agro Industries',         'MANUFACTURING', 'Jalandhar',   'Gurpreet Sandhu',  'Head - IT',       'PARTNER',  'pooja.sharma@cnergee.test',    'CONTACTED',    2, 'SDWAN',    4200000,  'Plants in 4 districts with poor connectivity; partner introduced them.'),
    (6,  'Aravalli Institute of Science', 'EDUCATION',     'Ajmer',       'Prof. Nidhi Jain', 'Registrar',       'TENDER',   'rahul.verma@cnergee.test',     'NEW',          0, 'WIFI',     2600000,  'Campus Wi-Fi tender expected; pre-bid meeting next month.'),
    (7,  'Gomti Logistics Park',          'LOGISTICS',     'Lucknow',     'Alok Srivastava',  'CTO',             'WEBSITE',  'amandeep.singh@cnergee.test',  'NEW',          0, 'ENDPOINT', 900000,   'Filled the website form: endpoint protection for 600 devices.'),
    (8,  'Konark Infotech',               'IT_ITES',       'Bhubaneswar', 'Sasmita Das',      'IT Head',         'DIRECT',   'karthik.raman@cnergee.test',   'DISQUALIFIED', 2, 'FIREWALL', 700000,   'Asked for a firewall quote for one office.'),
    (9,  'Sabarmati Retail',              'RETAIL',        'Ahmedabad',   'Hetal Shah',       'IT Manager',      'REFERRAL', 'neha.joshi@cnergee.test',      'DISQUALIFIED', 1, 'SDWAN',    1200000,  'Looking at SD-WAN for 12 stores.'),
    (10, 'Cauvery Power Distribution',    'GOVT',          'Mysuru',      'K. Shivakumar',    'Chief Engineer (IT)', 'TENDER', 'karthik.raman@cnergee.test', 'QUALIFYING',   5, 'FIREWALL', 12500000, 'SCADA network segregation after the CERT-In advisory.');

  SET i = 1;
  WHILE i <= 10 DO
    CALL spi_next_number('LD', 1, v_no);
    INSERT INTO sales_lead (lead_no, source, partner_id, account_name_text, industry_id, contact_name, contact_designation,
                            city, need_text, rough_value, rough_timing, owner_user_id, backup_owner_user_id,
                            next_action, next_action_due_on, stage_code, stage_entered_at,
                            problem_statement, product_id, solution_id, commercial_window_value, budget_known,
                            budget_min, budget_max, procurement_type_id, procurement_steps_known, expected_close_date,
                            qualification_pct, disqualify_reason_id, disqualify_note, disqualified_at,
                            last_activity_at, created_at, created_by)
    SELECT v_no, d.source,
           IF(d.source = 'PARTNER', (SELECT MIN(p.id) FROM partner p WHERE p.partner_no LIKE 'PTR-%' AND p.tier = 'STRATEGIC'), NULL),
           d.company, ind.id, d.contact, d.designation, d.city, d.need, d.value,
           ELT(1 + MOD(i, 3), 'This quarter', 'Next quarter', 'Within 6 months'),
           u.id, u.reporting_to_user_id,
           CASE d.stage WHEN 'DISQUALIFIED' THEN 'Archived' WHEN 'NEW' THEN 'First call to understand the requirement'
                        WHEN 'CONTACTED' THEN 'Meet the IT head with the solution architect'
                        ELSE 'Complete the qualification and convert' END,
           v_today + INTERVAL (MOD(i, 6) - 1) DAY,
           d.stage, TIMESTAMP(v_today - INTERVAL (3 + i) DAY, '06:00:00'),
           IF(d.facts >= 1, d.need, NULL),
           IF(d.facts >= 2, (SELECT id FROM product WHERE code = d.prod), NULL),
           IF(d.facts >= 2, (SELECT MIN(s.id) FROM solution s JOIN product p ON p.id = s.product_id WHERE p.code = d.prod), NULL),
           IF(d.facts >= 3, d.value, NULL), IF(d.facts >= 3, 'YES', NULL),
           IF(d.facts >= 3, ROUND(d.value * 0.8 / 100000) * 100000, NULL), IF(d.facts >= 3, d.value, NULL),
           IF(d.facts >= 5, (SELECT id FROM procurement_type WHERE code = IF(d.source = 'TENDER', 'TENDER', 'RFP')), NULL),
           IF(d.facts >= 5, 1, 0),
           IF(d.facts >= 6, v_today + INTERVAL (60 + i * 7) DAY, NULL),
           ROUND(100 * d.facts / 6, 2),
           IF(d.stage = 'DISQUALIFIED', (SELECT id FROM reason WHERE reason_type = 'DISQUALIFY' AND code = IF(i = 8, 'WRONG_FIT', 'NO_BUDGET')), NULL),
           IF(d.stage = 'DISQUALIFIED', IF(i = 8, 'Single office of 20 users; below our minimum deal size.',
                                                  'Budget frozen for this year; revisit in April.'), NULL),
           IF(d.stage = 'DISQUALIFIED', TIMESTAMP(v_today - INTERVAL (5 + i) DAY, '08:00:00'), NULL),
           IF(d.stage = 'NEW', NULL, TIMESTAMP(v_today - INTERVAL (2 + i) DAY, '07:00:00')),
           TIMESTAMP(v_today - INTERVAL (8 + 2 * i) DAY, '05:00:00'), u.id
      FROM demo_lead d
      JOIN industry ind ON ind.code = d.industry
      JOIN `user` u ON u.email = d.owner_email
     WHERE d.k = i;
    SET v_lead_id = LAST_INSERT_ID();

    -- qualification details for the leads that have them
    INSERT INTO lead_product (lead_id, product_id, created_by)
    SELECT v_lead_id, p.id, l.owner_user_id FROM demo_lead d JOIN product p ON p.code = d.prod
      JOIN sales_lead l ON l.id = v_lead_id WHERE d.k = i;
    IF (SELECT facts FROM demo_lead WHERE k = i) >= 4 THEN
      INSERT INTO lead_dmu (lead_id, name, designation, dmu_role, influence_level, stand, notes, created_by)
      SELECT v_lead_id, d.contact, d.designation, 'TECH_BUYER', 5, 'CHAMPION', 'Drives the evaluation.', l.owner_user_id
        FROM demo_lead d JOIN sales_lead l ON l.id = v_lead_id WHERE d.k = i
      UNION ALL
      SELECT v_lead_id, ELT(1 + MOD(i, 3), 'Sanjeev Mehra', 'Rupa Desai', 'Anil Bose'), 'Head - Purchase', 'COMM_BUYER', 4,
             'NEUTRAL', 'Will compare at least three bids.', l.owner_user_id
        FROM sales_lead l WHERE l.id = v_lead_id
      UNION ALL
      SELECT v_lead_id, ELT(1 + MOD(i, 3), 'Vinod Kale', 'Farah Khan', 'Suresh Nair'), 'Network Administrator',
             'INFLUENCER_INT', 3, 'CHAMPION', 'Hands-on; liked the demo.', l.owner_user_id
        FROM sales_lead l WHERE l.id = v_lead_id;
      INSERT INTO lead_competitor (lead_id, competitor_id, created_by)
      SELECT v_lead_id, c.id, l.owner_user_id FROM competitor c JOIN sales_lead l ON l.id = v_lead_id
       WHERE c.name IN ('Fortinet', 'Cisco');
    END IF;

    -- lead history and activities
    INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by, changed_at)
    SELECT 'LEAD', v_lead_id, NULL, 'NEW', l.owner_user_id, l.created_at FROM sales_lead l WHERE l.id = v_lead_id;
    IF (SELECT stage FROM demo_lead WHERE k = i) <> 'NEW' THEN
      INSERT INTO activity (entity_type, entity_id, lead_id, activity_type, activity_at, people_met, subject, notes,
                            outcome, by_user_id, created_by)
      SELECT 'LEAD', v_lead_id, v_lead_id, 'CALL', l.created_at + INTERVAL 1 DAY, l.contact_name,
             'Introductory call', CONCAT('Discussed: ', l.need_text), 'Interested; asked for a meeting.',
             l.owner_user_id, l.owner_user_id
        FROM sales_lead l WHERE l.id = v_lead_id;
      INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by, changed_at, days_in_previous)
      SELECT 'LEAD', v_lead_id, 'NEW', 'CONTACTED', l.owner_user_id, l.created_at + INTERVAL 1 DAY, 1
        FROM sales_lead l WHERE l.id = v_lead_id;
    END IF;
    IF (SELECT stage FROM demo_lead WHERE k = i) IN ('QUALIFYING', 'DISQUALIFIED') THEN
      INSERT INTO activity (entity_type, entity_id, lead_id, activity_type, activity_at, people_met, subject, notes,
                            outcome, by_user_id, created_by)
      SELECT 'LEAD', v_lead_id, v_lead_id, 'MEETING', l.created_at + INTERVAL 4 DAY, l.contact_name,
             'Requirement meeting', 'Went through the sites, the users and the timeline.',
             IF(l.stage_code = 'DISQUALIFIED', 'Not a fit for now.', 'Qualification in progress.'),
             l.owner_user_id, l.owner_user_id
        FROM sales_lead l WHERE l.id = v_lead_id;
      INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by, changed_at, days_in_previous, reason)
      SELECT 'LEAD', v_lead_id, 'CONTACTED', l.stage_code, l.owner_user_id, l.created_at + INTERVAL 4 DAY, 3,
             l.disqualify_note
        FROM sales_lead l WHERE l.id = v_lead_id;
    END IF;
    -- follow-up task for every open lead (UM 6.1: next action + due date)
    INSERT INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref, created_by)
    SELECT 'LEAD', l.id, 'FOLLOW_UP', l.next_action, l.owner_user_id, TIMESTAMP(l.next_action_due_on, '05:30:00'),
           'OPEN', CONCAT('demo-lead-', l.id), l.owner_user_id
      FROM sales_lead l WHERE l.id = v_lead_id AND l.stage_code IN ('NEW', 'CONTACTED', 'QUALIFYING');
    SET i = i + 1;
  END WHILE;

  -- follow-ups for the open leads of the first demo script too
  INSERT INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref, created_by)
  SELECT 'LEAD', l.id, 'FOLLOW_UP', l.next_action, l.owner_user_id, TIMESTAMP(l.next_action_due_on, '05:30:00'),
         'OPEN', CONCAT('demo-lead-', l.id), l.owner_user_id
    FROM sales_lead l
   WHERE l.created_by = v_head AND l.stage_code IN ('NEW', 'CONTACTED', 'QUALIFYING')
     AND NOT EXISTS (SELECT 1 FROM task t WHERE t.source_ref = CONCAT('demo-lead-', l.id));

  COMMIT;

  DROP TEMPORARY TABLE IF EXISTS demo_first;
  DROP TEMPORARY TABLE IF EXISTS demo_last;
  DROP TEMPORARY TABLE IF EXISTS demo_acc;
  DROP TEMPORARY TABLE IF EXISTS demo_contact;
  DROP TEMPORARY TABLE IF EXISTS demo_deal;
  DROP TEMPORARY TABLE IF EXISTS demo_lead;

  SELECT (SELECT COUNT(*) FROM contact c JOIN account a ON a.id = c.account_id WHERE a.notes = 'Demo data (demo_sales_data.sql)') AS contacts,
         (SELECT COUNT(*) FROM activity) AS activities,
         (SELECT COUNT(*) FROM offer) AS offers,
         (SELECT COUNT(*) FROM task WHERE source_ref LIKE 'demo-%') AS tasks,
         (SELECT COUNT(*) FROM weekly_status) AS weeklyStatus,
         (SELECT COUNT(*) FROM sales_lead) AS leads;
END $$

DELIMITER ;

CALL tmp_demo_sales_details();
DROP PROCEDURE IF EXISTS tmp_demo_sales_details;
