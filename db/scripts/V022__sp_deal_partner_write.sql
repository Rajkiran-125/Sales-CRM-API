-- =============================================================================
-- V022  Sales CRM - partners on deals, competitors, partner commercial    (2026-10-14)
--
--   spi_opp_edit_check              Deal exists, is open (optional) and the actor may edit it.
--   sp_opportunity_partner_add      Map a partner on a deal with a role (BR-OP-12).
--   sp_opportunity_partner_update   Change role, contact, engagement, primary, notes.
--   sp_opportunity_partner_remove   Unmap a partner (refused once commercials exist).
--   sp_opportunity_competitor_add / _update / _remove
--   sp_partner_commercial_create    New commercial version, never overwritten (BR-OP-13).
--   sp_opportunity_get              Re-issue of V013 adding partnerContactId / Name,
--                                   competitorId and the commercial partnerId.
--
-- Edit rights (as sp_opportunity_update): ALL scope, the owner, a manager of the
-- owner, or the deal's pre-sales owner. Commercials: also the partner's relationship
-- owner or their manager.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V021.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- spi_opp_edit_check
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_opp_edit_check $$
CREATE PROCEDURE spi_opp_edit_check(
  IN  p_actor_user_id BIGINT UNSIGNED,
  IN  p_opp_id        BIGINT UNSIGNED,
  IN  p_require_open  TINYINT(1),
  OUT o_account_id    BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_owner    BIGINT UNSIGNED;
  DECLARE v_presales BIGINT UNSIGNED;
  DECLARE v_stage    VARCHAR(20);
  DECLARE v_all      TINYINT;
  DECLARE v_own      TINYINT;
  DECLARE v_assigned TINYINT;
  DECLARE v_partner  TINYINT;
  DECLARE v_module   TINYINT;

  SET o_account_id = NULL;
  SELECT owner_user_id, presales_owner_user_id, stage_code, account_id
    INTO v_owner, v_presales, v_stage, o_account_id
    FROM opportunity WHERE id = p_opp_id AND is_active = 1;

  IF v_owner IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
  END IF;

  CALL spi_scope_flags(p_actor_user_id, v_all, v_own, v_assigned, v_partner, v_module);
  IF v_all = 0 AND v_owner <> p_actor_user_id AND IFNULL(v_presales, 0) <> p_actor_user_id
     AND NOT EXISTS (SELECT 1 FROM user_hierarchy h
                      WHERE h.ancestor_user_id = p_actor_user_id AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You do not have permission to edit this opportunity.', 'id');
  END IF;

  IF p_require_open = 1 AND v_stage IN ('WON', 'LOST') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Closed opportunities cannot be edited.', 'stageCode');
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- spi_opp_partner_validate: role, engagement level, contact of that partner,
-- one primary per deal.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_opp_partner_validate $$
CREATE PROCEDURE spi_opp_partner_validate(
  IN p_opp_id      BIGINT UNSIGNED,
  IN p_row_id      BIGINT UNSIGNED,  -- NULL on add
  IN p_partner_id  BIGINT UNSIGNED,
  IN p_role        VARCHAR(12),
  IN p_contact_id  BIGINT UNSIGNED,
  IN p_level       VARCHAR(6),
  IN p_is_primary  TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  IF p_role NOT IN ('SOURCED','INFLUENCED','FULFILMENT','SERVICE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose a partner role.', 'partnerRole');
  END IF;
  IF p_level IS NOT NULL AND p_level NOT IN ('HIGH','MEDIUM','LOW') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid engagement level.', 'engagementLevel');
  END IF;
  IF p_contact_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM contact WHERE id = p_contact_id AND partner_id = p_partner_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'The contact must be an active contact of this partner.', 'partnerContactId');
  END IF;
  IF p_is_primary = 1 AND EXISTS (
       SELECT 1 FROM opportunity_partner
        WHERE opportunity_id = p_opp_id AND is_primary = 1 AND id <> IFNULL(p_row_id, 0)) THEN
    CALL spi_raise('VALIDATION_FAILED', 'This deal already has a primary partner. Unmark it first.', 'isPrimary');
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_partner_add
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_partner_add $$
CREATE PROCEDURE sp_opportunity_partner_add(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_opp_id        BIGINT UNSIGNED,
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_role          VARCHAR(12),
  IN p_contact_id    BIGINT UNSIGNED,
  IN p_level         VARCHAR(6),
  IN p_is_primary    TINYINT(1),
  IN p_confirmed     TINYINT(1),
  IN p_notes         VARCHAR(1000)
)
  SQL SECURITY DEFINER
  COMMENT 'Map a partner on a deal (BR-OP-12)'
BEGIN
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_id      BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_opp_edit_check(p_actor_user_id, p_opp_id, 1, v_account);
  IF NOT EXISTS (SELECT 1 FROM partner WHERE id = p_partner_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active partner.', 'partnerId');
  END IF;
  CALL spi_opp_partner_validate(p_opp_id, NULL, p_partner_id, p_role, p_contact_id, p_level, p_is_primary);
  IF EXISTS (SELECT 1 FROM opportunity_partner
              WHERE opportunity_id = p_opp_id AND partner_id = p_partner_id AND partner_role = p_role) THEN
    CALL spi_raise('DUPLICATE', 'This partner already has this role on the deal.', 'partnerId');
  END IF;

  START TRANSACTION;
  INSERT INTO opportunity_partner (opportunity_id, partner_id, partner_role, partner_contact_id,
                                   engagement_level, is_primary, commercial_confirmed, notes,
                                   created_at, created_by)
  VALUES (p_opp_id, p_partner_id, p_role, p_contact_id, p_level, p_is_primary, p_confirmed, p_notes,
          UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();

  -- a mapped partner ends "partner to be mapped" (BR-OP-12)
  UPDATE opportunity SET partner_tbm = 0 WHERE id = p_opp_id AND partner_tbm = 1;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opp_id, 'OPPORTUNITY_PARTNER_ADD',
          JSON_OBJECT('partnerId', p_partner_id, 'partnerRole', p_role, 'isPrimary', p_is_primary = 1),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_partner_update
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_partner_update $$
CREATE PROCEDURE sp_opportunity_partner_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_opp_id        BIGINT UNSIGNED,
  IN p_row_id        BIGINT UNSIGNED,
  IN p_role          VARCHAR(12),
  IN p_contact_id    BIGINT UNSIGNED,
  IN p_level         VARCHAR(6),
  IN p_is_primary    TINYINT(1),
  IN p_confirmed     TINYINT(1),
  IN p_notes         VARCHAR(1000)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_partner BIGINT UNSIGNED;
  DECLARE v_role    VARCHAR(12);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_opp_edit_check(p_actor_user_id, p_opp_id, 1, v_account);
  SELECT partner_id, partner_role INTO v_partner, v_role
    FROM opportunity_partner WHERE id = p_row_id AND opportunity_id = p_opp_id;
  IF v_partner IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Partner row not found on this deal.', 'rowId');
  END IF;
  CALL spi_opp_partner_validate(p_opp_id, p_row_id, v_partner, p_role, p_contact_id, p_level, p_is_primary);
  IF p_role <> v_role AND EXISTS (SELECT 1 FROM opportunity_partner
       WHERE opportunity_id = p_opp_id AND partner_id = v_partner AND partner_role = p_role) THEN
    CALL spi_raise('DUPLICATE', 'This partner already has this role on the deal.', 'partnerRole');
  END IF;

  START TRANSACTION;
  UPDATE opportunity_partner SET
    partner_role         = p_role,
    partner_contact_id   = p_contact_id,
    engagement_level     = p_level,
    is_primary           = p_is_primary,
    commercial_confirmed = p_confirmed,
    notes                = p_notes,
    updated_at           = UTC_TIMESTAMP(3),
    updated_by           = p_actor_user_id
  WHERE id = p_row_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opp_id, 'OPPORTUNITY_PARTNER_UPDATE',
          JSON_OBJECT('partnerId', v_partner, 'partnerRole', JSON_OBJECT('from', v_role, 'to', p_role)),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT p_row_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_partner_remove
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_partner_remove $$
CREATE PROCEDURE sp_opportunity_partner_remove(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_opp_id        BIGINT UNSIGNED,
  IN p_row_id        BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_partner BIGINT UNSIGNED;
  DECLARE v_role    VARCHAR(12);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_opp_edit_check(p_actor_user_id, p_opp_id, 1, v_account);
  SELECT partner_id, partner_role INTO v_partner, v_role
    FROM opportunity_partner WHERE id = p_row_id AND opportunity_id = p_opp_id;
  IF v_partner IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Partner row not found on this deal.', 'rowId');
  END IF;
  -- BR-OP-13: commercials are never lost, so their partner stays on the deal
  IF EXISTS (SELECT 1 FROM partner_commercial
              WHERE opportunity_id = p_opp_id AND partner_id = v_partner AND partner_role = v_role) THEN
    CALL spi_raise('CONFLICT', 'This partner has commercial versions on the deal and cannot be removed.', 'rowId');
  END IF;

  START TRANSACTION;
  DELETE FROM opportunity_partner WHERE id = p_row_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opp_id, 'OPPORTUNITY_PARTNER_REMOVE',
          JSON_OBJECT('partnerId', v_partner, 'partnerRole', v_role),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_competitor_add
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_competitor_add $$
CREATE PROCEDURE sp_opportunity_competitor_add(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_opp_id         BIGINT UNSIGNED,
  IN p_competitor_id  BIGINT UNSIGNED,
  IN p_their_price    DECIMAL(16,2),
  IN p_strength       VARCHAR(1000),
  IN p_differentiator VARCHAR(1000)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_id      BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_opp_edit_check(p_actor_user_id, p_opp_id, 1, v_account);
  IF NOT EXISTS (SELECT 1 FROM competitor WHERE id = p_competitor_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active competitor.', 'competitorId');
  END IF;
  IF p_their_price IS NOT NULL AND p_their_price < 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'The price cannot be negative.', 'theirPrice');
  END IF;
  IF EXISTS (SELECT 1 FROM opportunity_competitor WHERE opportunity_id = p_opp_id AND competitor_id = p_competitor_id) THEN
    CALL spi_raise('DUPLICATE', 'This competitor is already on the deal.', 'competitorId');
  END IF;

  START TRANSACTION;
  INSERT INTO opportunity_competitor (opportunity_id, competitor_id, their_price, their_strength,
                                      our_differentiator, created_at, created_by)
  VALUES (p_opp_id, p_competitor_id, p_their_price, p_strength, p_differentiator,
          UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();

  -- a named competitor contradicts "no competition"
  UPDATE opportunity SET no_competition = 0 WHERE id = p_opp_id AND no_competition = 1;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opp_id, 'OPPORTUNITY_COMPETITOR_ADD', JSON_OBJECT('competitorId', p_competitor_id),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_competitor_update
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_competitor_update $$
CREATE PROCEDURE sp_opportunity_competitor_update(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_opp_id         BIGINT UNSIGNED,
  IN p_row_id         BIGINT UNSIGNED,
  IN p_their_price    DECIMAL(16,2),
  IN p_strength       VARCHAR(1000),
  IN p_differentiator VARCHAR(1000)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_account    BIGINT UNSIGNED;
  DECLARE v_competitor BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_opp_edit_check(p_actor_user_id, p_opp_id, 1, v_account);
  SELECT competitor_id INTO v_competitor
    FROM opportunity_competitor WHERE id = p_row_id AND opportunity_id = p_opp_id;
  IF v_competitor IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Competitor row not found on this deal.', 'rowId');
  END IF;
  IF p_their_price IS NOT NULL AND p_their_price < 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'The price cannot be negative.', 'theirPrice');
  END IF;

  START TRANSACTION;
  UPDATE opportunity_competitor SET
    their_price        = p_their_price,
    their_strength     = p_strength,
    our_differentiator = p_differentiator,
    updated_at         = UTC_TIMESTAMP(3),
    updated_by         = p_actor_user_id
  WHERE id = p_row_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opp_id, 'OPPORTUNITY_COMPETITOR_UPDATE', JSON_OBJECT('competitorId', v_competitor),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT p_row_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_competitor_remove
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_competitor_remove $$
CREATE PROCEDURE sp_opportunity_competitor_remove(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_opp_id        BIGINT UNSIGNED,
  IN p_row_id        BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_account    BIGINT UNSIGNED;
  DECLARE v_competitor BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_opp_edit_check(p_actor_user_id, p_opp_id, 1, v_account);
  SELECT competitor_id INTO v_competitor
    FROM opportunity_competitor WHERE id = p_row_id AND opportunity_id = p_opp_id;
  IF v_competitor IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Competitor row not found on this deal.', 'rowId');
  END IF;

  START TRANSACTION;
  DELETE FROM opportunity_competitor WHERE id = p_row_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opp_id, 'OPPORTUNITY_COMPETITOR_REMOVE', JSON_OBJECT('competitorId', v_competitor),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_commercial_create: version n+1 per (deal, partner); allowed on
-- closed deals too (the commercial outlives the deal close).
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_commercial_create $$
CREATE PROCEDURE sp_partner_commercial_create(
  IN p_actor_user_id    BIGINT UNSIGNED,
  IN p_request_id       VARCHAR(36),
  IN p_ip               VARCHAR(45),
  IN p_opp_id           BIGINT UNSIGNED,
  IN p_partner_id       BIGINT UNSIGNED,
  IN p_role             VARCHAR(12),
  IN p_deal_size_basis  VARCHAR(250),
  IN p_price            DECIMAL(16,2),
  IN p_margin_pct       DECIMAL(5,2),
  IN p_payment_terms    VARCHAR(250),
  IN p_pay_after        TINYINT(1),
  IN p_valid_till       DATE,
  IN p_bundle_tag       VARCHAR(60),
  IN p_remarks          VARCHAR(1000)
)
  SQL SECURITY DEFINER
  COMMENT 'New partner commercial version (BR-OP-13)'
BEGIN
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_version INT UNSIGNED;
  DECLARE v_id      BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  -- the partner's relationship owner (or their manager) may record commercials too
  IF EXISTS (SELECT 1 FROM partner pt JOIN user_hierarchy h ON h.descendant_user_id = pt.relationship_owner_user_id
              WHERE pt.id = p_partner_id AND h.ancestor_user_id = p_actor_user_id) THEN
    SELECT account_id INTO v_account FROM opportunity WHERE id = p_opp_id AND is_active = 1;
    IF v_account IS NULL THEN
      CALL spi_raise('NOT_FOUND', 'Opportunity not found.', 'id');
    END IF;
  ELSE
    CALL spi_opp_edit_check(p_actor_user_id, p_opp_id, 0, v_account);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM opportunity_partner
                  WHERE opportunity_id = p_opp_id AND partner_id = p_partner_id AND partner_role = p_role) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Map this partner on the deal with this role first.', 'partnerId');
  END IF;
  IF p_price IS NULL OR p_price <= 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'The price to the partner must be above zero.', 'priceToPartner');
  END IF;
  IF p_margin_pct IS NOT NULL AND (p_margin_pct < 0 OR p_margin_pct > 100) THEN
    CALL spi_raise('VALIDATION_FAILED', 'The margin must be between 0 and 100 %.', 'partnerMarginPct');
  END IF;

  START TRANSACTION;
  SELECT IFNULL(MAX(version_no), 0) + 1 INTO v_version
    FROM partner_commercial WHERE opportunity_id = p_opp_id AND partner_id = p_partner_id FOR UPDATE;

  INSERT INTO partner_commercial (opportunity_id, partner_id, account_id, partner_role, version_no,
                                  deal_size_basis, price_to_partner, partner_margin_pct, payment_terms,
                                  pay_partner_after_customer, valid_till, bundle_tag, remarks,
                                  created_at, created_by)
  VALUES (p_opp_id, p_partner_id, v_account, p_role, v_version,
          p_deal_size_basis, p_price, p_margin_pct, p_payment_terms,
          p_pay_after, p_valid_till, p_bundle_tag, p_remarks,
          UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opp_id, 'PARTNER_COMMERCIAL_CREATE',
          JSON_OBJECT('partnerId', p_partner_id, 'versionNo', v_version, 'priceToPartner', p_price),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id, v_version AS versionNo;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_get: V013 + partnerContactId / Name, competitorId, commercial partnerId
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_get $$
CREATE PROCEDURE sp_opportunity_get(
  IN p_user_id            BIGINT UNSIGNED,
  IN p_id                 BIGINT UNSIGNED,
  IN p_can_see_commercial TINYINT
)
  SQL SECURITY DEFINER
  COMMENT 'Deal workspace, read side (12.5) + row_version for optimistic lock'
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

  -- RS 0: deal header (adds rowVersion + loose IDs on top of V008 for the edit form)
  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, o.account_id AS accountId,
         a.name AS accountName, a.is_strategic AS accountStrategic, o.source,
         i.name AS industryName, o.industry_id AS industryId,
         so.name AS solutionName, o.solution_id AS solutionId,
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
         o.confidence_override_pct AS confidenceOverridePct,
         o.confidence_override_reason AS confidenceOverrideReason,
         o.currency, o.fx_rate AS fxRate,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(o.expected_value AS DECIMAL(18,2)) AS expectedValue,
         CAST(o.weighted_value AS DECIMAL(18,2)) AS weighted,
         o.expected_close_date AS expectedCloseDate, o.close_date_change_count AS closeDateChangeCount,
         CAST(o.commercial_window_value AS DECIMAL(18,2)) AS commercialWindowValue,
         o.commercial_window_accepted AS commercialWindowAccepted, o.budget_known AS budgetKnown,
         CAST(o.budget_min AS DECIMAL(18,2)) AS budgetMin, CAST(o.budget_max AS DECIMAL(18,2)) AS budgetMax,
         o.procurement_type_id AS procurementTypeId, pt.name AS procurementTypeName,
         o.current_procurement_step_id AS currentProcurementStepId, pst.name AS procurementStepName,
         o.validation_status AS validationStatus, vb.full_name AS validatedByName,
         o.validated_at AS validatedAt, o.validation_remark AS validationRemark,
         o.owner_user_id AS ownerUserId, u.full_name AS ownerName,
         o.backup_owner_user_id AS backupOwnerUserId, bu.full_name AS backupOwnerName,
         o.presales_owner_user_id AS presalesOwnerUserId, ps.full_name AS presalesName,
         o.sponsor_user_id AS sponsorUserId, sp.full_name AS sponsorName,
         o.partner_tbm AS partnerTbm, o.no_competition AS noCompetition,
         CAST(o.final_value AS DECIMAL(18,2)) AS finalValue, o.payment_terms AS paymentTerms,
         o.po_number AS poNumber, o.po_date AS poDate, CAST(o.po_value AS DECIMAL(18,2)) AS poValue,
         o.closed_at AS closedAt, dr.name AS dormantReason, o.dormant_note AS dormantNote,
         o.wake_up_date AS wakeUpDate, o.bundle_tag AS bundleTag, o.health,
         o.last_activity_at AS lastActivityAt, o.last_status_at AS lastStatusAt,
         o.lead_id AS leadId, l.lead_no AS leadNo,
         (SELECT so2.id FROM sales_order so2 WHERE so2.opportunity_id = o.id LIMIT 1) AS orderId,
         o.created_at AS createdAt, cb.full_name AS createdByName,
         o.row_version AS rowVersion
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

  -- RS 1: stepper
  SELECT code, name, sequence_no AS sequenceNo, default_confidence_pct AS confidencePct,
         is_open AS isOpen, is_won AS isWon, is_lost AS isLost
    FROM stage WHERE entity = 'OPP' AND is_active = 1 ORDER BY sequence_no;

  -- RS 2: products
  SELECT pr.id, pr.name, opr.is_primary AS isPrimary
    FROM opportunity_product opr JOIN product pr ON pr.id = opr.product_id
   WHERE opr.opportunity_id = p_id ORDER BY opr.is_primary DESC, pr.name;

  -- RS 3: DMU contacts (opportunity_dmu links to contact; d.name does not exist — use c.name)
  SELECT d.id, c.id AS contactId, c.name, c.designation, c.department, c.email, c.phone,
         d.dmu_role AS dmuRole, d.influence_level AS influenceLevel, d.stand, d.notes
    FROM opportunity_dmu d JOIN contact c ON c.id = d.contact_id
   WHERE d.opportunity_id = p_id
   ORDER BY FIELD(d.dmu_role, 'TECH_BUYER', 'COMM_BUYER', 'SPONSOR', 'INFLUENCER_INT', 'INFLUENCER_EXT'), d.id;

  -- RS 4: partners
  SELECT op.id, p.id AS partnerId, p.partner_no AS partnerNo,
         COALESCE(p.short_name, p.legal_name) AS partnerName, p.tier,
         op.partner_role AS partnerRole, op.engagement_level AS engagementLevel,
         op.is_primary AS isPrimary, op.commercial_confirmed AS commercialConfirmed, op.notes,
         op.partner_contact_id AS partnerContactId, pct.name AS partnerContactName
    FROM opportunity_partner op JOIN partner p ON p.id = op.partner_id
    LEFT JOIN contact pct ON pct.id = op.partner_contact_id
   WHERE op.opportunity_id = p_id
   ORDER BY op.is_primary DESC, op.id;

  -- RS 5: competitors
  SELECT oc.id, oc.competitor_id AS competitorId, c.name, CAST(oc.their_price AS DECIMAL(18,2)) AS theirPrice,
         oc.their_strength AS theirStrength, oc.our_differentiator AS ourDifferentiator
    FROM opportunity_competitor oc JOIN competitor c ON c.id = oc.competitor_id
   WHERE oc.opportunity_id = p_id ORDER BY c.name;

  -- RS 6: POC
  SELECT pc.id, pc.external_poc_ref AS externalPocRef, pc.status, pc.start_date AS startDate,
         pc.end_date AS endDate, pc.success_criteria AS successCriteria, pc.exit_criteria AS exitCriteria,
         c.name AS customerLeadName, u2.full_name AS cnergeeLeadName, pc.result,
         pc.customer_validated AS customerValidated, pc.readout_date AS readoutDate,
         pc.skipped, pc.skip_reason AS skipReason, pc.notes
    FROM opportunity_poc pc
    LEFT JOIN contact c ON c.id = pc.customer_lead_contact_id
    LEFT JOIN `user` u2 ON u2.id = pc.cnergee_lead_user_id
   WHERE pc.opportunity_id = p_id;

  -- RS 7: offers
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

  -- RS 8: partner commercial (only for holders of partner_commercial.view)
  SELECT pc.id, pc.partner_id AS partnerId, COALESCE(p.short_name, p.legal_name) AS partnerName, pc.partner_role AS partnerRole,
         pc.version_no AS versionNo, pc.deal_size_basis AS dealSizeBasis,
         CAST(pc.price_to_partner AS DECIMAL(18,2)) AS priceToPartner,
         pc.partner_margin_pct AS partnerMarginPct, pc.payment_terms AS paymentTerms,
         pc.pay_partner_after_customer AS payPartnerAfterCustomer, pc.valid_till AS validTill,
         pc.remarks, pc.created_at AS createdAt, u3.full_name AS createdByName
    FROM partner_commercial pc
    JOIN partner p ON p.id = pc.partner_id
    LEFT JOIN `user` u3 ON u3.id = pc.created_by
   WHERE pc.opportunity_id = p_id AND p_can_see_commercial = 1
   ORDER BY p.short_name, pc.version_no DESC;

  -- RS 9: activities
  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject,
         ac.notes, ac.outcome, ac.people_met AS peopleMet, ac.next_action AS nextAction,
         ac.next_action_on AS nextActionOn, u4.full_name AS byName
    FROM activity ac JOIN `user` u4 ON u4.id = ac.by_user_id
   WHERE ac.is_active = 1 AND (ac.opportunity_id = p_id OR (ac.entity_type = 'OPP' AND ac.entity_id = p_id))
   ORDER BY ac.activity_at DESC, ac.id DESC
   LIMIT 100;

  -- RS 10: weekly status
  SELECT ws.id, ws.week_start AS weekStart, ws.status, ws.this_week AS thisWeek,
         ws.next_step AS nextStep, ws.expected_close_date AS expectedCloseDate,
         ws.close_change_reason AS closeChangeReason,
         CAST(ws.expected_value AS DECIMAL(18,2)) AS expectedValue, s.name AS stageName,
         u5.full_name AS submittedByName, ws.submitted_at AS submittedAt
    FROM weekly_status ws
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = ws.stage_code
    LEFT JOIN `user` u5 ON u5.id = ws.submitted_by
   WHERE ws.opportunity_id = p_id
   ORDER BY ws.week_start DESC
   LIMIT 26;

  -- RS 11: monthly commits
  SELECT mc.id, mc.commit_month AS commitMonth, mc.commit_type AS commitType,
         CAST(mc.commit_value AS DECIMAL(18,2)) AS commitValue, mc.achieved
    FROM monthly_commit mc WHERE mc.opportunity_id = p_id ORDER BY mc.commit_month DESC;

  -- RS 12: stage history
  SELECT sh.id, fs.name AS fromStage, ts.name AS toStage, sh.to_stage AS toStageCode,
         u6.full_name AS changedByName, sh.changed_at AS changedAt, sh.reason,
         sh.days_in_previous AS daysInPrevious, sh.was_override AS wasOverride
    FROM stage_history sh
    LEFT JOIN stage fs ON fs.entity = 'OPP' AND fs.code = sh.from_stage
    LEFT JOIN stage ts ON ts.entity = 'OPP' AND ts.code = sh.to_stage
    LEFT JOIN `user` u6 ON u6.id = sh.changed_by
   WHERE sh.entity_type = 'OPP' AND sh.entity_id = p_id
   ORDER BY sh.changed_at DESC, sh.id DESC;

  -- RS 13: win/loss
  SELECT wl.outcome, lr.name AS lossReason, c.name AS competitorName, wl.detail, wl.lesson,
         wl.competition_replaced AS competitionReplaced, wl.remarks,
         (SELECT GROUP_CONCAT(r.name ORDER BY r.sort_order SEPARATOR ', ')
            FROM win_loss_reason wr JOIN reason r ON r.id = wr.reason_id
           WHERE wr.opportunity_id = wl.opportunity_id) AS winReasons,
         u7.full_name AS recordedByName, wl.recorded_at AS recordedAt
    FROM win_loss wl
    LEFT JOIN reason lr ON lr.id = wl.loss_reason_id
    LEFT JOIN competitor c ON c.id = wl.competitor_id
    LEFT JOIN `user` u7 ON u7.id = wl.recorded_by
   WHERE wl.opportunity_id = p_id;

  -- RS 14: tasks
  SELECT tk.id, tk.task_type AS taskType, tk.title, tk.due_at AS dueAt, tk.status,
         u8.full_name AS ownerName
    FROM task tk JOIN `user` u8 ON u8.id = tk.owner_user_id
   WHERE tk.entity_type = 'OPP' AND tk.entity_id = p_id
   ORDER BY tk.status = 'OPEN' DESC, tk.due_at;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V022', 'Partners on deals, competitors, partner commercial versions; sp_opportunity_get edit ids', UTC_TIMESTAMP());
