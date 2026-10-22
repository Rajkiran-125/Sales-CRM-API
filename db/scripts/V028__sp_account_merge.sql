-- =============================================================================
-- V028  Sales CRM - merge duplicate accounts                           (2026-10-14)
--
--   sp_account_merge   POST /accounts/{id}/merge (12.6, account.merge): move everything
--                      of account {id} onto the survivor, then retire {id}
--                      (is_active = 0, merged_into_account_id = survivor). The survivor's
--                      own field values win; it takes the earlier new-logo date and a
--                      non-prospect account type from the merged account. Rows that would
--                      break a unique key on the survivor (partner account map per period,
--                      custom field values) stay on the retired account. Audited on both.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V027.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_account_merge $$
CREATE PROCEDURE sp_account_merge(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,   -- merged away
  IN p_survivor_id   BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible   INT;
  DECLARE v_contacts  INT DEFAULT 0;
  DECLARE v_leads     INT DEFAULT 0;
  DECLARE v_opps      INT DEFAULT 0;
  DECLARE v_orders    INT DEFAULT 0;
  DECLARE v_docs      INT DEFAULT 0;
  DECLARE v_acts      INT DEFAULT 0;
  DECLARE v_counts    JSON;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_id = p_survivor_id THEN
    CALL spi_raise('VALIDATION_FAILED', 'An account cannot be merged into itself.', 'survivorAccountId');
  END IF;

  CALL spi_visible_accounts(p_actor_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_acc WHERE id = p_id;
  IF v_visible = 0 THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
    CALL spi_raise('NOT_FOUND', 'Account not found or not visible to you.', 'id');
  END IF;
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_acc WHERE id = p_survivor_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  IF v_visible = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'The surviving account was not found or is not visible to you.', 'survivorAccountId');
  END IF;

  START TRANSACTION;
  -- lock both rows so a concurrent edit or merge waits for this one
  SELECT COUNT(*) INTO v_visible FROM account WHERE id IN (p_id, p_survivor_id) FOR UPDATE;

  UPDATE contact SET account_id = p_survivor_id WHERE account_id = p_id;
  SET v_contacts = ROW_COUNT();
  UPDATE sales_lead SET account_id = p_survivor_id WHERE account_id = p_id;
  SET v_leads = ROW_COUNT();
  UPDATE opportunity SET account_id = p_survivor_id WHERE account_id = p_id;
  SET v_opps = ROW_COUNT();
  UPDATE sales_order SET account_id = p_survivor_id WHERE account_id = p_id;
  SET v_orders = ROW_COUNT();
  UPDATE tender SET account_id = p_survivor_id WHERE account_id = p_id;
  UPDATE partner_commercial SET account_id = p_survivor_id WHERE account_id = p_id;
  UPDATE partner_engagement SET account_id = p_survivor_id WHERE account_id = p_id;
  UPDATE partner_customer_code SET account_id = p_survivor_id WHERE account_id = p_id;
  UPDATE partner_account_map m SET m.account_id = p_survivor_id
   WHERE m.account_id = p_id
     AND NOT EXISTS (SELECT 1 FROM (SELECT partner_id, plan_period FROM partner_account_map
                                     WHERE account_id = p_survivor_id) s
                      WHERE s.partner_id = m.partner_id AND s.plan_period <=> m.plan_period);

  -- polymorphic parents: the record itself is the account
  UPDATE document SET account_id = p_survivor_id,
                      entity_id = IF(entity_type = 'ACCOUNT', p_survivor_id, entity_id)
   WHERE account_id = p_id OR (entity_type = 'ACCOUNT' AND entity_id = p_id);
  SET v_docs = ROW_COUNT();
  UPDATE activity SET account_id = p_survivor_id,
                      entity_id = IF(entity_type = 'ACCOUNT', p_survivor_id, entity_id)
   WHERE account_id = p_id OR (entity_type = 'ACCOUNT' AND entity_id = p_id);
  SET v_acts = ROW_COUNT();
  UPDATE task SET entity_id = p_survivor_id WHERE entity_type = 'ACCOUNT' AND entity_id = p_id;
  UPDATE custom_field_value v SET v.record_id = p_survivor_id
   WHERE v.entity = 'ACCOUNT' AND v.record_id = p_id
     AND NOT EXISTS (SELECT 1 FROM (SELECT field_id FROM custom_field_value
                                     WHERE entity = 'ACCOUNT' AND record_id = p_survivor_id) s
                      WHERE s.field_id = v.field_id);

  -- survivor keeps its values; the earlier new-logo date (BR-AC-03) and a non-prospect type carry over
  UPDATE account s JOIN account m ON m.id = p_id
     SET s.first_won_on = CASE WHEN s.first_won_on IS NULL THEN m.first_won_on
                               WHEN m.first_won_on IS NULL THEN s.first_won_on
                               ELSE LEAST(s.first_won_on, m.first_won_on) END,
         s.account_type = IF(s.account_type = 'PROSPECT', m.account_type, s.account_type),
         s.is_strategic = GREATEST(s.is_strategic, m.is_strategic),
         s.updated_at = UTC_TIMESTAMP(3), s.updated_by = p_actor_user_id,
         s.row_version = s.row_version + 1
   WHERE s.id = p_survivor_id;

  UPDATE account SET is_active = 0, merged_into_account_id = p_survivor_id,
                     updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id,
                     row_version = row_version + 1
   WHERE id = p_id;

  SET v_counts = JSON_OBJECT('contacts', v_contacts, 'leads', v_leads, 'opportunities', v_opps,
                             'orders', v_orders, 'documents', v_docs, 'activities', v_acts);
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('account', p_id, 'ACCOUNT_MERGE',
          JSON_OBJECT('mergedInto', p_survivor_id, 'moved', v_counts),
          p_actor_user_id, p_ip, p_request_id),
         ('account', p_survivor_id, 'ACCOUNT_MERGE',
          JSON_OBJECT('mergedFrom', p_id, 'moved', v_counts),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT p_survivor_id AS id, v_counts AS moved;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V028', 'Merge duplicate accounts', UTC_TIMESTAMP());
