-- =============================================================================
-- V029  Sales CRM - edit a draft offer                                 (2026-10-14)
--
--   sp_offer_update   PATCH /offers/{id} (14.5): change the figures of a DRAFT offer
--                     (a new offer, or the draft a revise created). The approval flag is
--                     recomputed from the settings, as on create (OD-49). Sent, approved
--                     and superseded versions are never changed (revise instead).
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V028.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_offer_update $$
CREATE PROCEDURE sp_offer_update(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_offer_id       BIGINT UNSIGNED,
  IN p_offer_value    DECIMAL(16,2),
  IN p_list_value     DECIMAL(16,2),
  IN p_discount_pct   DECIMAL(5,2),
  IN p_value_adds     VARCHAR(2000),
  IN p_payment_terms  VARCHAR(500),
  IN p_valid_till     DATE,
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
  COMMENT 'Edit a DRAFT offer; recompute approval_required from settings'
BEGIN
  DECLARE v_status   VARCHAR(16);
  DECLARE v_owner    BIGINT UNSIGNED;
  DECLARE v_app_req  TINYINT DEFAULT 0;
  DECLARE v_disc_thr DECIMAL(16,2);
  DECLARE v_val_lim  DECIMAL(16,2);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT f.status, o.owner_user_id
    INTO v_status, v_owner
    FROM offer f
    JOIN opportunity o ON o.id = f.opportunity_id
   WHERE f.id = p_offer_id;

  IF v_status IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Offer not found.', 'id');
  END IF;
  IF v_status <> 'DRAFT' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Only DRAFT offers can be edited; revise the offer instead.', 'status');
  END IF;
  IF p_allow_any = 0 AND v_owner <> p_actor_user_id
     AND NOT EXISTS (
       SELECT 1 FROM user_hierarchy h
        WHERE h.ancestor_user_id = p_actor_user_id
          AND h.descendant_user_id = v_owner) THEN
    CALL spi_raise('FORBIDDEN', 'You can only edit offers on your own deals.', 'id');
  END IF;
  IF p_valid_till < UTC_DATE() THEN
    CALL spi_raise('VALIDATION_FAILED', 'Valid till must be today or a future date.', 'validTill');
  END IF;

  CALL spi_setting_decimal('offer.approval.discount_pct', 15, v_disc_thr);
  CALL spi_setting_decimal('offer.approval.value_limit',  10000000, v_val_lim);
  IF (p_discount_pct IS NOT NULL AND p_discount_pct > v_disc_thr) OR p_offer_value > v_val_lim THEN
    SET v_app_req = 1;
  END IF;

  START TRANSACTION;
  UPDATE offer
     SET offer_value = p_offer_value, list_value = p_list_value, discount_pct = p_discount_pct,
         value_adds = p_value_adds, payment_terms = p_payment_terms, valid_till = p_valid_till,
         approval_required = v_app_req,
         updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id,
         row_version = row_version + 1
   WHERE id = p_offer_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('offer', p_offer_id, 'OFFER_UPDATE',
          JSON_OBJECT('offerValue', p_offer_value, 'discountPct', p_discount_pct, 'validTill', p_valid_till),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT p_offer_id AS id, v_app_req AS approvalRequired;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V029', 'Edit a draft offer', UTC_TIMESTAMP());
