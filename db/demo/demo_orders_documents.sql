-- =============================================================================
-- DEMO ONLY - orders, payments, documents and win / loss lessons      (2026-10-12)
--
-- NEVER run this on a live database. Run it after demo_partners_tenders.sql. It adds:
--   * an order for every won demo deal (UM 6.6, BR-OR-01): the PO-to-payment track
--     (PO received -> PO to manufacturer -> goods delivered -> deployment -> invoice
--     raised -> payment received -> closed) with dates that follow each PO
--   * invoices (80 % on installation, 20 % after go-live acceptance), customer payments
--     with their delay days (most on time, some late; one customer holding its payments, so
--     there are overdue invoices),
--     partner releases made only after the customer paid (BR-OR-05), and revenue / GM /
--     NP entered by finance on the settled orders (BR-OR-06)
--   * documents with tags (M14): customer POs, invoices, proposals (one per offer
--     version), BoQs, datasheets, POC plans and readouts, contracts, partner price
--     letters, NDAs and account plans, partner agreements and GTM plans, tender
--     compliance sheets, bid receipts and OEM authorisations, lead overviews. Files are
--     metadata only: there is nothing to download in the demo
--   * finance tasks on My day (invoices due or overdue, partner releases to make), order
--     activities, and a distinct lesson on every closed demo deal for Win / Loss analysis
-- Dates are relative to the day you run it. Rows are inserted directly (D-26).
-- Runs once: a second run stops with "already loaded".
--
-- Prerequisites: V001-V010, `npm run seed:demo`, demo_sales_data.sql,
-- demo_sales_details.sql, demo_partners_tenders.sql.
-- =============================================================================

USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- one document: the file metadata, the document and its tags (comma separated)
DROP PROCEDURE IF EXISTS tmp_demo_doc $$
CREATE PROCEDURE tmp_demo_doc(
  IN  p_entity     VARCHAR(10),
  IN  p_entity_id  BIGINT UNSIGNED,
  IN  p_lead       BIGINT UNSIGNED,
  IN  p_opp        BIGINT UNSIGNED,
  IN  p_acc        BIGINT UNSIGNED,
  IN  p_ptr        BIGINT UNSIGNED,
  IN  p_title      VARCHAR(250),
  IN  p_type       VARCHAR(40),
  IN  p_file       VARCHAR(255),
  IN  p_size       BIGINT UNSIGNED,
  IN  p_shared     VARCHAR(10),
  IN  p_shared_ptr BIGINT UNSIGNED,
  IN  p_on         DATE,
  IN  p_by         BIGINT UNSIGNED,
  IN  p_version    INT,
  IN  p_notes      VARCHAR(1000),
  IN  p_tags       VARCHAR(300),
  OUT o_id         BIGINT UNSIGNED
)
BEGIN
  DECLARE v_key  VARCHAR(100) DEFAULT CONCAT('demo-', REPLACE(UUID(), '-', ''));
  DECLARE v_file BIGINT UNSIGNED;
  DECLARE v_tags VARCHAR(300) DEFAULT IFNULL(p_tags, '');
  DECLARE v_tag  VARCHAR(60);

  INSERT INTO file_object (storage_key, original_name, mime_type, size_bytes, checksum_sha256, scan_status,
                           uploaded_by, created_at)
  VALUES (v_key, p_file,
          CASE LOWER(SUBSTRING_INDEX(p_file, '.', -1))
            WHEN 'pdf'  THEN 'application/pdf'
            WHEN 'xlsx' THEN 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
            WHEN 'docx' THEN 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
            WHEN 'pptx' THEN 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
            ELSE 'application/octet-stream' END,
          p_size, SHA2(v_key, 256), 'CLEAN', p_by, TIMESTAMP(p_on, '06:00:00'));
  SET v_file = LAST_INSERT_ID();

  INSERT INTO document (entity_type, entity_id, lead_id, opportunity_id, account_id, partner_id, file_object_id,
                        title, document_type_id, shared_with, shared_with_partner_id, shared_on, shared_by,
                        version_no, notes, created_at, created_by)
  SELECT p_entity, p_entity_id, p_lead, p_opp, p_acc, p_ptr, v_file, p_title, dt.id, p_shared,
         IF(p_shared = 'PARTNER', p_shared_ptr, NULL), IF(p_shared = 'INTERNAL', NULL, p_on),
         IF(p_shared = 'INTERNAL', NULL, p_by), p_version, p_notes, TIMESTAMP(p_on, '06:00:00'), p_by
    FROM document_type dt WHERE dt.code = p_type;
  SET o_id = LAST_INSERT_ID();

  WHILE v_tags <> '' DO
    SET v_tag = TRIM(SUBSTRING_INDEX(v_tags, ',', 1));
    SET v_tags = IF(LOCATE(',', v_tags) > 0, SUBSTRING(v_tags, LOCATE(',', v_tags) + 1), '');
    IF v_tag <> '' THEN
      INSERT IGNORE INTO document_tag (document_id, tag) VALUES (o_id, v_tag);
    END IF;
  END WHILE;
END $$

DROP PROCEDURE IF EXISTS tmp_demo_orders_documents $$
CREATE PROCEDURE tmp_demo_orders_documents()
BEGIN
  DECLARE v_today      DATE;
  DECLARE v_meera      BIGINT UNSIGNED;
  DECLARE v_suresh     BIGINT UNSIGNED;
  DECLARE v_no         VARCHAR(30);
  DECLARE i            INT;
  DECLARE j            INT;
  DECLARE n            INT;
  DECLARE v_doc        BIGINT UNSIGNED;
  -- order
  DECLARE v_order      BIGINT UNSIGNED;
  DECLARE v_opp        BIGINT UNSIGNED;
  DECLARE v_acc        BIGINT UNSIGNED;
  DECLARE v_owner      BIGINT UNSIGNED;
  DECLARE v_ptr        BIGINT UNSIGNED;
  DECLARE v_ptr_share  DECIMAL(16,2);
  DECLARE v_force_k    INT;
  DECLARE v_ptr_name   VARCHAR(150);
  DECLARE v_acc_name   VARCHAR(200);
  DECLARE v_prod       VARCHAR(30);
  DECLARE v_govt       TINYINT;
  DECLARE v_po_no      VARCHAR(60);
  DECLARE v_po_date    DATE;
  DECLARE v_po_value   DECIMAL(16,2);
  DECLARE v_mfr        DATE;
  DECLARE v_deliv      DATE;
  DECLARE v_deploy     DATE;
  DECLARE v_status     VARCHAR(16);
  DECLARE v_credit     INT;
  -- invoices and payments
  DECLARE v_inv        BIGINT UNSIGNED;
  DECLARE v_inv_no     VARCHAR(60);
  DECLARE v_inv_seq    INT DEFAULT 400;
  DECLARE v_inv_on     DATE;
  DECLARE v_due        DATE;
  DECLARE v_amt        DECIMAL(16,2);
  DECLARE v_paid       DECIMAL(16,2);
  DECLARE v_paid_on    DATE;
  DECLARE v_delay      INT;
  DECLARE v_rel        DECIMAL(16,2);
  DECLARE v_rel_on     DATE;
  DECLARE v_all_paid   TINYINT;
  DECLARE v_last_cust  DATE;
  DECLARE v_last       DATE;
  DECLARE v_rel_wait   TINYINT;
  DECLARE v_gm         DECIMAL(5,2);
  -- document plan
  DECLARE d_entity     VARCHAR(10);
  DECLARE d_entity_id  BIGINT UNSIGNED;
  DECLARE d_lead       BIGINT UNSIGNED;
  DECLARE d_opp        BIGINT UNSIGNED;
  DECLARE d_acc        BIGINT UNSIGNED;
  DECLARE d_ptr        BIGINT UNSIGNED;
  DECLARE d_title      VARCHAR(250);
  DECLARE d_type       VARCHAR(40);
  DECLARE d_file       VARCHAR(255);
  DECLARE d_size       BIGINT UNSIGNED;
  DECLARE d_shared     VARCHAR(10);
  DECLARE d_shared_ptr BIGINT UNSIGNED;
  DECLARE d_on         DATE;
  DECLARE d_by         BIGINT UNSIGNED;
  DECLARE d_version    INT;
  DECLARE d_notes      VARCHAR(1000);
  DECLARE d_tags       VARCHAR(300);
  DECLARE d_offer      BIGINT UNSIGNED;
  DECLARE d_pc         BIGINT UNSIGNED;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF EXISTS (SELECT 1 FROM sales_order so JOIN account a ON a.id = so.account_id
              WHERE a.notes = 'Demo data (demo_sales_data.sql)') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Demo orders and documents are already loaded.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM partner_engagement pe JOIN partner p ON p.id = pe.partner_id
                  WHERE p.relationship_owner_user_id IN (SELECT id FROM `user` WHERE email LIKE '%@cnergee.test')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Run demo_partners_tenders.sql first.';
  END IF;

  SET v_today = DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);
  SELECT id INTO v_meera FROM `user` WHERE email = 'meera.nair@cnergee.test';
  SELECT id INTO v_suresh FROM `user` WHERE email = 'suresh.pillai@cnergee.test';
  IF v_meera IS NULL OR v_suresh IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The demo finance users are missing: run npm run seed:demo first.';
  END IF;

  -- the won demo deals, oldest PO first
  DROP TEMPORARY TABLE IF EXISTS demo_won;
  CREATE TEMPORARY TABLE demo_won (
    k INT AUTO_INCREMENT PRIMARY KEY, opp_id BIGINT UNSIGNED, acc_id BIGINT UNSIGNED, acc_name VARCHAR(200),
    owner_id BIGINT UNSIGNED, po_no VARCHAR(60), po_date DATE, po_value DECIMAL(16,2), ptr_id BIGINT UNSIGNED NULL,
    ptr_name VARCHAR(150) NULL, ptr_share DECIMAL(16,2) NULL, industry VARCHAR(30), prod VARCHAR(30)
  );
  INSERT INTO demo_won (opp_id, acc_id, acc_name, owner_id, po_no, po_date, po_value, ptr_id, industry, prod)
  SELECT o.id, o.account_id, a.name, o.owner_user_id, o.po_number, o.po_date, o.po_value,
         (SELECT op.partner_id FROM opportunity_partner op
           WHERE op.opportunity_id = o.id AND op.partner_role IN ('SOURCED', 'FULFILMENT')
           ORDER BY op.is_primary DESC, op.id LIMIT 1),
         ind.code,
         (SELECT pr.code FROM opportunity_product op JOIN product pr ON pr.id = op.product_id
           WHERE op.opportunity_id = o.id ORDER BY op.is_primary DESC LIMIT 1)
    FROM opportunity o
    JOIN account a ON a.id = o.account_id
    LEFT JOIN industry ind ON ind.id = a.industry_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND o.stage_code = 'WON' AND o.po_date IS NOT NULL
   ORDER BY o.po_date, o.id;
  -- the partner's share of the PO: its margin in the latest partner commercial (10 % if none)
  UPDATE demo_won d
     SET d.ptr_name = (SELECT COALESCE(p.short_name, p.legal_name) FROM partner p WHERE p.id = d.ptr_id),
         d.ptr_share = ROUND(d.po_value * IFNULL((SELECT pc.partner_margin_pct FROM partner_commercial pc
                                                   WHERE pc.opportunity_id = d.opp_id AND pc.partner_id = d.ptr_id
                                                   ORDER BY pc.version_no DESC LIMIT 1), 10) / 100, 2)
   WHERE d.ptr_id IS NOT NULL;
  -- the latest order whose first invoice fell due in the last 60 days (same dates as the loop
  -- below): its customer is holding the payments, so there is always an overdue invoice
  SELECT MAX(k) INTO v_force_k
    FROM demo_won
   WHERE po_date + INTERVAL (ELT(1 + MOD(k, 4), 3, 2, 4, 9) + 12 + MOD(k * 3, 9) + 7 + MOD(k * 5, 8) + 2 + MOD(k * 7, 6)
                             + IF(industry IN ('GOVT', 'EDUCATION'), 45, 30)) DAY
         BETWEEN v_today - INTERVAL 60 DAY AND v_today - INTERVAL 1 DAY;

  START TRANSACTION;

  -- ---------------------------------------------------------------- orders (UM 6.6)
  SELECT COUNT(*) INTO n FROM demo_won;
  SET i = 1;
  WHILE i <= n DO
    SELECT opp_id, acc_id, acc_name, owner_id, po_no, po_date, po_value, ptr_id, ptr_name, ptr_share, prod,
           industry IN ('GOVT', 'EDUCATION')
      INTO v_opp, v_acc, v_acc_name, v_owner, v_po_no, v_po_date, v_po_value, v_ptr, v_ptr_name, v_ptr_share, v_prod,
           v_govt
      FROM demo_won WHERE k = i;

    SET v_credit = IF(v_govt = 1, 45, 30);
    -- the OEM order waits for the advance or the site survey on some deals
    SET v_mfr = v_po_date + INTERVAL ELT(1 + MOD(i, 4), 3, 2, 4, 9) DAY;
    SET v_deliv = v_mfr + INTERVAL (12 + MOD(i * 3, 9)) DAY;
    SET v_deploy = v_deliv + INTERVAL (7 + MOD(i * 5, 8)) DAY;

    CALL spi_next_number('ORD', 1, v_no);
    INSERT INTO sales_order (order_no, opportunity_id, account_id, fulfilment_partner_id, po_number, po_date, po_value,
                             billing_to, payment_terms, pay_partner_after_customer, status, created_at, created_by)
    VALUES (v_no, v_opp, v_acc, v_ptr, v_po_no, v_po_date, v_po_value, 'CUSTOMER',
            CONCAT('80 % on installation, 20 % after go-live acceptance; ', v_credit, ' days from the invoice date'),
            v_ptr IS NOT NULL, 'PO_RECEIVED', TIMESTAMP(v_po_date, '06:00:00'), v_owner);
    SET v_order = LAST_INSERT_ID();
    SET v_status = 'PO_RECEIVED';

    -- the customer PO is the first document of the order
    CALL tmp_demo_doc('ORDER', v_order, NULL, v_opp, v_acc, NULL, CONCAT('Customer purchase order ', v_po_no),
                      'PURCHASE_ORDER', CONCAT(REPLACE(v_po_no, '/', '-'), '.pdf'), 240000 + MOD(i * 7919, 300000),
                      'INTERNAL', NULL, v_po_date, v_owner, 1,
                      CONCAT('PO value INR ', FORMAT(v_po_value, 0, 'en_IN'), ', signed by the customer purchase head.'),
                      CONCAT('po,', LOWER(v_prod)), v_doc);
    UPDATE sales_order SET po_document_id = v_doc WHERE id = v_order;
    INSERT INTO order_event (order_id, status, event_date, by_user_id, remark, document_id, created_at)
    VALUES (v_order, 'PO_RECEIVED', v_po_date, v_owner,
            CONCAT('Customer PO ', v_po_no, ' received for INR ', FORMAT(v_po_value, 0, 'en_IN'), '.'), v_doc,
            TIMESTAMP(v_po_date, '06:30:00'));

    INSERT INTO activity (entity_type, entity_id, opportunity_id, account_id, activity_type, activity_at, people_met,
                          subject, notes, outcome, by_user_id, created_by)
    VALUES ('ORDER', v_order, v_opp, v_acc, 'MEETING', TIMESTAMP(LEAST(v_po_date + INTERVAL 1 DAY, v_today), '05:30:00'),
            'IT head, project manager and the site engineers', 'Order kick-off with the customer',
            'Walked through the delivery schedule, site readiness, the acceptance test and the invoicing milestones.',
            'Site readiness confirmed for all locations; acceptance test plan agreed.', v_owner, v_owner);

    IF v_mfr <= v_today THEN
      INSERT INTO order_event (order_id, status, event_date, by_user_id, remark, created_at)
      VALUES (v_order, 'PO_TO_MFR', v_mfr, v_owner,
              'Back-to-back PO placed on the OEM; delivery committed within 2 weeks.', TIMESTAMP(v_mfr, '07:00:00'));
      SET v_status = 'PO_TO_MFR';
    ELSE
      SET v_mfr = NULL;
    END IF;
    IF v_mfr IS NOT NULL AND v_deliv <= v_today THEN
      INSERT INTO order_event (order_id, status, event_date, by_user_id, remark, created_at)
      VALUES (v_order, 'GOODS_DELIVERED', v_deliv, v_owner,
              'All line items delivered to site; delivery challan signed by the customer IT team.',
              TIMESTAMP(v_deliv, '08:00:00'));
      INSERT INTO activity (entity_type, entity_id, opportunity_id, account_id, activity_type, activity_at, people_met,
                            subject, notes, outcome, by_user_id, created_by)
      VALUES ('ORDER', v_order, v_opp, v_acc, 'CALL', TIMESTAMP(v_deliv + INTERVAL 1 DAY, '06:00:00'), 'Customer IT head',
              'Delivery confirmation', 'Confirmed receipt of every line item and the serial numbers against the PO.',
              'No damages or shortages; installation slot booked.', v_owner, v_owner);
      SET v_status = 'GOODS_DELIVERED';
    ELSE
      SET v_deliv = NULL;
    END IF;
    IF v_deliv IS NOT NULL AND v_deploy <= v_today THEN
      INSERT INTO order_event (order_id, status, event_date, by_user_id, remark, created_at)
      VALUES (v_order, 'DEPLOYED', v_deploy, v_owner,
              'Installation and configuration complete; acceptance test passed at all sites.',
              TIMESTAMP(v_deploy, '09:00:00'));
      SET v_status = 'DEPLOYED';
    ELSE
      SET v_deploy = NULL;
    END IF;
    UPDATE sales_order
       SET po_to_mfr_on = v_mfr, delivered_on = v_deliv, deployed_on = v_deploy,
           deployment_reference = IF(v_deploy IS NULL, NULL,
                                     CONCAT('IMP-', YEAR(v_deploy), '-', LPAD(40 + i, 4, '0'), ' (implementation tracker)'))
     WHERE id = v_order;

    -- invoices: 80 % on installation, 20 % after go-live acceptance
    SET v_all_paid = 1;
    SET v_last_cust = NULL;
    SET v_last = NULL;
    SET v_rel_wait = 0;
    SET j = 1;
    WHILE j <= 2 DO
      SET v_inv_on = IF(v_deploy IS NULL, NULL,
                        IF(j = 1, v_deploy + INTERVAL (2 + MOD(i * 7, 6)) DAY, v_deploy + INTERVAL (21 + MOD(i, 5)) DAY));
      IF v_inv_on IS NOT NULL AND v_inv_on <= v_today THEN
        SET v_amt = IF(j = 1, ROUND(v_po_value * 0.8, 2), v_po_value - ROUND(v_po_value * 0.8, 2));
        SET v_due = v_inv_on + INTERVAL v_credit DAY;
        SET v_inv_seq = v_inv_seq + 1;
        SET v_inv_no = CONCAT('CN/', MOD(YEAR(v_inv_on) - (MONTH(v_inv_on) < 4), 100), '-',
                              MOD(YEAR(v_inv_on) - (MONTH(v_inv_on) < 4) + 1, 100), '/', LPAD(v_inv_seq, 4, '0'));
        INSERT INTO invoice (order_id, invoice_no, invoice_date, due_date, amount, status, created_at, created_by)
        VALUES (v_order, v_inv_no, v_inv_on, v_due, v_amt, 'OPEN', TIMESTAMP(v_inv_on, '07:00:00'), v_meera);
        SET v_inv = LAST_INSERT_ID();
        CALL tmp_demo_doc('ORDER', v_order, NULL, v_opp, v_acc, NULL, CONCAT('Tax invoice ', v_inv_no),
                          'INVOICE', CONCAT('Invoice_', REPLACE(v_inv_no, '/', '-'), '.pdf'),
                          140000 + MOD(v_inv_seq * 7919, 80000), 'CUSTOMER', NULL, v_inv_on, v_meera, 1,
                          IF(j = 1, 'Supply and installation (80 %).', 'Go-live acceptance (20 %).'),
                          'invoice', v_doc);
        UPDATE invoice SET document_id = v_doc WHERE id = v_inv;
        IF j = 1 THEN
          UPDATE sales_order SET first_invoice_on = v_inv_on, order_to_book_days = DATEDIFF(v_inv_on, v_po_date)
           WHERE id = v_order;
          INSERT INTO order_event (order_id, status, event_date, by_user_id, remark, document_id, created_at)
          VALUES (v_order, 'INVOICED', v_inv_on, v_meera,
                  CONCAT('Invoice ', v_inv_no, ' raised for 80 % on installation.'), v_doc,
                  TIMESTAMP(v_inv_on, '07:30:00'));
          SET v_status = 'INVOICED';
        END IF;

        -- the customer pays: on time or a few days late, part-paid (orders 3, 9); nothing yet on
        -- the order picked above
        SET v_delay = IF(j = 1, ELT(1 + MOD(i, 6), -3, 0, 9, 16, 2, 4), ELT(1 + MOD(i + 2, 6), 0, -2, 5, 11, 0, 20));
        SET v_paid_on = IF(i = v_force_k, v_today + INTERVAL 1 DAY, v_due + INTERVAL v_delay DAY);
        IF v_paid_on <= v_today THEN
          SET v_paid = IF(j = 2 AND MOD(i, 6) = 3, ROUND(v_amt / 2, 2), v_amt);
          INSERT INTO payment (order_id, invoice_id, direction, amount, paid_on, reference, delay_days, remarks,
                               created_at, created_by)
          VALUES (v_order, v_inv, 'RECEIVED', v_paid, v_paid_on,
                  CONCAT(ELT(1 + MOD(i, 4), 'HDFC', 'ICIC', 'SBIN', 'UTIB'), 'R5', DATE_FORMAT(v_paid_on, '%Y%m%d'),
                         LPAD(MOD(v_inv_seq * 104729, 100000000), 8, '0')),
                  GREATEST(0, DATEDIFF(v_paid_on, v_due)),
                  CASE WHEN v_paid < v_amt THEN 'Customer held back 50 % until the punch-list items are closed.'
                       WHEN v_delay > 7 THEN 'Paid late: the invoice waited for the CFO approval.'
                       ELSE NULL END,
                  TIMESTAMP(v_paid_on, '08:00:00'), v_suresh);
          UPDATE invoice SET paid_amount = v_paid, status = IF(v_paid < v_amt, 'PART_PAID', 'PAID'),
                             updated_at = TIMESTAMP(v_paid_on, '08:00:00'), updated_by = v_suresh
           WHERE id = v_inv;
          IF v_paid < v_amt THEN SET v_all_paid = 0; END IF;
          SET v_last_cust = v_paid_on;
          SET v_last = GREATEST(IFNULL(v_last, v_paid_on), v_paid_on);

          -- the partner share is released only after the customer has paid (BR-OR-05)
          IF v_ptr IS NOT NULL THEN
            SET v_rel = ROUND(v_paid * v_ptr_share / v_po_value, 2);
            SET v_rel_on = v_paid_on + INTERVAL (7 + MOD(i, 4)) DAY;
            IF v_rel_on <= v_today THEN
              INSERT INTO payment (order_id, invoice_id, direction, partner_id, amount, paid_on, reference, remarks,
                                   created_at, created_by)
              VALUES (v_order, v_inv, 'RELEASED', v_ptr, v_rel, v_rel_on,
                      CONCAT('NEFT/', DATE_FORMAT(v_rel_on, '%y%m%d'), '/', LPAD(MOD(v_inv_seq * 7919, 1000000), 6, '0')),
                      CONCAT('Partner share released after the customer payment against ', v_inv_no, '.'),
                      TIMESTAMP(v_rel_on, '09:00:00'), v_meera);
              SET v_last = GREATEST(v_last, v_rel_on);
            ELSE
              SET v_rel_wait = 1;
            END IF;
          END IF;
        ELSE
          SET v_all_paid = 0;
          IF v_due < v_today THEN
            UPDATE invoice SET status = 'OVERDUE' WHERE id = v_inv;
            IF NOT EXISTS (SELECT 1 FROM activity WHERE entity_type = 'ORDER' AND entity_id = v_order
                                                      AND subject LIKE 'Payment follow-up%') THEN
              INSERT INTO activity (entity_type, entity_id, opportunity_id, account_id, activity_type, activity_at,
                                    people_met, subject, notes, outcome, next_action, next_action_on,
                                    next_action_owner_id, by_user_id, created_by)
              VALUES ('ORDER', v_order, v_opp, v_acc, 'CALL', TIMESTAMP(v_today - INTERVAL 3 DAY, '06:00:00'),
                      'Accounts payable team', CONCAT('Payment follow-up on ', v_inv_no),
                      'Invoice is with the customer CFO for approval; the cheque run is fortnightly.',
                      'Promised the release in the next payment run.', 'Escalate to the customer CFO if not paid',
                      v_today + INTERVAL 4 DAY, v_owner, v_meera, v_meera);
            END IF;
          END IF;
        END IF;
      ELSE
        SET v_all_paid = 0;
      END IF;
      SET j = j + 1;
    END WHILE;

    IF v_all_paid = 1 AND v_last_cust IS NOT NULL THEN
      INSERT INTO order_event (order_id, status, event_date, by_user_id, remark, created_at)
      VALUES (v_order, 'PAID', v_last_cust, v_suresh, 'Full payment received from the customer.',
              TIMESTAMP(v_last_cust, '10:00:00'));
      SET v_status = 'PAID';
      IF v_rel_wait = 0 AND v_last + INTERVAL 15 DAY <= v_today THEN
        INSERT INTO order_event (order_id, status, event_date, by_user_id, remark, created_at)
        VALUES (v_order, 'CLOSED', v_last + INTERVAL 15 DAY, v_meera,
                IF(v_ptr IS NULL, 'Order closed: delivered, invoiced and paid.',
                   CONCAT('Order closed: delivered, invoiced, paid and ', v_ptr_name, ' settled.')),
                TIMESTAMP(v_last + INTERVAL 15 DAY, '10:00:00'));
        SET v_status = 'CLOSED';
      END IF;
    END IF;

    -- finance enters revenue / GM / NP once the order is settled (BR-OR-06)
    SET v_gm = CASE v_prod WHEN 'SDWAN' THEN 31.50 WHEN 'FIREWALL' THEN 27.00 WHEN 'WIFI' THEN 24.50 ELSE 36.00 END
             + MOD(i, 4) - 1.5;
    UPDATE sales_order so
       SET so.status = v_status,
           so.invoiced_value = (SELECT IFNULL(SUM(x.amount), 0) FROM invoice x WHERE x.order_id = v_order),
           so.received_value = (SELECT IFNULL(SUM(p.amount), 0) FROM payment p
                                 WHERE p.order_id = v_order AND p.direction = 'RECEIVED'),
           so.released_to_partner_value = (SELECT IFNULL(SUM(p.amount), 0) FROM payment p
                                            WHERE p.order_id = v_order AND p.direction = 'RELEASED'),
           so.revenue = IF(v_status IN ('PAID', 'CLOSED') OR (v_status = 'INVOICED' AND MOD(i, 2) = 0), v_po_value, NULL),
           so.gross_margin_pct = IF(v_status IN ('PAID', 'CLOSED') OR (v_status = 'INVOICED' AND MOD(i, 2) = 0), v_gm, NULL),
           so.net_profit_pct = IF(v_status IN ('PAID', 'CLOSED'), v_gm - 13.5 - MOD(i, 3), NULL),
           so.revenue_recognised_on = IF(v_status IN ('PAID', 'CLOSED') OR (v_status = 'INVOICED' AND MOD(i, 2) = 0),
                                         so.first_invoice_on, NULL),
           so.updated_at = UTC_TIMESTAMP(3), so.updated_by = v_meera
     WHERE so.id = v_order;

    -- a customer payment came in and the partner share is still to be released
    IF v_rel_wait = 1 THEN
      INSERT INTO task (entity_type, entity_id, task_type, title, description, owner_user_id, due_at, status,
                        source_ref, created_by)
      VALUES ('ORDER', v_order, 'FOLLOW_UP', CONCAT('Release partner payment: ', v_ptr_name, ' on ', v_no),
              'The customer has paid; release the partner share as per the partner commercial.', v_meera,
              TIMESTAMP(v_today + INTERVAL 2 DAY, '04:30:00'), 'OPEN', CONCAT('demo-rel-', v_order), v_meera);
    END IF;
    SET i = i + 1;
  END WHILE;

  -- ---------------------------------------------------------------- finance tasks on My day
  INSERT INTO task (entity_type, entity_id, task_type, title, description, owner_user_id, due_at, status, source_ref,
                    created_by)
  SELECT 'INVOICE', x.id, 'INVOICE_DUE', CONCAT('Collect payment: ', x.invoice_no, ' · ', a.name),
         CONCAT('Outstanding INR ', FORMAT(x.amount - x.paid_amount, 0, 'en_IN'), ' on order ', so.order_no,
                ', due ', DATE_FORMAT(x.due_date, '%d %b %Y'), '.'),
         v_meera, TIMESTAMP(x.due_date, '04:30:00'), 'OPEN', CONCAT('demo-inv-', x.id), v_meera
    FROM invoice x
    JOIN sales_order so ON so.id = x.order_id
    JOIN account a ON a.id = so.account_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND x.status <> 'PAID'
     AND x.due_date <= v_today + INTERVAL 10 DAY;

  -- the deal owner helps finance: one call per order with overdue invoices
  INSERT INTO task (entity_type, entity_id, task_type, title, description, owner_user_id, due_at, status, source_ref,
                    created_by)
  SELECT 'ORDER', so.id, 'FOLLOW_UP', CONCAT('Overdue payment on ', so.order_no, ': call the customer sponsor'),
         'Finance has followed up twice; a call from the account owner usually releases the payment.',
         o.owner_user_id, TIMESTAMP(v_today + INTERVAL 1 DAY, '04:30:00'), 'OPEN', CONCAT('demo-od-', so.id), v_meera
    FROM sales_order so
    JOIN opportunity o ON o.id = so.opportunity_id
    JOIN account a ON a.id = so.account_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)'
     AND EXISTS (SELECT 1 FROM invoice x WHERE x.order_id = so.id AND x.status = 'OVERDUE');

  -- ---------------------------------------------------------------- documents (M14)
  DROP TEMPORARY TABLE IF EXISTS demo_doc_plan;
  CREATE TEMPORARY TABLE demo_doc_plan (
    k INT AUTO_INCREMENT PRIMARY KEY, entity VARCHAR(10), entity_id BIGINT UNSIGNED, lead_id BIGINT UNSIGNED NULL,
    opp_id BIGINT UNSIGNED NULL, acc_id BIGINT UNSIGNED NULL, ptr_id BIGINT UNSIGNED NULL, title VARCHAR(250),
    type_code VARCHAR(40), file_name VARCHAR(255), size_bytes BIGINT UNSIGNED, shared VARCHAR(10),
    shared_ptr BIGINT UNSIGNED NULL, on_date DATE, by_id BIGINT UNSIGNED, version_no INT, notes VARCHAR(1000) NULL,
    tags VARCHAR(300), offer_id BIGINT UNSIGNED NULL, pc_id BIGINT UNSIGNED NULL
  );

  -- proposals: one per offer version sent to the customer
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date,
                             by_id, version_no, notes, tags, offer_id)
  SELECT 'OPP', o.id, o.id, o.account_id, CONCAT('Commercial proposal ', f.offer_no, ' - ', o.title), 'PROPOSAL',
         CONCAT('Proposal_', REPLACE(f.offer_no, '/', '_'), '.pdf'), 850000 + MOD(f.id * 7919, 900000), 'CUSTOMER',
         DATE(f.sent_at + INTERVAL 330 MINUTE), f.sent_by, f.version_no,
         CONCAT('Offer INR ', FORMAT(f.offer_value, 0, 'en_IN'), ', discount ', f.discount_pct, ' %; ', f.value_adds),
         CONCAT('proposal,', LOWER(pr.code), IF(f.status = 'ACCEPTED', ',final', '')), f.id
    FROM offer f
    JOIN opportunity o ON o.id = f.opportunity_id
    JOIN account a ON a.id = o.account_id
    JOIN opportunity_product op ON op.opportunity_id = o.id AND op.is_primary = 1
    JOIN product pr ON pr.id = op.product_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND f.sent_at IS NOT NULL AND f.sent_by IS NOT NULL;

  -- BoQ for deals from the proposal stage on: shared with the partner when one prices it
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, ptr_id, title, type_code, file_name, size_bytes, shared,
                             shared_ptr, on_date, by_id, version_no, tags)
  SELECT 'OPP', o.id, o.id, o.account_id, x.ptr, CONCAT('Bill of quantities - ', o.title), 'BOQ',
         CONCAT('BoQ_', o.opportunity_no, '.xlsx'), 42000 + MOD(o.id * 7919, 90000),
         IF(x.ptr IS NULL, 'CUSTOMER', 'PARTNER'), x.ptr,
         LEAST(v_today, COALESCE((SELECT DATE(MIN(f.submitted_at) + INTERVAL 330 MINUTE) - INTERVAL 2 DAY
                                    FROM offer f WHERE f.opportunity_id = o.id),
                                 DATE(o.stage_entered_at + INTERVAL 330 MINUTE))),
         IFNULL(o.presales_owner_user_id, o.owner_user_id), 1, CONCAT('boq,', LOWER(pr.code))
    FROM opportunity o
    JOIN account a ON a.id = o.account_id
    JOIN opportunity_product op ON op.opportunity_id = o.id AND op.is_primary = 1
    JOIN product pr ON pr.id = op.product_id
    JOIN (SELECT o2.id, (SELECT opp.partner_id FROM opportunity_partner opp
                          WHERE opp.opportunity_id = o2.id AND opp.partner_role IN ('SOURCED', 'FULFILMENT')
                          ORDER BY opp.is_primary DESC LIMIT 1) AS ptr
            FROM opportunity o2) x ON x.id = o.id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)'
     AND o.stage_code IN ('PROPOSAL', 'NEGOTIATION', 'COMMERCIAL_CLOSED', 'CONTRACT_SIGNED', 'WON');

  -- datasheets sent during the technical engagement and the POC
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date,
                             by_id, version_no, tags)
  SELECT 'OPP', o.id, o.id, o.account_id, CONCAT(pr.name, ' datasheet and reference architecture'), 'DATASHEET',
         CONCAT(REPLACE(pr.name, ' ', '_'), '_Datasheet.pdf'), 1200000 + MOD(pr.id * 7919, 400000), 'CUSTOMER',
         LEAST(v_today, DATE(o.created_at + INTERVAL 330 MINUTE) + INTERVAL 6 DAY),
         IFNULL(o.presales_owner_user_id, o.owner_user_id), 1, CONCAT('datasheet,', LOWER(pr.code))
    FROM opportunity o
    JOIN account a ON a.id = o.account_id
    JOIN opportunity_product op ON op.opportunity_id = o.id AND op.is_primary = 1
    JOIN product pr ON pr.id = op.product_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND o.stage_code IN ('TECH_ENGAGEMENT', 'POC');

  -- POC plan and readout
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date,
                             by_id, version_no, notes, tags)
  SELECT 'OPP', o.id, o.id, o.account_id, CONCAT('POC plan and success criteria - ', o.title), 'POC_PLAN',
         CONCAT('POC_Plan_', o.opportunity_no, '.docx'), 180000 + MOD(pc.id * 7919, 60000), 'CUSTOMER',
         LEAST(v_today, IFNULL(pc.start_date - INTERVAL 3 DAY, v_today)),
         IFNULL(pc.cnergee_lead_user_id, o.owner_user_id), 1, pc.success_criteria, CONCAT('poc,', LOWER(pr.code))
    FROM opportunity_poc pc
    JOIN opportunity o ON o.id = pc.opportunity_id
    JOIN account a ON a.id = o.account_id
    JOIN opportunity_product op ON op.opportunity_id = o.id AND op.is_primary = 1
    JOIN product pr ON pr.id = op.product_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND pc.skipped = 0;
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date,
                             by_id, version_no, notes, tags)
  SELECT 'OPP', o.id, o.id, o.account_id, CONCAT('POC readout - ', o.title), 'POC_READOUT',
         CONCAT('POC_Readout_', o.opportunity_no, '.pptx'), 2400000 + MOD(pc.id * 7919, 900000), 'CUSTOMER',
         LEAST(v_today, pc.readout_date), IFNULL(pc.cnergee_lead_user_id, o.owner_user_id), 1,
         IF(pc.customer_validated = 1, 'Signed off by the customer: every success criterion met.',
            'Readout shared; customer sign-off pending.'),
         CONCAT('poc,readout,', LOWER(pr.code))
    FROM opportunity_poc pc
    JOIN opportunity o ON o.id = pc.opportunity_id
    JOIN account a ON a.id = o.account_id
    JOIN opportunity_product op ON op.opportunity_id = o.id AND op.is_primary = 1
    JOIN product pr ON pr.id = op.product_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND pc.readout_date IS NOT NULL;

  -- signed contracts
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date,
                             by_id, version_no, tags)
  SELECT 'OPP', o.id, o.id, o.account_id, CONCAT('Signed contract - ', o.title), 'CONTRACT',
         CONCAT('Contract_', o.opportunity_no, '_signed.pdf'), 650000 + MOD(o.id * 7919, 300000), 'CUSTOMER',
         LEAST(v_today, IF(o.stage_code = 'WON', DATE(o.closed_at + INTERVAL 330 MINUTE) - INTERVAL 4 DAY,
                           DATE(o.stage_entered_at + INTERVAL 330 MINUTE))),
         o.owner_user_id, 1, 'contract,signed'
    FROM opportunity o
    JOIN account a ON a.id = o.account_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND o.stage_code IN ('CONTRACT_SIGNED', 'WON');

  -- partner price letters: one per partner commercial version (BR-OP-13)
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, ptr_id, title, type_code, file_name, size_bytes, shared,
                             shared_ptr, on_date, by_id, version_no, notes, tags, pc_id)
  SELECT 'OPP', o.id, o.id, o.account_id, pc.partner_id,
         CONCAT('Partner price letter - ', COALESCE(p.short_name, p.legal_name), ' - ', o.title), 'PRICE_LETTER',
         CONCAT('PriceLetter_', o.opportunity_no, '_v', pc.version_no, '.pdf'), 120000 + MOD(pc.id * 7919, 50000),
         'PARTNER', pc.partner_id, LEAST(v_today, DATE(pc.created_at + INTERVAL 330 MINUTE)), pc.created_by,
         pc.version_no,
         CONCAT('Price to partner INR ', FORMAT(pc.price_to_partner, 0, 'en_IN'), ', partner margin ',
                pc.partner_margin_pct, ' %; ', pc.payment_terms, '.'),
         CONCAT('price-letter,', LOWER(REPLACE(COALESCE(p.short_name, p.legal_name), ' ', '-'))), pc.id
    FROM partner_commercial pc
    JOIN opportunity o ON o.id = pc.opportunity_id
    JOIN account a ON a.id = o.account_id
    JOIN partner p ON p.id = pc.partner_id
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND o.stage_code NOT IN ('LOST', 'DORMANT');

  -- accounts: NDA with every strategic account, an internal account plan
  INSERT INTO demo_doc_plan (entity, entity_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date, by_id,
                             version_no, tags)
  SELECT 'ACCOUNT', a.id, a.id, CONCAT('Mutual NDA - ', a.name), 'NDA',
         CONCAT('NDA_', REPLACE(a.name, ' ', '_'), '.pdf'), 310000 + MOD(a.id * 7919, 60000), 'CUSTOMER',
         LEAST(v_today, IFNULL((SELECT MIN(DATE(o.created_at + INTERVAL 330 MINUTE)) FROM opportunity o
                                 WHERE o.account_id = a.id), v_today) - INTERVAL 6 DAY),
         a.owner_user_id, 1, 'nda,legal'
    FROM account a
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND a.is_strategic = 1;
  INSERT INTO demo_doc_plan (entity, entity_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date, by_id,
                             version_no, notes, tags)
  SELECT 'ACCOUNT', a.id, a.id, CONCAT('Account plan FY 26-27 - ', a.name), 'OTHER',
         CONCAT('AccountPlan_', REPLACE(a.name, ' ', '_'), '.pptx'), 3100000 + MOD(a.id * 7919, 500000), 'INTERNAL',
         v_today - INTERVAL (20 + MOD(a.id, 15)) DAY, a.owner_user_id, 2,
         'White space by product, the DMU map and the next two quarters of pipeline.', 'account-plan,strategic'
    FROM account a
   WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND a.is_strategic = 1;

  -- partners: agreement, joint GTM plan; a draft agreement for the one still in negotiation
  INSERT INTO demo_doc_plan (entity, entity_id, ptr_id, title, type_code, file_name, size_bytes, shared, shared_ptr,
                             on_date, by_id, version_no, notes, tags)
  SELECT 'PARTNER', p.id, p.id,
         IF(p.agreement_status = 'SIGNED', CONCAT('Partner agreement 2026-2028 - ', p.legal_name),
            CONCAT('Draft partner agreement - ', p.legal_name)),
         'AGREEMENT',
         CONCAT(IF(p.agreement_status = 'SIGNED', 'Agreement_', 'Agreement_DRAFT_'),
                REPLACE(COALESCE(p.short_name, p.legal_name), ' ', '_'), '.', IF(p.agreement_status = 'SIGNED', 'pdf', 'docx')),
         520000 + MOD(p.id * 7919, 200000), 'PARTNER', p.id,
         v_today - INTERVAL IF(p.agreement_status = 'SIGNED', 120 + MOD(p.id * 37, 200), 9) DAY,
         p.relationship_owner_user_id, IF(p.agreement_status = 'SIGNED', 1, 2),
         IF(p.agreement_status = 'SIGNED', 'Countersigned; covers deal registration, margins and the support SLA.',
            'Comments awaited from the partner on the exclusivity clause.'),
         IF(p.agreement_status = 'SIGNED', 'agreement,legal', 'agreement,draft')
    FROM partner p
   WHERE p.relationship_owner_user_id IN (SELECT id FROM `user` WHERE email LIKE '%@cnergee.test');
  INSERT INTO demo_doc_plan (entity, entity_id, ptr_id, title, type_code, file_name, size_bytes, shared, shared_ptr,
                             on_date, by_id, version_no, notes, tags)
  SELECT 'PARTNER', p.id, p.id, CONCAT('Joint GTM plan H2 FY 26-27 - ', COALESCE(p.short_name, p.legal_name)),
         'GTM_PLAN', CONCAT('GTM_Plan_H2_', REPLACE(COALESCE(p.short_name, p.legal_name), ' ', '_'), '.pptx'),
         2800000 + MOD(p.id * 7919, 600000), 'PARTNER', p.id, v_today - INTERVAL (15 + MOD(p.id * 7, 20)) DAY,
         p.relationship_owner_user_id, 1,
         'Target accounts, joint events, the enablement plan and the quarterly pipeline goal.', 'gtm,plan'
    FROM partner p
   WHERE p.relationship_owner_user_id IN (SELECT id FROM `user` WHERE email LIKE '%@cnergee.test')
     AND p.tier IN ('STRATEGIC', 'GROWTH');

  -- tenders: compliance sheet, OEM authorisation to the bidder, bid submission receipt
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, title, type_code, file_name, size_bytes, shared,
                             shared_ptr, on_date, by_id, version_no, tags)
  SELECT 'TENDER', t.id, t.opportunity_id, t.account_id, CONCAT('Technical compliance sheet - ', t.title), 'COMPLIANCE',
         CONCAT('Compliance_', t.tender_no, '.xlsx'), 95000 + MOD(t.id * 7919, 60000),
         IF(t.bidder_partner_id IS NULL, 'INTERNAL', 'PARTNER'), t.bidder_partner_id,
         LEAST(v_today, IFNULL(t.submission_on, v_today) - INTERVAL 10 DAY), t.owner_user_id, 1,
         'tender,compliance,govt'
    FROM tender t
   WHERE t.owner_user_id IN (SELECT id FROM `user` WHERE email LIKE '%@cnergee.test');
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, ptr_id, title, type_code, file_name, size_bytes, shared,
                             shared_ptr, on_date, by_id, version_no, tags)
  SELECT 'TENDER', t.id, t.opportunity_id, t.account_id, t.bidder_partner_id,
         CONCAT('OEM authorisation (MAF) to ', COALESCE(p.short_name, p.legal_name), ' - ', t.tender_no), 'OTHER',
         CONCAT('MAF_', t.tender_no, '.pdf'), 90000 + MOD(t.id * 7919, 30000), 'PARTNER', t.bidder_partner_id,
         LEAST(v_today, IFNULL(t.submission_on, v_today) - INTERVAL 6 DAY), t.owner_user_id, 1, 'tender,maf'
    FROM tender t
    JOIN partner p ON p.id = t.bidder_partner_id
   WHERE t.owner_user_id IN (SELECT id FROM `user` WHERE email LIKE '%@cnergee.test')
     AND t.status NOT IN ('IDENTIFIED', 'CANCELLED');
  INSERT INTO demo_doc_plan (entity, entity_id, opp_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date,
                             by_id, version_no, notes, tags)
  SELECT 'TENDER', t.id, t.opportunity_id, t.account_id,
         CONCAT('Bid submission receipt - ', IFNULL(t.reference_no, t.tender_no)), 'OTHER',
         CONCAT('BidReceipt_', t.tender_no, '.pdf'), 60000 + MOD(t.id * 7919, 20000), 'INTERNAL',
         LEAST(v_today, t.submission_on), t.owner_user_id, 1,
         CONCAT('Submitted on ', IFNULL(t.portal, 'the portal'), ' before the deadline.'), 'tender,submission'
    FROM tender t
   WHERE t.owner_user_id IN (SELECT id FROM `user` WHERE email LIKE '%@cnergee.test')
     AND t.status IN ('SUBMITTED', 'TECH_QUALIFIED', 'L1_L2', 'AWARDED', 'NOT_AWARDED') AND t.submission_on <= v_today;

  -- leads: the solution overview sent while qualifying
  INSERT INTO demo_doc_plan (entity, entity_id, lead_id, acc_id, title, type_code, file_name, size_bytes, shared, on_date,
                             by_id, version_no, tags)
  SELECT 'LEAD', l.id, l.id, l.account_id,
         CONCAT('Solution overview - ', IFNULL(pr.name, 'Cnergee portfolio'), ' for ', COALESCE(a.name, l.account_name_text)),
         'DATASHEET', CONCAT('Overview_', l.lead_no, '.pdf'), 900000 + MOD(l.id * 7919, 300000), 'CUSTOMER',
         LEAST(v_today, DATE(l.created_at + INTERVAL 330 MINUTE) + INTERVAL 3 DAY), l.owner_user_id, 1,
         CONCAT('overview', IF(pr.code IS NULL, '', CONCAT(',', LOWER(pr.code))))
    FROM sales_lead l
    LEFT JOIN account a ON a.id = l.account_id
    LEFT JOIN product pr ON pr.id = l.product_id
   WHERE l.owner_user_id IN (SELECT id FROM `user` WHERE email LIKE '%@cnergee.test')
     AND l.stage_code IN ('CONTACTED', 'QUALIFYING');

  -- walk the plan by key: AUTO_INCREMENT leaves gaps between the INSERT ... SELECT batches
  SET i = (SELECT MIN(k) FROM demo_doc_plan);
  WHILE i IS NOT NULL DO
    SELECT entity, entity_id, lead_id, opp_id, acc_id, ptr_id, title, type_code, file_name, size_bytes, shared,
           shared_ptr, on_date, by_id, version_no, notes, tags, offer_id, pc_id
      INTO d_entity, d_entity_id, d_lead, d_opp, d_acc, d_ptr, d_title, d_type, d_file, d_size, d_shared,
           d_shared_ptr, d_on, d_by, d_version, d_notes, d_tags, d_offer, d_pc
      FROM demo_doc_plan WHERE k = i;
    CALL tmp_demo_doc(d_entity, d_entity_id, d_lead, d_opp, d_acc, d_ptr, d_title, d_type, d_file, d_size, d_shared,
                      d_shared_ptr, d_on, d_by, d_version, d_notes, d_tags, v_doc);
    IF d_offer IS NOT NULL THEN UPDATE offer SET document_id = v_doc WHERE id = d_offer; END IF;
    IF d_pc IS NOT NULL THEN UPDATE partner_commercial SET document_id = v_doc WHERE id = d_pc; END IF;
    SET i = (SELECT MIN(k) FROM demo_doc_plan WHERE k > i);
  END WHILE;

  -- ---------------------------------------------------------------- win / loss lessons (M13)
  UPDATE win_loss wl
    JOIN (SELECT o.id, ROW_NUMBER() OVER (ORDER BY o.closed_at, o.id) AS rn
            FROM opportunity o JOIN account a ON a.id = o.account_id
           WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND o.stage_code = 'WON') x ON x.id = wl.opportunity_id
     SET wl.lesson = ELT(1 + MOD(x.rn - 1, 12),
           'A three-branch POC on the customer''s own traffic removed every doubt about failover.',
           'Bringing the partner''s local engineers to the first meeting built trust with the IT head.',
           'A reference visit to a similar customer settled the technical evaluation.',
           'Meeting the CFO before the RFP let us shape a phased payment plan in our favour.',
           'Mapping the full DMU early meant no surprises at the purchase committee.',
           'A clear migration plan from the incumbent vendor reduced the perceived risk.',
           'Bundling 3 years of support made us better value than a lower upfront price.',
           'Fast, complete answers to the pre-bid queries made us the most compliant bidder.',
           'A joint account plan with the partner kept follow-ups weekly and on time.',
           'Showing the central console to the CISO turned an influencer into a champion.',
           'Holding the price but adding engineer training avoided a discount war.',
           'Committing a delivery date the OEM had confirmed in writing won over procurement.'),
         wl.detail = ELT(1 + MOD(x.rn - 1, 4),
           'Ranked first in the technical evaluation; our price was within 3 % of the lowest.',
           'The customer chose us after the POC readout and a reference call.',
           'The partner relationship and on-site support coverage decided it.',
           'Lowest total cost over 3 years once support and training were included.');
  UPDATE win_loss wl
    JOIN (SELECT o.id, ROW_NUMBER() OVER (ORDER BY o.closed_at, o.id) AS rn
            FROM opportunity o JOIN account a ON a.id = o.account_id
           WHERE a.notes = 'Demo data (demo_sales_data.sql)' AND o.stage_code = 'LOST') x ON x.id = wl.opportunity_id
     SET wl.lesson = ELT(1 + MOD(x.rn - 1, 8),
           'We met the commercial buyer too late; price became the only criterion.',
           'The incumbent offered a free hardware refresh; we should have proposed a trade-in.',
           'The budget was never confirmed in writing; qualify the budget before the POC.',
           'We quoted 6 weeks for delivery against a 3-week need; check OEM stock before quoting.',
           'There was no single sponsor, so the evaluation stalled without a decision owner.',
           'The competitor bundled managed services; offer a partner-led managed option next time.',
           'We missed the pre-bid meeting and the specification favoured another vendor.',
           'The partner was engaged too late to influence the IT head.');

  COMMIT;

  DROP TEMPORARY TABLE IF EXISTS demo_won;
  DROP TEMPORARY TABLE IF EXISTS demo_doc_plan;

  SELECT (SELECT COUNT(*) FROM sales_order) AS orders,
         (SELECT COUNT(*) FROM order_event) AS orderEvents,
         (SELECT COUNT(*) FROM invoice) AS invoices,
         (SELECT COUNT(*) FROM invoice WHERE status = 'OVERDUE') AS overdueInvoices,
         (SELECT COUNT(*) FROM payment WHERE direction = 'RECEIVED') AS customerPayments,
         (SELECT COUNT(*) FROM payment WHERE direction = 'RELEASED') AS partnerReleases,
         (SELECT COUNT(*) FROM document) AS documents,
         (SELECT COUNT(*) FROM document_tag) AS documentTags,
         (SELECT COUNT(*) FROM task WHERE source_ref LIKE 'demo-inv-%' OR source_ref LIKE 'demo-rel-%'
                                       OR source_ref LIKE 'demo-od-%') AS financeTasks;
END $$

DELIMITER ;

CALL tmp_demo_orders_documents();
DROP PROCEDURE IF EXISTS tmp_demo_orders_documents;
DROP PROCEDURE IF EXISTS tmp_demo_doc;
