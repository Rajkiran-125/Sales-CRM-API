-- =============================================================================
-- V017  Sales CRM - contacts & opportunity DMU, write side              (2026-10-13)
--
--   sp_contact_create        Add a contact to an account (or partner).
--   sp_contact_update        Edit a contact's details.
--   sp_contact_deactivate    Soft-delete a contact (is_active = 0).
--
--   sp_opportunity_dmu_upsert  Add or update a contact's DMU role on a deal.
--                              Idempotent on (opportunity_id, contact_id, dmu_role).
--   sp_opportunity_dmu_remove  Remove a DMU entry from a deal.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V016.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_contact_create
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_contact_create $$
CREATE PROCEDURE sp_contact_create(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_account_id     BIGINT UNSIGNED,  -- nullable; exactly one of account/partner
  IN p_partner_id     BIGINT UNSIGNED,  -- nullable
  IN p_name           VARCHAR(150),
  IN p_designation    VARCHAR(100),     -- nullable
  IN p_department     VARCHAR(100),     -- nullable
  IN p_email          VARCHAR(150),     -- nullable
  IN p_phone          VARCHAR(20),      -- nullable
  IN p_seniority      VARCHAR(40),      -- nullable
  IN p_influence_level TINYINT UNSIGNED, -- nullable, 1-5
  IN p_stand          VARCHAR(10),
  IN p_intel_notes    TEXT,             -- nullable
  IN p_spoc_type      VARCHAR(12)       -- nullable; partner contacts only
)
BEGIN
  DECLARE v_contact_id BIGINT UNSIGNED;

  -- ---- exactly one parent ----
  IF (p_account_id IS NULL) = (p_partner_id IS NULL) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|accountId|Exactly one of accountId or partnerId is required.';
  END IF;

  -- ---- validate parent exists ----
  IF p_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM account WHERE id = p_account_id AND is_active = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|accountId|Account not found.';
  END IF;

  IF p_partner_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM partner WHERE id = p_partner_id AND is_active = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|partnerId|Partner not found.';
  END IF;

  -- ---- validate enums ----
  IF p_stand NOT IN ('CHAMPION','NEUTRAL','BLOCKER','UNKNOWN') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|stand|Invalid stand value.';
  END IF;

  IF p_influence_level IS NOT NULL AND (p_influence_level < 1 OR p_influence_level > 5) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|influenceLevel|Must be between 1 and 5.';
  END IF;

  IF p_spoc_type IS NOT NULL AND
     p_spoc_type NOT IN ('TOP_MGMT','DMU','TECH','FINANCE','LEGAL','COMMERCIAL') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|spocType|Invalid SPOC type.';
  END IF;

  INSERT INTO contact (
    account_id, partner_id, name, designation, department,
    email, phone, seniority, influence_level, stand,
    intel_notes, spoc_type, is_active,
    created_at, created_by
  ) VALUES (
    p_account_id, p_partner_id, p_name, p_designation, p_department,
    p_email, p_phone, p_seniority, p_influence_level, p_stand,
    p_intel_notes, p_spoc_type, 1,
    UTC_TIMESTAMP(3), p_actor_user_id
  );
  SET v_contact_id = LAST_INSERT_ID();

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('contact', v_contact_id, 'CONTACT_CREATE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT v_contact_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_contact_update
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_contact_update $$
CREATE PROCEDURE sp_contact_update(
  IN p_actor_user_id   BIGINT UNSIGNED,
  IN p_request_id      VARCHAR(36),
  IN p_ip              VARCHAR(45),
  IN p_contact_id      BIGINT UNSIGNED,
  IN p_name            VARCHAR(150),
  IN p_designation     VARCHAR(100),
  IN p_department      VARCHAR(100),
  IN p_email           VARCHAR(150),
  IN p_phone           VARCHAR(20),
  IN p_seniority       VARCHAR(40),
  IN p_influence_level TINYINT UNSIGNED,
  IN p_stand           VARCHAR(10),
  IN p_intel_notes     TEXT,
  IN p_spoc_type       VARCHAR(12)
)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM contact WHERE id = p_contact_id AND is_active = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|id|Contact not found.';
  END IF;

  IF p_stand NOT IN ('CHAMPION','NEUTRAL','BLOCKER','UNKNOWN') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|stand|Invalid stand value.';
  END IF;

  IF p_influence_level IS NOT NULL AND (p_influence_level < 1 OR p_influence_level > 5) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|influenceLevel|Must be between 1 and 5.';
  END IF;

  IF p_spoc_type IS NOT NULL AND
     p_spoc_type NOT IN ('TOP_MGMT','DMU','TECH','FINANCE','LEGAL','COMMERCIAL') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|spocType|Invalid SPOC type.';
  END IF;

  UPDATE contact SET
    name           = p_name,
    designation    = p_designation,
    department     = p_department,
    email          = p_email,
    phone          = p_phone,
    seniority      = p_seniority,
    influence_level = p_influence_level,
    stand          = p_stand,
    intel_notes    = p_intel_notes,
    spoc_type      = p_spoc_type,
    updated_at     = UTC_TIMESTAMP(3),
    updated_by     = p_actor_user_id
  WHERE id = p_contact_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('contact', p_contact_id, 'CONTACT_UPDATE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT p_contact_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_contact_deactivate
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_contact_deactivate $$
CREATE PROCEDURE sp_contact_deactivate(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_contact_id     BIGINT UNSIGNED
)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM contact WHERE id = p_contact_id AND is_active = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|id|Contact not found.';
  END IF;

  UPDATE contact SET
    is_active  = 0,
    updated_at = UTC_TIMESTAMP(3),
    updated_by = p_actor_user_id
  WHERE id = p_contact_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('contact', p_contact_id, 'CONTACT_DEACTIVATE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT p_contact_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_dmu_upsert
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_dmu_upsert $$
CREATE PROCEDURE sp_opportunity_dmu_upsert(
  IN p_actor_user_id   BIGINT UNSIGNED,
  IN p_request_id      VARCHAR(36),
  IN p_ip              VARCHAR(45),
  IN p_opportunity_id  BIGINT UNSIGNED,
  IN p_contact_id      BIGINT UNSIGNED,
  IN p_dmu_role        VARCHAR(15),
  IN p_influence_level TINYINT UNSIGNED,  -- nullable
  IN p_stand           VARCHAR(10),
  IN p_notes           VARCHAR(1000),     -- nullable
  IN p_allow_any       TINYINT(1)
)
BEGIN
  DECLARE v_opp_owner     BIGINT UNSIGNED;
  DECLARE v_opp_account   BIGINT UNSIGNED;
  DECLARE v_contact_acct  BIGINT UNSIGNED;
  DECLARE v_dmu_id        BIGINT UNSIGNED;
  DECLARE v_action        VARCHAR(30);

  -- ---- verify opportunity ----
  SELECT owner_user_id, account_id
    INTO v_opp_owner, v_opp_account
    FROM opportunity WHERE id = p_opportunity_id AND is_active = 1;

  IF v_opp_owner IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|opportunityId|Opportunity not found.';
  END IF;

  IF p_allow_any = 0 AND v_opp_owner <> p_actor_user_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN|opportunityId|You can only manage DMU on your own deals.';
  END IF;

  -- ---- validate enums ----
  IF p_dmu_role NOT IN ('TECH_BUYER','COMM_BUYER','INFLUENCER_INT','INFLUENCER_EXT','SPONSOR') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|dmuRole|Invalid DMU role.';
  END IF;

  IF p_stand NOT IN ('CHAMPION','NEUTRAL','BLOCKER','UNKNOWN') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|stand|Invalid stand value.';
  END IF;

  IF p_influence_level IS NOT NULL AND (p_influence_level < 1 OR p_influence_level > 5) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|influenceLevel|Must be between 1 and 5.';
  END IF;

  -- ---- verify contact belongs to the opportunity's account ----
  SELECT account_id INTO v_contact_acct
    FROM contact WHERE id = p_contact_id AND is_active = 1;

  IF v_contact_acct IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|contactId|Contact not found.';
  END IF;

  IF v_contact_acct <> v_opp_account THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'UNPROCESSABLE|contactId|Contact does not belong to this deal''s account.';
  END IF;

  -- ---- upsert ----
  SELECT id INTO v_dmu_id
    FROM opportunity_dmu
   WHERE opportunity_id = p_opportunity_id AND contact_id = p_contact_id AND dmu_role = p_dmu_role;

  IF v_dmu_id IS NULL THEN
    INSERT INTO opportunity_dmu (
      opportunity_id, contact_id, dmu_role, influence_level, stand, notes,
      created_at, created_by
    ) VALUES (
      p_opportunity_id, p_contact_id, p_dmu_role, p_influence_level, p_stand, p_notes,
      UTC_TIMESTAMP(3), p_actor_user_id
    );
    SET v_dmu_id = LAST_INSERT_ID();
    SET v_action = 'OPPORTUNITY_DMU_ADD';
  ELSE
    UPDATE opportunity_dmu SET
      influence_level = p_influence_level,
      stand           = p_stand,
      notes           = p_notes,
      updated_at      = UTC_TIMESTAMP(3),
      updated_by      = p_actor_user_id
    WHERE id = v_dmu_id;
    SET v_action = 'OPPORTUNITY_DMU_UPDATE';
  END IF;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opportunity_id, v_action, NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT v_dmu_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- sp_opportunity_dmu_remove
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_opportunity_dmu_remove $$
CREATE PROCEDURE sp_opportunity_dmu_remove(
  IN p_actor_user_id   BIGINT UNSIGNED,
  IN p_request_id      VARCHAR(36),
  IN p_ip              VARCHAR(45),
  IN p_dmu_id          BIGINT UNSIGNED,
  IN p_opportunity_id  BIGINT UNSIGNED,
  IN p_allow_any       TINYINT(1)
)
BEGIN
  DECLARE v_opp_owner BIGINT UNSIGNED;

  -- ---- verify opportunity ----
  SELECT owner_user_id INTO v_opp_owner
    FROM opportunity WHERE id = p_opportunity_id AND is_active = 1;

  IF v_opp_owner IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|opportunityId|Opportunity not found.';
  END IF;

  IF p_allow_any = 0 AND v_opp_owner <> p_actor_user_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN|opportunityId|You can only manage DMU on your own deals.';
  END IF;

  -- ---- verify dmu row belongs to the opportunity ----
  IF NOT EXISTS (SELECT 1 FROM opportunity_dmu WHERE id = p_dmu_id AND opportunity_id = p_opportunity_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND|id|DMU entry not found.';
  END IF;

  DELETE FROM opportunity_dmu WHERE id = p_dmu_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('opportunity', p_opportunity_id, 'OPPORTUNITY_DMU_REMOVE', NULL, p_actor_user_id, p_ip, p_request_id);

  SELECT p_dmu_id AS id;
END $$

DELIMITER ;
