-- =============================================================================
-- V037  Sales CRM - tenders, write side                                  (2026-10-15)
--
--   spi_tender_edit_check       owner, backup or their manager (or ALL scope) + rowVersion.
--   spi_tender_readiness        readiness % = done mandatory items / mandatory items (all items
--                               when none is mandatory) (BR-TD-02).
--   sp_tender_save              POST / PATCH /tenders: the UM 4.4 fields; a new tender gets
--                               TND-0001 numbers and the OD-40 default checklist; BR-TD-04 dates.
--   sp_tender_edit_get          GET /tenders/{id}/edit: the values with ids and the version.
--   sp_tender_checklist_save    POST / PATCH /tenders/{id}/checklist: one item (text, mandatory,
--                               done, its document); readiness recomputed.
--   sp_tender_checklist_delete  DELETE /tenders/{id}/checklist/{itemId}
--   sp_tender_transition        POST /tenders/{id}/status-transitions: forward along the track
--                               (12.8), CANCELLED from any open status. NOT_AWARDED needs the
--                               loss reason (BR-TD-01); AWARDED needs the deal it links: the deal
--                               itself is closed WON on the deal (PO details, BR-OR-01), D-55.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V036.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS spi_tender_edit_check $$
CREATE PROCEDURE spi_tender_edit_check(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_id            BIGINT UNSIGNED,
  IN p_row_version   INT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_owner   BIGINT UNSIGNED;
  DECLARE v_backup  BIGINT UNSIGNED;
  DECLARE v_version INT UNSIGNED;

  SELECT owner_user_id, backup_owner_user_id, row_version INTO v_owner, v_backup, v_version
    FROM tender WHERE id = p_id AND is_active = 1;
  IF v_owner IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Tender not found.', 'id');
  END IF;
  IF p_allow_any = 0 AND NOT EXISTS (SELECT 1 FROM user_hierarchy
       WHERE ancestor_user_id = p_actor_user_id AND descendant_user_id IN (v_owner, IFNULL(v_backup, 0))) THEN
    CALL spi_raise('FORBIDDEN', 'Only the owner, the backup owner or their manager can change this tender.', 'id');
  END IF;
  IF p_row_version IS NOT NULL AND v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'Someone else changed this tender. Reload and try again.', 'rowVersion');
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_tender_readiness $$
CREATE PROCEDURE spi_tender_readiness(IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  UPDATE tender t
     SET t.readiness_pct = IFNULL((
           SELECT ROUND(100 * SUM(c.is_done) / COUNT(*), 2) FROM tender_checklist_item c
            WHERE c.tender_id = t.id
              AND (c.is_mandatory = 1
                   OR NOT EXISTS (SELECT 1 FROM tender_checklist_item m WHERE m.tender_id = t.id AND m.is_mandatory = 1))), 0)
   WHERE t.id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- sp_tender_save: p_id NULL = create
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_tender_save $$
CREATE PROCEDURE sp_tender_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_row_version   INT UNSIGNED,
  IN p_reference_no  VARCHAR(100),
  IN p_portal        VARCHAR(150),
  IN p_authority     VARCHAR(200),
  IN p_account_id    BIGINT UNSIGNED,
  IN p_title         VARCHAR(250),
  IN p_product_id    BIGINT UNSIGNED,
  IN p_value         DECIMAL(16,2),
  IN p_role          VARCHAR(10),
  IN p_bidder_id     BIGINT UNSIGNED,
  IN p_pre_bid_on    DATE,
  IN p_submission_on DATE,
  IN p_opening_on    DATE,
  IN p_spec          TINYINT(1),
  IN p_rfp           TINYINT(1),
  IN p_prebid        TINYINT(1),
  IN p_notes         TEXT,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_backup_id     BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id    BIGINT UNSIGNED;
  DECLARE v_no    VARCHAR(30);
  DECLARE v_owner BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_id IS NOT NULL THEN
    CALL spi_tender_edit_check(p_actor_user_id, p_id, p_row_version, p_allow_any);
    SELECT owner_user_id INTO v_owner FROM tender WHERE id = p_id;
  END IF;
  SET p_owner_user_id = COALESCE(p_owner_user_id, v_owner, p_actor_user_id);

  IF (p_pre_bid_on IS NOT NULL AND p_submission_on IS NOT NULL AND p_pre_bid_on > p_submission_on)
     OR (p_submission_on IS NOT NULL AND p_opening_on IS NOT NULL AND p_submission_on > p_opening_on) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Dates must run pre-bid, then submission, then opening.', 'submissionOn');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_owner_user_id AND status = 'ACTIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'The owner must be an active user.', 'ownerUserId');
  END IF;
  -- keeping the current owner is always allowed; a new owner must be in the actor's tree
  IF p_allow_any = 0 AND p_owner_user_id <> IFNULL(v_owner, 0) AND NOT EXISTS (SELECT 1 FROM user_hierarchy
       WHERE ancestor_user_id = p_actor_user_id AND descendant_user_id = p_owner_user_id) THEN
    CALL spi_raise('FORBIDDEN', 'The owner must be you or someone in your team.', 'ownerUserId');
  END IF;
  IF p_backup_id IS NOT NULL AND p_backup_id = p_owner_user_id THEN
    CALL spi_raise('VALIDATION_FAILED', 'The backup owner must differ from the owner.', 'backupOwnerUserId');
  END IF;
  IF p_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM account WHERE id = p_account_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active account.', 'accountId');
  END IF;
  IF p_bidder_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM partner WHERE id = p_bidder_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active partner.', 'bidderPartnerId');
  END IF;
  IF p_product_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM product WHERE id = p_product_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active product.', 'productId');
  END IF;

  START TRANSACTION;
  IF p_id IS NULL THEN
    CALL spi_next_number('TND', 0, v_no);
    INSERT INTO tender (tender_no, reference_no, portal, authority, account_id, title, product_id,
                        estimated_value, our_role, bidder_partner_id, pre_bid_on, submission_on, opening_on,
                        spec_influenced, rfp_influenced, prebid_queries_filed, intelligence_notes,
                        owner_user_id, backup_owner_user_id, created_by)
    VALUES (v_no, p_reference_no, p_portal, p_authority, p_account_id, p_title, p_product_id,
            p_value, p_role, p_bidder_id, p_pre_bid_on, p_submission_on, p_opening_on,
            p_spec, p_rfp, p_prebid, p_notes, p_owner_user_id, p_backup_id, p_actor_user_id);
    SET v_id = LAST_INSERT_ID();
    -- OD-40 default readiness checklist (UM 4.4)
    INSERT INTO tender_checklist_item (tender_id, item_text, is_mandatory, sort_order, created_by) VALUES
      (v_id, 'Eligibility criteria met', 1, 1, p_actor_user_id),
      (v_id, 'Bid documents ready', 1, 2, p_actor_user_id),
      (v_id, 'EMD arranged', 1, 3, p_actor_user_id),
      (v_id, 'OEM authorisation', 1, 4, p_actor_user_id),
      (v_id, 'Partner readiness confirmed', 1, 5, p_actor_user_id);
    INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by)
    VALUES ('TENDER', v_id, NULL, 'IDENTIFIED', p_actor_user_id);
  ELSE
    UPDATE tender
       SET reference_no = p_reference_no, portal = p_portal, authority = p_authority, account_id = p_account_id,
           title = p_title, product_id = p_product_id, estimated_value = p_value, our_role = p_role,
           bidder_partner_id = p_bidder_id, pre_bid_on = p_pre_bid_on, submission_on = p_submission_on,
           opening_on = p_opening_on, spec_influenced = p_spec, rfp_influenced = p_rfp,
           prebid_queries_filed = p_prebid, intelligence_notes = p_notes,
           owner_user_id = p_owner_user_id, backup_owner_user_id = p_backup_id,
           updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id, row_version = row_version + 1
     WHERE id = p_id;
    SET v_id = p_id;
  END IF;
  CALL spi_tender_readiness(v_id);
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('tender', v_id, IF(p_id IS NULL, 'TENDER_CREATE', 'TENDER_UPDATE'),
          JSON_OBJECT('title', p_title, 'ownerUserId', p_owner_user_id), p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT id, tender_no AS tenderNo, row_version AS rowVersion FROM tender WHERE id = v_id;
END $$

DROP PROCEDURE IF EXISTS sp_tender_edit_get $$
CREATE PROCEDURE sp_tender_edit_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible INT;

  CALL spi_visible_tenders(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_tender WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_tender;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Tender not found.', 'id');
  END IF;

  SELECT t.id, t.row_version AS rowVersion, t.status, t.reference_no AS referenceNo, t.portal, t.authority,
         t.account_id AS accountId, a.name AS accountName, t.title, t.product_id AS productId,
         CAST(t.estimated_value AS DECIMAL(18,2)) AS estimatedValue, t.our_role AS ourRole,
         t.bidder_partner_id AS bidderPartnerId, COALESCE(p.short_name, p.legal_name) AS bidderPartnerName,
         t.pre_bid_on AS preBidOn, t.submission_on AS submissionOn, t.opening_on AS openingOn,
         t.spec_influenced AS specInfluenced, t.rfp_influenced AS rfpInfluenced,
         t.prebid_queries_filed AS prebidQueriesFiled, t.intelligence_notes AS intelligenceNotes,
         t.owner_user_id AS ownerUserId, u.full_name AS ownerName,
         t.backup_owner_user_id AS backupOwnerUserId, b.full_name AS backupOwnerName,
         t.opportunity_id AS opportunityId
    FROM tender t
    JOIN `user` u ON u.id = t.owner_user_id
    LEFT JOIN `user` b ON b.id = t.backup_owner_user_id
    LEFT JOIN account a ON a.id = t.account_id
    LEFT JOIN partner p ON p.id = t.bidder_partner_id
   WHERE t.id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- checklist
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_tender_checklist_save $$
CREATE PROCEDURE sp_tender_checklist_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_tender_id     BIGINT UNSIGNED,
  IN p_item_id       BIGINT UNSIGNED,     -- NULL = new item
  IN p_text          VARCHAR(500),
  IN p_mandatory     TINYINT(1),
  IN p_done          TINYINT(1),
  IN p_document_id   BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_tender_edit_check(p_actor_user_id, p_tender_id, NULL, p_allow_any);
  IF p_item_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM tender_checklist_item WHERE id = p_item_id AND tender_id = p_tender_id) THEN
    CALL spi_raise('NOT_FOUND', 'Checklist item not found.', 'itemId');
  END IF;
  IF p_document_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM document WHERE id = p_document_id AND is_active = 1
                                                  AND entity_type = 'TENDER' AND entity_id = p_tender_id) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose a document of this tender.', 'documentId');
  END IF;

  START TRANSACTION;
  IF p_item_id IS NULL THEN
    INSERT INTO tender_checklist_item (tender_id, item_text, is_mandatory, is_done, done_by, done_at,
                                       document_id, sort_order, created_by)
    SELECT p_tender_id, p_text, p_mandatory, p_done, IF(p_done = 1, p_actor_user_id, NULL),
           IF(p_done = 1, UTC_TIMESTAMP(3), NULL), p_document_id, IFNULL(MAX(sort_order), 0) + 1, p_actor_user_id
      FROM tender_checklist_item WHERE tender_id = p_tender_id;
    SET v_id = LAST_INSERT_ID();
  ELSE
    UPDATE tender_checklist_item
       -- the page does not carry the document id: none sent keeps the stored one
       SET item_text = p_text, is_mandatory = p_mandatory, document_id = COALESCE(p_document_id, document_id),
           done_by = IF(p_done = 1, IF(is_done = 1, done_by, p_actor_user_id), NULL),
           done_at = IF(p_done = 1, IF(is_done = 1, done_at, UTC_TIMESTAMP(3)), NULL),
           is_done = p_done, updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
     WHERE id = p_item_id;
    SET v_id = p_item_id;
  END IF;
  CALL spi_tender_readiness(p_tender_id);
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('tender', p_tender_id, 'TENDER_CHECKLIST', JSON_OBJECT('itemId', v_id, 'done', p_done = 1),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id, readiness_pct AS readinessPct FROM tender WHERE id = p_tender_id;
END $$

DROP PROCEDURE IF EXISTS sp_tender_checklist_delete $$
CREATE PROCEDURE sp_tender_checklist_delete(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_tender_id     BIGINT UNSIGNED,
  IN p_item_id       BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_tender_edit_check(p_actor_user_id, p_tender_id, NULL, p_allow_any);
  IF NOT EXISTS (SELECT 1 FROM tender_checklist_item WHERE id = p_item_id AND tender_id = p_tender_id) THEN
    CALL spi_raise('NOT_FOUND', 'Checklist item not found.', 'itemId');
  END IF;
  START TRANSACTION;
  DELETE FROM tender_checklist_item WHERE id = p_item_id;
  CALL spi_tender_readiness(p_tender_id);
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('tender', p_tender_id, 'TENDER_CHECKLIST_REMOVE', JSON_OBJECT('itemId', p_item_id),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;
END $$

-- ---------------------------------------------------------------------------
-- sp_tender_transition
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_tender_transition $$
CREATE PROCEDURE sp_tender_transition(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_row_version   INT UNSIGNED,
  IN p_to            VARCHAR(14),
  IN p_result        VARCHAR(20),
  IN p_l1_price      DECIMAL(16,2),
  IN p_our_price     DECIMAL(16,2),
  IN p_winner        VARCHAR(200),
  IN p_loss_reason   BIGINT UNSIGNED,
  IN p_opportunity   BIGINT UNSIGNED,
  IN p_reason        VARCHAR(1000),
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_from     VARCHAR(14);
  DECLARE v_from_seq INT;
  DECLARE v_to_seq   INT;
  DECLARE v_open     TINYINT;
  DECLARE v_opp      BIGINT UNSIGNED;
  DECLARE v_account  BIGINT UNSIGNED;
  DECLARE v_since    DATETIME(3);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_tender_edit_check(p_actor_user_id, p_id, p_row_version, p_allow_any);
  SELECT status, opportunity_id, account_id INTO v_from, v_opp, v_account FROM tender WHERE id = p_id;
  SELECT sequence_no, is_open INTO v_from_seq, v_open FROM stage WHERE entity = 'TENDER' AND code = v_from;
  SELECT sequence_no INTO v_to_seq FROM stage WHERE entity = 'TENDER' AND code = p_to;

  IF v_to_seq IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown tender status.', 'toStatus');
  END IF;
  IF v_open = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'This tender is closed.', 'toStatus');
  END IF;
  IF p_to <> 'CANCELLED' AND v_to_seq <= v_from_seq THEN
    CALL spi_raise('VALIDATION_FAILED', 'A tender moves forward along its track.', 'toStatus');
  END IF;
  IF p_to = 'NOT_AWARDED' AND p_loss_reason IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Record why the tender was lost.', 'lossReasonId');
  END IF;
  IF p_loss_reason IS NOT NULL AND NOT EXISTS (SELECT 1 FROM reason WHERE id = p_loss_reason AND reason_type = 'LOSS') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose a loss reason.', 'lossReasonId');
  END IF;
  SET v_opp = COALESCE(p_opportunity, v_opp);
  IF p_to = 'AWARDED' AND v_opp IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Link the deal this tender belongs to; it is closed as WON on the deal.', 'opportunityId');
  END IF;
  IF p_opportunity IS NOT NULL AND NOT EXISTS (SELECT 1 FROM opportunity WHERE id = p_opportunity AND is_active = 1
                                                  AND (v_account IS NULL OR account_id = v_account)) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active deal of the tender''s account.', 'opportunityId');
  END IF;

  SELECT MAX(changed_at) INTO v_since FROM stage_history WHERE entity_type = 'TENDER' AND entity_id = p_id;

  START TRANSACTION;
  UPDATE tender
     SET status = p_to, opportunity_id = v_opp,
         result = COALESCE(p_result, result), l1_price = COALESCE(p_l1_price, l1_price),
         our_price = COALESCE(p_our_price, our_price), winner = COALESCE(p_winner, winner),
         loss_reason_id = COALESCE(p_loss_reason, loss_reason_id),
         updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id, row_version = row_version + 1
   WHERE id = p_id;
  INSERT INTO stage_history (entity_type, entity_id, from_stage, to_stage, changed_by, reason, days_in_previous)
  VALUES ('TENDER', p_id, v_from, p_to, p_actor_user_id, p_reason,
          IF(v_since IS NULL, NULL, DATEDIFF(UTC_TIMESTAMP(3), v_since)));
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('tender', p_id, 'TENDER_STATUS', JSON_OBJECT('from', v_from, 'to', p_to, 'opportunityId', v_opp),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT t.id, t.status, t.row_version AS rowVersion, t.opportunity_id AS opportunityId,
         o.stage_code AS opportunityStage
    FROM tender t LEFT JOIN opportunity o ON o.id = t.opportunity_id WHERE t.id = p_id;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V037', 'Tenders write side: save, checklist and readiness, status transitions', UTC_TIMESTAMP());
