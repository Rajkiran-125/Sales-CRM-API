-- =============================================================================
-- DEMO ONLY - extra tenders                                         (2026-10-21)
--
-- NEVER run this on a live database. Adds 12 stand-alone tenders (UM 4.4) that cover
-- every status, from newly identified to awarded / lost / cancelled, so the tender list,
-- the readiness checklist and the submission-due alerts have something to show.
-- Each tender gets the 5-item readiness checklist and a pre-bid meeting activity.
-- Tenders are tied to demo government / education / healthcare accounts; no deals.
-- Dates are relative to the day you run it. Rows are inserted directly (D-26).
-- Runs once: a second run stops with "already loaded" (reference numbers start DEMO/).
--
-- Prerequisites: V001-V009, V037, `npm run seed:demo`, demo_sales_data.sql.
-- To remove them again, see the commented block at the end.
-- =============================================================================

USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS tmp_demo_tenders $$
CREATE PROCEDURE tmp_demo_tenders()
BEGIN
  DECLARE v_today  DATE;
  DECLARE v_head   BIGINT UNSIGNED;
  DECLARE v_bidder BIGINT UNSIGNED;
  DECLARE v_accs   INT;
  DECLARE v_no     VARCHAR(30);
  DECLARE v_tid    BIGINT UNSIGNED;
  DECLARE v_owner  BIGINT UNSIGNED;
  DECLARE v_status VARCHAR(14);
  DECLARE v_sub    DATE;
  DECLARE v_done   INT;
  DECLARE i        INT;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF EXISTS (SELECT 1 FROM tender WHERE reference_no LIKE 'DEMO/%') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Demo tenders are already loaded.';
  END IF;

  SET v_today = DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  SELECT id INTO v_head FROM `user` WHERE email = 'vikram.mehta@cnergee.test';
  IF v_head IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Run `npm run seed:demo` first.';
  END IF;
  SET v_bidder = (SELECT id FROM partner WHERE short_name = 'Bharat GovSol' AND partner_no LIKE 'PTR-%' LIMIT 1);

  -- demo public-sector accounts, handed out round-robin
  DROP TEMPORARY TABLE IF EXISTS demo_t_acc;
  CREATE TEMPORARY TABLE demo_t_acc (k INT AUTO_INCREMENT PRIMARY KEY, account_id BIGINT UNSIGNED, name VARCHAR(250), owner_id BIGINT UNSIGNED);
  INSERT INTO demo_t_acc (account_id, name, owner_id)
  SELECT a.id, a.name, a.owner_user_id
    FROM account a JOIN industry ind ON ind.id = a.industry_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND ind.code IN ('GOVT', 'EDUCATION', 'HEALTHCARE')
   ORDER BY a.id;
  SELECT COUNT(*) INTO v_accs FROM demo_t_acc;
  IF v_accs = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Run demo_sales_data.sql first.';
  END IF;

  -- k, title, product, value (INR), status, submission date offset (days from today), our role, portal
  DROP TEMPORARY TABLE IF EXISTS demo_t;
  CREATE TEMPORARY TABLE demo_t (
    k INT PRIMARY KEY, title VARCHAR(200), product VARCHAR(20), value DECIMAL(16,2), status VARCHAR(14),
    sub_days INT, our_role VARCHAR(10), portal VARCHAR(40)
  );
  INSERT INTO demo_t VALUES
    (1,  'Unified threat management for 40 depots',              'FIREWALL', 24000000, 'IDENTIFIED',     35,  'OEM',        'GeM'),
    (2,  'Wi-Fi 7 upgrade for hostels and libraries',            'WIFI',     11000000, 'IDENTIFIED',     42,  'CONSORTIUM', 'CPPP'),
    (3,  'SD-WAN for 120 branch offices',                        'SDWAN',    56000000, 'READINESS',      12,  'CONSORTIUM', 'State e-procurement'),
    (4,  'Endpoint protection for 3,000 seats',                  'ENDPOINT',  8500000, 'READINESS',      6,   'OEM',        'GeM'),
    (5,  'Data centre perimeter firewall refresh',               'FIREWALL', 32000000, 'CAPTURED',       3,   'CONSORTIUM', 'CPPP'),
    (6,  'Secure campus network - phase 2',                      'WIFI',     27000000, 'SUBMITTED',      -10, 'OEM',        'GeM'),
    (7,  'SD-WAN for regional offices with 5-year support',      'SDWAN',    41000000, 'SUBMITTED',      -18, 'CONSORTIUM', 'State e-procurement'),
    (8,  'Next-generation firewalls for the state data centre',  'FIREWALL', 75000000, 'TECH_QUALIFIED', -25, 'CONSORTIUM', 'CPPP'),
    (9,  'Endpoint detection and response with managed SOC',     'ENDPOINT', 19000000, 'L1_L2',          -32, 'OEM',        'GeM'),
    (10, 'Hospital-wide Wi-Fi with clinical device onboarding',  'WIFI',     14500000, 'AWARDED',        -60, 'CONSORTIUM', 'State e-procurement'),
    (11, 'SD-WAN for treasury and sub-treasury offices',         'SDWAN',    38000000, 'NOT_AWARDED',    -75, 'CONSORTIUM', 'CPPP'),
    (12, 'Firewall annual maintenance contract (3 years)',       'FIREWALL',  6000000, 'CANCELLED',      -20, 'OEM',        'GeM');

  START TRANSACTION;

  SET i = 1;
  WHILE i <= 12 DO
    SELECT t.status, v_today + INTERVAL t.sub_days DAY, IFNULL(a.owner_id, v_head)
      INTO v_status, v_sub, v_owner
      FROM demo_t t JOIN demo_t_acc a ON a.k = 1 + MOD(i - 1, v_accs)
     WHERE t.k = i;
    SET v_done = CASE v_status WHEN 'IDENTIFIED' THEN 0 WHEN 'READINESS' THEN 2 WHEN 'CAPTURED' THEN 4
                               WHEN 'CANCELLED' THEN 3 ELSE 5 END;

    CALL spi_next_number('TND', 1, v_no);
    INSERT INTO tender (tender_no, reference_no, portal, authority, account_id, title, product_id, estimated_value, our_role,
                        bidder_partner_id, pre_bid_on, submission_on, opening_on, status, spec_influenced, rfp_influenced,
                        prebid_queries_filed, intelligence_notes, readiness_pct, result, l1_price, our_price, winner,
                        loss_reason_id, owner_user_id, backup_owner_user_id, created_at, created_by)
    SELECT v_no, CONCAT('DEMO/', YEAR(v_today), '/', LPAD(i, 3, '0')), t.portal, a.name, a.account_id,
           CONCAT(t.title, ' - ', a.name), (SELECT id FROM product WHERE code = t.product), t.value, t.our_role,
           IF(t.our_role = 'OEM', NULL, v_bidder),
           v_sub - INTERVAL 12 DAY, v_sub, v_sub + INTERVAL 7 DAY, v_status,
           IF(MOD(i, 3) <> 0, 1, 0), IF(MOD(i, 2) = 1, 1, 0), IF(v_status <> 'IDENTIFIED', 1, 0),
           ELT(1 + MOD(i, 4),
               'Presented the reference architecture to the technical committee before the RFP; our sizing was adopted.',
               'Pre-bid: asked to relax the turnover criterion and to allow consortium bids; both accepted in the corrigendum.',
               'Competitor is pushing a bundled switching offer; evaluation is L1 after technical qualification.',
               'Consultant drafting the RFP is close to the CIO; specification is vendor-neutral so far.'),
           ROUND(100 * v_done / 5, 2),
           CASE v_status WHEN 'L1_L2' THEN 'L1' WHEN 'AWARDED' THEN 'L1 - awarded' WHEN 'NOT_AWARDED' THEN 'L2' ELSE NULL END,
           IF(v_status IN ('L1_L2', 'AWARDED', 'NOT_AWARDED'), ROUND(t.value * IF(v_status = 'NOT_AWARDED', 0.93, 0.96) / 10000) * 10000, NULL),
           IF(v_status IN ('L1_L2', 'AWARDED', 'NOT_AWARDED'), ROUND(t.value * 0.96 / 10000) * 10000, NULL),
           CASE v_status WHEN 'AWARDED' THEN 'Cnergee with Bharat GovSol'
                         WHEN 'NOT_AWARDED' THEN 'A competing system integrator (Fortinet stack)' ELSE NULL END,
           IF(v_status = 'NOT_AWARDED', (SELECT id FROM reason WHERE reason_type = 'LOSS' AND code = 'PRICE'), NULL),
           v_owner, v_head, TIMESTAMP(v_sub - INTERVAL 45 DAY, '05:00:00'), v_owner
      FROM demo_t t JOIN demo_t_acc a ON a.k = 1 + MOD(i - 1, v_accs)
     WHERE t.k = i;
    SET v_tid = LAST_INSERT_ID();

    -- readiness checklist (OD-40 default items)
    INSERT INTO tender_checklist_item (tender_id, item_text, is_mandatory, is_done, done_by, done_at, sort_order, created_by)
    SELECT v_tid, x.item, 1, x.seq <= v_done, IF(x.seq <= v_done, v_owner, NULL),
           IF(x.seq <= v_done, TIMESTAMP(v_sub - INTERVAL (20 - x.seq * 2) DAY, '07:00:00'), NULL), x.seq, v_owner
      FROM (SELECT 1 AS seq, 'Eligibility criteria met (turnover, similar work experience)' AS item
            UNION ALL SELECT 2, 'Technical compliance sheet and datasheets'
            UNION ALL SELECT 3, 'EMD / bid security arranged'
            UNION ALL SELECT 4, 'OEM authorisation letter to the bidder'
            UNION ALL SELECT 5, 'Partner readiness: bidder documents, MAF, local presence') x;

    -- pre-bid meeting only once it has happened
    IF v_sub - INTERVAL 12 DAY <= v_today THEN
      INSERT INTO activity (entity_type, entity_id, activity_type, activity_at, people_met, subject, notes, outcome, by_user_id, created_by)
      VALUES ('TENDER', v_tid, 'MEETING', TIMESTAMP(v_sub - INTERVAL 12 DAY, '06:00:00'), 'Procurement cell and the technical committee',
              'Pre-bid meeting', 'Raised queries on the specification and the eligibility criteria.',
              'Corrigendum expected next week.', v_owner, v_owner);
    END IF;
    SET i = i + 1;
  END WHILE;

  COMMIT;

  DROP TEMPORARY TABLE IF EXISTS demo_t;
  DROP TEMPORARY TABLE IF EXISTS demo_t_acc;

  SELECT status, COUNT(*) AS demoTenders FROM tender WHERE reference_no LIKE 'DEMO/%' GROUP BY status ORDER BY MIN(id);
END $$

DELIMITER ;

CALL tmp_demo_tenders();
DROP PROCEDURE IF EXISTS tmp_demo_tenders;

-- ---------------------------------------------------------------- remove (run by hand)
-- DELETE FROM activity WHERE entity_type = 'TENDER' AND entity_id IN (SELECT id FROM tender WHERE reference_no LIKE 'DEMO/%');
-- DELETE FROM tender_checklist_item WHERE tender_id IN (SELECT id FROM tender WHERE reference_no LIKE 'DEMO/%');
-- DELETE FROM tender WHERE reference_no LIKE 'DEMO/%';
