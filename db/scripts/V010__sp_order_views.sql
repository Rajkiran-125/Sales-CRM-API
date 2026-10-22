-- =============================================================================
-- V010  Sales CRM - orders, win / loss analysis, documents and reports, read side
--       (M10, M13, M14, M16)                                         (2026-10-12)
--
--   Orders (list with the money figures; order workspace with the PO-to-payment track,
--   invoices, customer payments and partner releases with the release rule), Win / Loss
--   analysis (reasons, competitors, win reasons, lessons, monthly trend), Documents
--   (search over the documents of every visible record) and two reports that have no screen
--   of their own: Product mix and Revenue & GM. Read-only (decision D-27).
--
--   Scope (10.8): an order is visible with its deal (Finance, MODULE_LIMITED on ORDERS,
--   sees every deal that has an order, V008); a document with its parent record (rule 3).
--   Money is DECIMAL(18,2) in INR (OD-27, OD-51).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V009.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- =============================================================================
-- ORDERS (M10)
-- =============================================================================

-- spi_visible_orders: tmp_vis_order = orders of the user's visible deals
DROP PROCEDURE IF EXISTS spi_visible_orders $$
CREATE PROCEDURE spi_visible_orders(IN p_user_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all TINYINT;

  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_order;
  CREATE TEMPORARY TABLE tmp_vis_order (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_vis_order (id)
  SELECT so.id FROM sales_order so JOIN tmp_dash_opp t ON t.id = so.opportunity_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

-- sp_order_list: rows, { total }, counts per status, money totals
DROP PROCEDURE IF EXISTS sp_order_list $$
CREATE PROCEDURE sp_order_list(
  IN p_user_id BIGINT UNSIGNED,
  IN p_search  VARCHAR(100),
  IN p_status  VARCHAR(16),
  IN p_sort    VARCHAR(30),
  IN p_offset  INT,
  IN p_limit   INT
)
  SQL SECURITY DEFINER
  COMMENT 'Orders of the visible deals (12.9)'
BEGIN
  DECLARE v_search VARCHAR(100);
  DECLARE v_like   VARCHAR(310);
  DECLARE v_today  DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  CALL spi_like(p_search, v_search, v_like);
  CALL spi_visible_orders(p_user_id);

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  CREATE TEMPORARY TABLE tmp_list (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_list (id)
  SELECT so.id FROM sales_order so
    JOIN tmp_vis_order v ON v.id = so.id
    JOIN opportunity o ON o.id = so.opportunity_id
    JOIN account a ON a.id = so.account_id
   WHERE v_search IS NULL OR so.order_no LIKE v_like OR so.po_number LIKE v_like OR a.name LIKE v_like
      OR o.opportunity_no LIKE v_like OR o.title LIKE v_like;

  SELECT so.id, so.order_no AS orderNo, so.opportunity_id AS opportunityId, o.opportunity_no AS opportunityNo,
         o.title, so.account_id AS accountId, a.name AS accountName,
         COALESCE(fp.short_name, fp.legal_name) AS partnerName, so.po_number AS poNumber, so.po_date AS poDate,
         CAST(so.po_value AS DECIMAL(18,2)) AS poValue, so.status, st.name AS statusName,
         CAST(so.invoiced_value AS DECIMAL(18,2)) AS invoicedValue,
         CAST(so.received_value AS DECIMAL(18,2)) AS receivedValue,
         CAST(so.invoiced_value - so.received_value AS DECIMAL(18,2)) AS outstanding,
         CAST(so.released_to_partner_value AS DECIMAL(18,2)) AS releasedToPartner,
         so.order_to_book_days AS orderToBookDays, CAST(so.revenue AS DECIMAL(18,2)) AS revenue,
         so.gross_margin_pct AS gmPct, u.full_name AS ownerName,
         (SELECT COUNT(*) FROM invoice i WHERE i.order_id = so.id AND i.status <> 'PAID' AND i.due_date < v_today) AS overdueInvoices
    FROM sales_order so
    JOIN tmp_list l ON l.id = so.id
    JOIN opportunity o ON o.id = so.opportunity_id
    JOIN account a ON a.id = so.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN partner fp ON fp.id = so.fulfilment_partner_id
    LEFT JOIN stage st ON st.entity = 'ORDER' AND st.code = so.status
   WHERE p_status IS NULL OR so.status = p_status
   ORDER BY
     CASE WHEN p_sort = '-poValue'     THEN so.po_value END DESC,
     CASE WHEN p_sort = 'poValue'      THEN so.po_value END ASC,
     CASE WHEN p_sort = '-outstanding' THEN so.invoiced_value - so.received_value END DESC,
     CASE WHEN p_sort = 'outstanding'  THEN so.invoiced_value - so.received_value END ASC,
     CASE WHEN p_sort = 'poDate'       THEN so.po_date END ASC,
     so.po_date DESC, so.id DESC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total FROM sales_order so JOIN tmp_list l ON l.id = so.id
   WHERE p_status IS NULL OR so.status = p_status;

  SELECT st.code AS status, st.name AS statusName, CAST(COUNT(x.id) AS SIGNED) AS count
    FROM stage st
    LEFT JOIN (SELECT so.id, so.status FROM sales_order so JOIN tmp_list l ON l.id = so.id) x ON x.status = st.code
   WHERE st.entity = 'ORDER'
   GROUP BY st.code, st.name, st.sequence_no
   ORDER BY st.sequence_no;

  SELECT CAST(COUNT(*) AS SIGNED) AS orders,
         CAST(IFNULL(SUM(so.po_value), 0) AS DECIMAL(18,2)) AS poValue,
         CAST(IFNULL(SUM(so.invoiced_value), 0) AS DECIMAL(18,2)) AS invoiced,
         CAST(IFNULL(SUM(so.received_value), 0) AS DECIMAL(18,2)) AS received,
         CAST(IFNULL(SUM(so.invoiced_value - so.received_value), 0) AS DECIMAL(18,2)) AS outstanding,
         CAST(IFNULL(SUM(so.released_to_partner_value), 0) AS DECIMAL(18,2)) AS released,
         ROUND(AVG(so.order_to_book_days), 1) AS avgOrderToBookDays
    FROM sales_order so JOIN tmp_list l ON l.id = so.id;

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_order;
END $$

-- sp_order_get: the order workspace (UM 6.6). Result sets:
--   order, track (stages), events, invoices, payments, partnerRelease, activities
DROP PROCEDURE IF EXISTS sp_order_get $$
CREATE PROCEDURE sp_order_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Order workspace, read side (12.9)'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;
  DECLARE v_today   DATE DEFAULT DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE);

  CALL spi_visible_orders(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_order WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_order;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Order not found.', 'id');
  END IF;

  SELECT so.id, so.order_no AS orderNo, so.opportunity_id AS opportunityId, o.opportunity_no AS opportunityNo,
         o.title, so.account_id AS accountId, a.name AS accountName,
         so.fulfilment_partner_id AS partnerId, COALESCE(fp.short_name, fp.legal_name) AS partnerName,
         so.po_number AS poNumber, so.po_date AS poDate, CAST(so.po_value AS DECIMAL(18,2)) AS poValue,
         so.billing_to AS billingTo, so.payment_terms AS paymentTerms,
         so.pay_partner_after_customer AS payPartnerAfterCustomer, so.status, st.name AS statusName,
         so.po_to_mfr_on AS poToMfrOn, so.delivered_on AS deliveredOn, so.deployed_on AS deployedOn,
         so.deployment_reference AS deploymentReference, so.first_invoice_on AS firstInvoiceOn,
         so.order_to_book_days AS orderToBookDays,
         CAST(so.invoiced_value AS DECIMAL(18,2)) AS invoicedValue,
         CAST(so.received_value AS DECIMAL(18,2)) AS receivedValue,
         CAST(so.invoiced_value - so.received_value AS DECIMAL(18,2)) AS outstanding,
         CAST(so.released_to_partner_value AS DECIMAL(18,2)) AS releasedToPartner,
         CAST(so.revenue AS DECIMAL(18,2)) AS revenue, so.gross_margin_pct AS gmPct, so.net_profit_pct AS npPct,
         so.revenue_recognised_on AS revenueRecognisedOn, u.full_name AS ownerName, so.created_at AS createdAt
    FROM sales_order so
    JOIN opportunity o ON o.id = so.opportunity_id
    JOIN account a ON a.id = so.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN partner fp ON fp.id = so.fulfilment_partner_id
    LEFT JOIN stage st ON st.entity = 'ORDER' AND st.code = so.status
   WHERE so.id = p_id;

  SELECT code, name, sequence_no AS sequenceNo FROM stage WHERE entity = 'ORDER' AND is_active = 1 ORDER BY sequence_no;

  SELECT e.id, e.status, st.name AS statusName, e.event_date AS eventDate, u.full_name AS byName, e.remark
    FROM order_event e
    JOIN `user` u ON u.id = e.by_user_id
    LEFT JOIN stage st ON st.entity = 'ORDER' AND st.code = e.status
   WHERE e.order_id = p_id
   ORDER BY e.event_date, st.sequence_no;

  SELECT i.id, i.invoice_no AS invoiceNo, i.invoice_date AS invoiceDate, i.due_date AS dueDate,
         CAST(i.amount AS DECIMAL(18,2)) AS amount, CAST(i.paid_amount AS DECIMAL(18,2)) AS paidAmount,
         IF(i.status <> 'PAID' AND i.due_date < v_today, 'OVERDUE', i.status) AS status,
         (SELECT MAX(p.paid_on) FROM payment p WHERE p.invoice_id = i.id AND p.direction = 'RECEIVED') AS paidOn,
         (SELECT MAX(p.delay_days) FROM payment p WHERE p.invoice_id = i.id AND p.direction = 'RECEIVED') AS delayDays
    FROM invoice i WHERE i.order_id = p_id ORDER BY i.invoice_date, i.id;

  SELECT p.id, p.direction, p.invoice_id AS invoiceId, i.invoice_no AS invoiceNo,
         COALESCE(pt.short_name, pt.legal_name) AS partnerName, CAST(p.amount AS DECIMAL(18,2)) AS amount,
         p.paid_on AS paidOn, p.reference, p.delay_days AS delayDays, p.remarks
    FROM payment p
    LEFT JOIN invoice i ON i.id = p.invoice_id
    LEFT JOIN partner pt ON pt.id = p.partner_id
   WHERE p.order_id = p_id
   ORDER BY p.paid_on, p.id;

  -- the partner payment release rule (BR-OR-05): with "pay the partner only after the customer
  -- pays", the total released cannot exceed what the customer has paid; the latest partner
  -- commercial (BR-OP-13) for reference
  SELECT so.pay_partner_after_customer AS payAfterCustomer,
         CAST(so.received_value AS DECIMAL(18,2)) AS customerReceived,
         CAST(so.released_to_partner_value AS DECIMAL(18,2)) AS released,
         (so.pay_partner_after_customer = 0 OR so.released_to_partner_value <= so.received_value) AS withinRule,
         CAST(pc.price_to_partner AS DECIMAL(18,2)) AS partnerPrice, pc.partner_margin_pct AS partnerMarginPct,
         pc.payment_terms AS partnerPaymentTerms, pc.version_no AS commercialVersion
    FROM sales_order so
    LEFT JOIN partner_commercial pc
           ON pc.opportunity_id = so.opportunity_id AND pc.partner_id = so.fulfilment_partner_id
          AND pc.version_no = (SELECT MAX(x.version_no) FROM partner_commercial x
                                WHERE x.opportunity_id = so.opportunity_id AND x.partner_id = so.fulfilment_partner_id)
   WHERE so.id = p_id AND so.fulfilment_partner_id IS NOT NULL;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject, ac.notes,
         ac.outcome, ac.people_met AS peopleMet, u.full_name AS byName
    FROM activity ac JOIN `user` u ON u.id = ac.by_user_id
   WHERE ac.is_active = 1 AND ac.entity_type = 'ORDER' AND ac.entity_id = p_id
   ORDER BY ac.activity_at DESC;
END $$

-- =============================================================================
-- WIN / LOSS ANALYSIS (M13)
-- =============================================================================

-- spi_winloss_closed: tmp_closed = the visible deals won or lost in the period (IST close
-- date), value in INR (won at the PO value); returns the resolved period
DROP PROCEDURE IF EXISTS spi_winloss_closed $$
CREATE PROCEDURE spi_winloss_closed(
  IN  p_user_id       BIGINT UNSIGNED,
  IN  p_fiscal_year   SMALLINT,
  IN  p_quarter       TINYINT,
  IN  p_owner_user_id BIGINT UNSIGNED,
  IN  p_product_id    BIGINT UNSIGNED,
  IN  p_industry_id   BIGINT UNSIGNED,
  IN  p_partner_id    BIGINT UNSIGNED,
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
   WHERE o.stage_code IN ('WON', 'LOST') AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN o_from AND o_to;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

-- sp_winloss_summary: period, kpis, monthly trend, loss reasons, competitors who beat us,
-- win reasons, lessons
DROP PROCEDURE IF EXISTS sp_winloss_summary $$
CREATE PROCEDURE sp_winloss_summary(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_fiscal_year   SMALLINT,
  IN p_quarter       TINYINT,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_product_id    BIGINT UNSIGNED,
  IN p_industry_id   BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
  COMMENT 'Win / loss analysis of the closed deals (12.12)'
BEGIN
  DECLARE v_fy   SMALLINT;
  DECLARE v_q    TINYINT;
  DECLARE v_from DATE;
  DECLARE v_to   DATE;

  CALL spi_winloss_closed(p_user_id, p_fiscal_year, p_quarter, p_owner_user_id, p_product_id, p_industry_id,
                          p_partner_id, v_fy, v_q, v_from, v_to);

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

-- sp_winloss_deals: the closed deals of the period with reasons and competitor; rows, { total }
DROP PROCEDURE IF EXISTS sp_winloss_deals $$
CREATE PROCEDURE sp_winloss_deals(
  IN p_user_id       BIGINT UNSIGNED,
  IN p_fiscal_year   SMALLINT,
  IN p_quarter       TINYINT,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_product_id    BIGINT UNSIGNED,
  IN p_industry_id   BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED,
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
                          p_partner_id, v_fy, v_q, v_from, v_to);

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

-- =============================================================================
-- DOCUMENTS (M14)
-- =============================================================================

-- sp_document_list: documents of the visible records (rule 3: a document has the
-- visibility of its parent); rows, { total }, counts per document type
DROP PROCEDURE IF EXISTS sp_document_list $$
CREATE PROCEDURE sp_document_list(
  IN p_user_id      BIGINT UNSIGNED,
  IN p_search       VARCHAR(100),
  IN p_type_code    VARCHAR(40),
  IN p_entity_type  VARCHAR(10),
  IN p_shared_with  VARCHAR(10),
  IN p_partner_id   BIGINT UNSIGNED,
  IN p_account_id   BIGINT UNSIGNED,
  IN p_tag          VARCHAR(60),
  IN p_offset       INT,
  IN p_limit        INT
)
  SQL SECURITY DEFINER
  COMMENT 'Document search over the visible records (12.13)'
BEGIN
  DECLARE v_search VARCHAR(100);
  DECLARE v_like   VARCHAR(310);

  CALL spi_like(p_search, v_search, v_like);
  CALL spi_visible_tenders(p_user_id);
  CALL spi_visible_partners(p_user_id);
  CALL spi_visible_leads(p_user_id);
  CALL spi_visible_accounts(p_user_id);  -- also leaves tmp_dash_opp

  DROP TEMPORARY TABLE IF EXISTS tmp_vis_doc;
  CREATE TEMPORARY TABLE tmp_vis_doc (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_vis_doc (id)
  SELECT d.id
    FROM document d
   WHERE d.is_active = 1 AND d.deleted_at IS NULL
     AND ((d.opportunity_id IS NOT NULL AND d.opportunity_id IN (SELECT id FROM tmp_dash_opp))
          OR (d.opportunity_id IS NULL AND d.entity_type = 'ACCOUNT' AND d.account_id IN (SELECT id FROM tmp_vis_acc))
          OR (d.entity_type = 'PARTNER' AND d.partner_id IN (SELECT id FROM tmp_vis_ptr))
          OR (d.entity_type = 'TENDER' AND d.entity_id IN (SELECT id FROM tmp_vis_tender))
          OR (d.entity_type = 'LEAD' AND d.entity_id IN (SELECT id FROM tmp_vis_lead)));
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_tender;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_lead;

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  CREATE TEMPORARY TABLE tmp_list (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_list (id)
  SELECT d.id FROM document d
    JOIN tmp_vis_doc v ON v.id = d.id
    JOIN file_object f ON f.id = d.file_object_id
   WHERE (v_search IS NULL OR d.title LIKE v_like OR f.original_name LIKE v_like
          OR EXISTS (SELECT 1 FROM document_tag t WHERE t.document_id = d.id AND t.tag LIKE v_like))
     AND (p_entity_type IS NULL OR d.entity_type = p_entity_type)
     AND (p_shared_with IS NULL OR d.shared_with = p_shared_with)
     AND (p_partner_id IS NULL OR d.partner_id = p_partner_id OR d.shared_with_partner_id = p_partner_id)
     AND (p_account_id IS NULL OR d.account_id = p_account_id)
     AND (p_tag IS NULL OR EXISTS (SELECT 1 FROM document_tag t WHERE t.document_id = d.id AND t.tag = p_tag));

  SELECT d.id, d.title, dt.code AS typeCode, dt.name AS typeName, d.entity_type AS entityType, d.entity_id AS entityId,
         CASE d.entity_type
           WHEN 'OPP' THEN (SELECT CONCAT(o.opportunity_no, ' · ', o.title) FROM opportunity o WHERE o.id = d.entity_id)
           WHEN 'ACCOUNT' THEN (SELECT a2.name FROM account a2 WHERE a2.id = d.entity_id)
           WHEN 'PARTNER' THEN (SELECT COALESCE(p2.short_name, p2.legal_name) FROM partner p2 WHERE p2.id = d.entity_id)
           WHEN 'TENDER' THEN (SELECT CONCAT(t.tender_no, ' · ', t.title) FROM tender t WHERE t.id = d.entity_id)
           WHEN 'ORDER' THEN (SELECT so.order_no FROM sales_order so WHERE so.id = d.entity_id)
           WHEN 'LEAD' THEN (SELECT CONCAT(l.lead_no, ' · ', COALESCE(la.name, l.account_name_text, l.contact_name))
                               FROM sales_lead l LEFT JOIN account la ON la.id = l.account_id WHERE l.id = d.entity_id)
         END AS entityLabel,
         a.name AS accountName, COALESCE(p.short_name, p.legal_name) AS partnerName,
         d.shared_with AS sharedWith, COALESCE(sp.short_name, sp.legal_name) AS sharedWithPartner,
         d.shared_on AS sharedOn, sb.full_name AS sharedByName, d.version_no AS versionNo, d.notes,
         f.original_name AS fileName, f.mime_type AS mimeType, f.size_bytes AS sizeBytes,
         (SELECT GROUP_CONCAT(t.tag ORDER BY t.tag SEPARATOR ',') FROM document_tag t WHERE t.document_id = d.id) AS tags,
         d.created_at AS createdAt
    FROM document d
    JOIN tmp_list l ON l.id = d.id
    JOIN file_object f ON f.id = d.file_object_id
    JOIN document_type dt ON dt.id = d.document_type_id
    LEFT JOIN account a ON a.id = d.account_id
    LEFT JOIN partner p ON p.id = d.partner_id
    LEFT JOIN partner sp ON sp.id = d.shared_with_partner_id
    LEFT JOIN `user` sb ON sb.id = d.shared_by
   WHERE p_type_code IS NULL OR dt.code = p_type_code
   ORDER BY IFNULL(d.shared_on, DATE(d.created_at)) DESC, d.id DESC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total FROM document d JOIN tmp_list l ON l.id = d.id
    JOIN document_type dt ON dt.id = d.document_type_id
   WHERE p_type_code IS NULL OR dt.code = p_type_code;

  SELECT dt.code AS typeCode, dt.name AS typeName, CAST(COUNT(*) AS SIGNED) AS count
    FROM document d JOIN tmp_list l ON l.id = d.id JOIN document_type dt ON dt.id = d.document_type_id
   GROUP BY dt.code, dt.name, dt.sort_order ORDER BY dt.sort_order;

  -- the most used tags of the visible documents, for the filter chips
  SELECT t.tag, CAST(COUNT(*) AS SIGNED) AS count
    FROM document_tag t JOIN tmp_vis_doc v ON v.id = t.document_id
   GROUP BY t.tag ORDER BY count DESC, t.tag LIMIT 20;

  DROP TEMPORARY TABLE IF EXISTS tmp_list;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_doc;
END $$

-- =============================================================================
-- REPORTS (M16)
-- =============================================================================

-- sp_report_revenue_gm: won revenue and gross margin by product, partner, industry or month
-- for the visible deals won in the period (19.1 REVENUE_GM)
DROP PROCEDURE IF EXISTS sp_report_revenue_gm $$
CREATE PROCEDURE sp_report_revenue_gm(
  IN p_user_id     BIGINT UNSIGNED,
  IN p_fiscal_year SMALLINT,
  IN p_quarter     TINYINT,
  IN p_dimension   VARCHAR(10)
)
  SQL SECURITY DEFINER
  COMMENT 'Revenue and GM by dimension (19.1)'
BEGIN
  DECLARE v_all   TINYINT;
  DECLARE v_fy    SMALLINT;
  DECLARE v_q     TINYINT;
  DECLARE v_from  DATE;
  DECLARE v_to    DATE;
  DECLARE v_today DATE;
  DECLARE v_dim   VARCHAR(10) DEFAULT UPPER(IFNULL(p_dimension, 'PRODUCT'));

  IF v_dim NOT IN ('PRODUCT', 'PARTNER', 'INDUSTRY', 'MONTH') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Group by product, partner, industry or month.', 'dimension');
  END IF;
  CALL spi_dashboard_period(p_fiscal_year, p_quarter, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);

  DROP TEMPORARY TABLE IF EXISTS tmp_won;
  CREATE TEMPORARY TABLE tmp_won (id BIGINT UNSIGNED NOT NULL PRIMARY KEY, revenue DECIMAL(18,2), gm DECIMAL(5,2) NULL);
  INSERT INTO tmp_won
  SELECT o.id, COALESCE(so.revenue, o.po_value, o.final_value, o.expected_value) * o.fx_rate, so.gross_margin_pct
    FROM opportunity o
    JOIN tmp_dash_opp t ON t.id = o.id
    LEFT JOIN sales_order so ON so.opportunity_id = o.id
   WHERE o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;

  SELECT v_fy AS fiscalYear, v_q AS quarter, v_from AS fromDate, v_to AS toDate, v_dim AS dimension;

  SELECT x.label, CAST(COUNT(*) AS SIGNED) AS deals, CAST(SUM(x.revenue) AS DECIMAL(18,2)) AS revenue,
         CAST(SUM(x.revenue * x.gm / 100) AS DECIMAL(18,2)) AS grossMargin,
         ROUND(100 * SUM(x.revenue * x.gm / 100) / NULLIF(SUM(IF(x.gm IS NULL, 0, x.revenue)), 0), 1) AS gmPct,
         CAST(SUM(IF(x.gm IS NULL, x.revenue, 0)) AS DECIMAL(18,2)) AS revenueWithoutGm
    FROM (
      SELECT w.revenue, w.gm,
             CASE v_dim
               WHEN 'PRODUCT' THEN (SELECT pr.name FROM opportunity_product op JOIN product pr ON pr.id = op.product_id
                                     WHERE op.opportunity_id = w.id ORDER BY op.is_primary DESC LIMIT 1)
               WHEN 'PARTNER' THEN IFNULL((SELECT COALESCE(p.short_name, p.legal_name) FROM opportunity_partner op
                                            JOIN partner p ON p.id = op.partner_id
                                           WHERE op.opportunity_id = w.id ORDER BY op.is_primary DESC LIMIT 1), 'Direct (no partner)')
               WHEN 'INDUSTRY' THEN (SELECT i.name FROM opportunity o JOIN account a ON a.id = o.account_id
                                       JOIN industry i ON i.id = COALESCE(o.industry_id, a.industry_id) WHERE o.id = w.id)
               ELSE (SELECT DATE_FORMAT(o.closed_at + INTERVAL 330 MINUTE, '%Y-%m') FROM opportunity o WHERE o.id = w.id)
             END AS label
        FROM tmp_won w
    ) x
   GROUP BY x.label
   ORDER BY IF(v_dim = 'MONTH', x.label, NULL), revenue DESC;

  SELECT CAST(COUNT(*) AS SIGNED) AS deals, CAST(IFNULL(SUM(revenue), 0) AS DECIMAL(18,2)) AS revenue,
         CAST(IFNULL(SUM(revenue * gm / 100), 0) AS DECIMAL(18,2)) AS grossMargin,
         ROUND(100 * SUM(revenue * gm / 100) / NULLIF(SUM(IF(gm IS NULL, 0, revenue)), 0), 1) AS gmPct
    FROM tmp_won;

  DROP TEMPORARY TABLE IF EXISTS tmp_won;
END $$

-- sp_report_product_mix: products per partner and per account (single vs multi) for the
-- visible deals open now or won in the period (19.1 PRODUCT_MIX)
DROP PROCEDURE IF EXISTS sp_report_product_mix $$
CREATE PROCEDURE sp_report_product_mix(
  IN p_user_id     BIGINT UNSIGNED,
  IN p_fiscal_year SMALLINT,
  IN p_quarter     TINYINT,
  IN p_partner_id  BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
  COMMENT 'Product mix per partner and per account (19.1)'
BEGIN
  DECLARE v_all   TINYINT;
  DECLARE v_fy    SMALLINT;
  DECLARE v_q     TINYINT;
  DECLARE v_from  DATE;
  DECLARE v_to    DATE;
  DECLARE v_today DATE;

  CALL spi_dashboard_period(p_fiscal_year, p_quarter, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, p_partner_id, v_all);

  DROP TEMPORARY TABLE IF EXISTS tmp_mix;
  CREATE TEMPORARY TABLE tmp_mix (opp_id BIGINT UNSIGNED, product_id BIGINT UNSIGNED, account_id BIGINT UNSIGNED,
                                  won TINYINT, PRIMARY KEY (opp_id, product_id));
  INSERT INTO tmp_mix
  SELECT o.id, op.product_id, o.account_id, o.stage_code = 'WON'
    FROM opportunity o
    JOIN tmp_dash_opp t ON t.id = o.id
    JOIN opportunity_product op ON op.opportunity_id = o.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE s.is_open = 1
      OR (o.stage_code = 'WON' AND DATE(o.closed_at + INTERVAL 330 MINUTE) BETWEEN v_from AND v_to);
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;

  SELECT v_fy AS fiscalYear, v_q AS quarter, v_from AS fromDate, v_to AS toDate;

  SELECT p.id AS partnerId, COALESCE(p.short_name, p.legal_name) AS partnerName,
         CAST(COUNT(DISTINCT m.product_id) AS SIGNED) AS products,
         GROUP_CONCAT(DISTINCT pr.name ORDER BY pr.sort_order SEPARATOR ', ') AS productNames,
         CAST(COUNT(DISTINCT m.opp_id) AS SIGNED) AS deals, CAST(COUNT(DISTINCT IF(m.won = 1, m.opp_id, NULL)) AS SIGNED) AS won
    FROM tmp_mix m
    JOIN opportunity_partner op ON op.opportunity_id = m.opp_id
    JOIN partner p ON p.id = op.partner_id
    JOIN product pr ON pr.id = m.product_id
   GROUP BY p.id, p.short_name, p.legal_name
   ORDER BY products DESC, deals DESC;

  SELECT a.id AS accountId, a.name AS accountName,
         CAST(COUNT(DISTINCT pr.id) AS SIGNED) AS products,
         GROUP_CONCAT(DISTINCT pr.name ORDER BY pr.sort_order SEPARATOR ', ') AS productNames,
         CAST(COUNT(DISTINCT m.opp_id) AS SIGNED) AS deals
    FROM tmp_mix m
    JOIN account a ON a.id = m.account_id
    JOIN product pr ON pr.id = m.product_id
   GROUP BY a.id, a.name
   ORDER BY products DESC, deals DESC;

  DROP TEMPORARY TABLE IF EXISTS tmp_mix;
END $$

DELIMITER ;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V010', 'Orders, win / loss, documents and reports, read side', 'V010__sp_order_views.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
