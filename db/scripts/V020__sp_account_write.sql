-- =============================================================================
-- V020  Sales CRM - accounts, write side                              (2026-10-14)
--
--   spi_account_dup_check  BR-AC-02: duplicate warning by name / GST / website.
--   sp_account_create      Create an account (ACC-0001 ...), owner + backup (BR-AC-01).
--   sp_account_update      Edit an account; owner changes are kept in audit_log (BR-AC-01).
--   sp_account_get         Re-issue of V008 adding ownerUserId, backupOwnerUserId,
--                          industryId, panNo and rowVersion for the edit form.
--
-- Rights: create needs account.create (route). Owner / backup may be set to the actor
-- or anyone in the actor's reporting tree; ALL-scope users (p_allow_any = 1) may pick
-- any active user. Update: the owner, the backup, a manager of either, or ALL scope.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V019.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- spi_account_dup_check: raise DUPLICATE when another active account has the
-- same name, GST number or website (scheme, www. and trailing / ignored).
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_account_dup_check $$
CREATE PROCEDURE spi_account_dup_check(
  IN p_exclude_id BIGINT UNSIGNED,
  IN p_name       VARCHAR(200),
  IN p_gst_no     VARCHAR(15),
  IN p_website    VARCHAR(255)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_no    VARCHAR(20) DEFAULT NULL;
  DECLARE v_field VARCHAR(20);
  DECLARE v_site  VARCHAR(255) DEFAULT
    NULLIF(REGEXP_REPLACE(LOWER(TRIM(IFNULL(p_website, ''))), '^(https?://)?(www\\.)?|/+$', ''), '');

  SELECT a.account_no,
         CASE WHEN a.name = TRIM(p_name) THEN 'name'
              WHEN p_gst_no IS NOT NULL AND a.gst_no = p_gst_no THEN 'gstNo'
              ELSE 'website' END
    INTO v_no, v_field
    FROM account a
   WHERE a.is_active = 1
     AND a.id <> IFNULL(p_exclude_id, 0)
     AND (a.name = TRIM(p_name)
          OR (p_gst_no IS NOT NULL AND a.gst_no = p_gst_no)
          OR (v_site IS NOT NULL AND
              REGEXP_REPLACE(LOWER(TRIM(IFNULL(a.website, ''))), '^(https?://)?(www\\.)?|/+$', '') = v_site))
   ORDER BY a.id
   LIMIT 1;

  IF v_no IS NOT NULL THEN
    CALL spi_raise('DUPLICATE', CONCAT('Possible duplicate of account ', v_no, '. Save anyway to keep both.'), v_field);
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- spi_account_check_people: validate industry, type, owner and backup.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_account_check_people $$
CREATE PROCEDURE spi_account_check_people(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_industry_id   BIGINT UNSIGNED,
  IN p_account_type  VARCHAR(12),
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_backup_user_id BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  IF p_industry_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM industry WHERE id = p_industry_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active industry.', 'industryId');
  END IF;
  IF p_account_type NOT IN ('PROSPECT','CUSTOMER','STRATEGIC','DORMANT') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid account type.', 'accountType');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_owner_user_id AND status = 'ACTIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'The owner must be an active user.', 'ownerUserId');
  END IF;
  IF p_allow_any = 0 AND NOT EXISTS (SELECT 1 FROM user_hierarchy
       WHERE ancestor_user_id = p_actor_user_id AND descendant_user_id = p_owner_user_id) THEN
    CALL spi_raise('FORBIDDEN', 'The owner must be you or someone in your team.', 'ownerUserId');
  END IF;
  IF p_backup_user_id IS NOT NULL THEN
    IF p_backup_user_id = p_owner_user_id THEN
      CALL spi_raise('VALIDATION_FAILED', 'The backup owner must differ from the owner.', 'backupOwnerUserId');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_backup_user_id AND status = 'ACTIVE') THEN
      CALL spi_raise('VALIDATION_FAILED', 'The backup owner must be an active user.', 'backupOwnerUserId');
    END IF;
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- sp_account_create
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_account_create $$
CREATE PROCEDURE sp_account_create(
  IN p_actor_user_id     BIGINT UNSIGNED,
  IN p_request_id        VARCHAR(36),
  IN p_ip                VARCHAR(45),
  IN p_name              VARCHAR(200),
  IN p_legal_name        VARCHAR(250),
  IN p_industry_id       BIGINT UNSIGNED,
  IN p_segment           VARCHAR(60),
  IN p_account_type      VARCHAR(12),
  IN p_is_strategic      TINYINT(1),
  IN p_country           VARCHAR(80),
  IN p_state             VARCHAR(80),
  IN p_city              VARCHAR(100),
  IN p_address           VARCHAR(500),
  IN p_website           VARCHAR(255),
  IN p_gst_no            VARCHAR(15),
  IN p_pan_no            VARCHAR(10),
  IN p_locations_count   INT UNSIGNED,
  IN p_existing_vendor   VARCHAR(200),
  IN p_owner_user_id     BIGINT UNSIGNED,
  IN p_backup_user_id    BIGINT UNSIGNED,
  IN p_notes             TEXT,
  IN p_ignore_duplicates TINYINT(1),
  IN p_allow_any         TINYINT(1)
)
  SQL SECURITY DEFINER
  COMMENT 'Create an account (12.6, BR-AC-01/02)'
BEGIN
  DECLARE v_no VARCHAR(20);
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_account_check_people(p_actor_user_id, p_industry_id, p_account_type,
                                p_owner_user_id, p_backup_user_id, p_allow_any);
  IF p_ignore_duplicates = 0 THEN
    CALL spi_account_dup_check(NULL, p_name, p_gst_no, p_website);
  END IF;

  START TRANSACTION;
  CALL spi_next_number('ACC', 0, v_no);

  INSERT INTO account (
    account_no, name, legal_name, industry_id, segment, account_type, is_strategic,
    country, state, city, address, website, gst_no, pan_no, locations_count,
    existing_vendor, owner_user_id, backup_owner_user_id, notes, created_at, created_by
  ) VALUES (
    v_no, TRIM(p_name), p_legal_name, p_industry_id, p_segment, p_account_type, p_is_strategic,
    IFNULL(p_country, 'India'), p_state, p_city, p_address, p_website, p_gst_no, p_pan_no, p_locations_count,
    p_existing_vendor, p_owner_user_id, p_backup_user_id, p_notes, UTC_TIMESTAMP(3), p_actor_user_id
  );
  SET v_id = LAST_INSERT_ID();

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('account', v_id, 'ACCOUNT_CREATE',
          JSON_OBJECT('ownerUserId', JSON_OBJECT('to', p_owner_user_id),
                      'backupOwnerUserId', JSON_OBJECT('to', p_backup_user_id),
                      'duplicateOverride', p_ignore_duplicates = 1),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id, v_no AS accountNo;
END $$

-- ---------------------------------------------------------------------------
-- sp_account_update  (optimistic lock on row_version)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_account_update $$
CREATE PROCEDURE sp_account_update(
  IN p_actor_user_id     BIGINT UNSIGNED,
  IN p_request_id        VARCHAR(36),
  IN p_ip                VARCHAR(45),
  IN p_id                BIGINT UNSIGNED,
  IN p_row_version       INT UNSIGNED,
  IN p_name              VARCHAR(200),
  IN p_legal_name        VARCHAR(250),
  IN p_industry_id       BIGINT UNSIGNED,
  IN p_segment           VARCHAR(60),
  IN p_account_type      VARCHAR(12),
  IN p_is_strategic      TINYINT(1),
  IN p_country           VARCHAR(80),
  IN p_state             VARCHAR(80),
  IN p_city              VARCHAR(100),
  IN p_address           VARCHAR(500),
  IN p_website           VARCHAR(255),
  IN p_gst_no            VARCHAR(15),
  IN p_pan_no            VARCHAR(10),
  IN p_locations_count   INT UNSIGNED,
  IN p_existing_vendor   VARCHAR(200),
  IN p_owner_user_id     BIGINT UNSIGNED,
  IN p_backup_user_id    BIGINT UNSIGNED,
  IN p_notes             TEXT,
  IN p_ignore_duplicates TINYINT(1),
  IN p_allow_any         TINYINT(1)
)
  SQL SECURITY DEFINER
  COMMENT 'Edit an account (12.6, BR-AC-01/02)'
BEGIN
  DECLARE v_owner   BIGINT UNSIGNED;
  DECLARE v_backup  BIGINT UNSIGNED;
  DECLARE v_version INT UNSIGNED;
  DECLARE v_name    VARCHAR(200);
  DECLARE v_type    VARCHAR(12);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT owner_user_id, backup_owner_user_id, row_version, name, account_type
    INTO v_owner, v_backup, v_version, v_name, v_type
    FROM account WHERE id = p_id AND is_active = 1;

  IF v_owner IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Account not found.', 'id');
  END IF;
  IF p_allow_any = 0 AND NOT EXISTS (SELECT 1 FROM user_hierarchy
       WHERE ancestor_user_id = p_actor_user_id AND descendant_user_id IN (v_owner, IFNULL(v_backup, 0))) THEN
    CALL spi_raise('FORBIDDEN', 'Only the owner, the backup owner or their manager can edit this account.', 'id');
  END IF;
  IF v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'Someone else changed this account. Reload and try again.', 'rowVersion');
  END IF;

  SET p_owner_user_id = IFNULL(p_owner_user_id, v_owner);
  -- keeping the current owner is always allowed, even outside the actor's tree
  CALL spi_account_check_people(p_actor_user_id, p_industry_id, p_account_type,
                                p_owner_user_id, p_backup_user_id,
                                IF(p_owner_user_id = v_owner, 1, p_allow_any));
  IF p_ignore_duplicates = 0 THEN
    CALL spi_account_dup_check(p_id, p_name, p_gst_no, p_website);
  END IF;

  START TRANSACTION;
  UPDATE account SET
    name                 = TRIM(p_name),
    legal_name           = p_legal_name,
    industry_id          = p_industry_id,
    segment              = p_segment,
    account_type         = p_account_type,
    is_strategic         = p_is_strategic,
    country              = IFNULL(p_country, 'India'),
    state                = p_state,
    city                 = p_city,
    address              = p_address,
    website              = p_website,
    gst_no               = p_gst_no,
    pan_no               = p_pan_no,
    locations_count      = p_locations_count,
    existing_vendor      = p_existing_vendor,
    owner_user_id        = p_owner_user_id,
    backup_owner_user_id = p_backup_user_id,
    notes                = p_notes,
    updated_at           = UTC_TIMESTAMP(3),
    updated_by           = p_actor_user_id,
    row_version          = row_version + 1
  WHERE id = p_id;

  -- BR-AC-01: owner / backup history lives in the audit log
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('account', p_id, 'ACCOUNT_UPDATE',
          JSON_OBJECT('name', JSON_OBJECT('from', v_name, 'to', TRIM(p_name)),
                      'accountType', JSON_OBJECT('from', v_type, 'to', p_account_type),
                      'ownerUserId', JSON_OBJECT('from', v_owner, 'to', p_owner_user_id),
                      'backupOwnerUserId', JSON_OBJECT('from', v_backup, 'to', p_backup_user_id),
                      'duplicateOverride', p_ignore_duplicates = 1),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT p_id AS id, v_version + 1 AS rowVersion;
END $$

-- ---------------------------------------------------------------------------
-- sp_account_get: V008 + the fields the edit form needs
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_account_get $$
CREATE PROCEDURE sp_account_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Account 360, read side (12.6)'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;

  CALL spi_visible_accounts(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_acc WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  IF v_visible = 0 THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
    CALL spi_raise('NOT_FOUND', 'Account not found.', 'id');
  END IF;

  -- the visible deals of this account
  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
  CREATE TEMPORARY TABLE tmp_rows (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  INSERT INTO tmp_rows (id)
  SELECT o.id FROM opportunity o JOIN tmp_dash_opp t ON t.id = o.id WHERE o.account_id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;

  SELECT a.id, a.account_no AS accountNo, a.name, a.legal_name AS legalName, i.name AS industryName,
         a.segment, a.account_type AS accountType, a.is_strategic AS isStrategic, a.country, a.state,
         a.city, a.address, a.website, a.gst_no AS gstNo, a.locations_count AS locationsCount,
         a.existing_vendor AS existingVendor, u.full_name AS ownerName, b.full_name AS backupOwnerName,
         a.first_won_on AS firstWonOn, a.notes, a.created_at AS createdAt,
         a.owner_user_id AS ownerUserId, a.backup_owner_user_id AS backupOwnerUserId,
         a.industry_id AS industryId, a.pan_no AS panNo, a.row_version AS rowVersion
    FROM account a
    JOIN `user` u ON u.id = a.owner_user_id
    LEFT JOIN `user` b ON b.id = a.backup_owner_user_id
    LEFT JOIN industry i ON i.id = a.industry_id
   WHERE a.id = p_id;

  SELECT CAST(IFNULL(SUM(s.is_open = 1), 0) AS SIGNED) AS openDeals,
         CAST(IFNULL(SUM(IF(s.is_open = 1, o.expected_value * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS openPipeline,
         CAST(IFNULL(SUM(IF(s.is_open = 1, o.weighted_value, 0)), 0) AS DECIMAL(18,2)) AS weightedPipeline,
         CAST(IFNULL(SUM(o.stage_code = 'WON'), 0) AS SIGNED) AS wonDeals,
         CAST(IFNULL(SUM(IF(o.stage_code = 'WON', COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate, 0)), 0) AS DECIMAL(18,2)) AS wonLifetime,
         CAST(IFNULL(SUM(o.stage_code = 'LOST'), 0) AS SIGNED) AS lostDeals,
         MAX(IF(o.stage_code = 'WON', DATE(o.closed_at + INTERVAL 330 MINUTE), NULL)) AS lastWonOn
    FROM opportunity o
    JOIN tmp_rows r ON r.id = o.id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code;

  SELECT c.id, c.name, c.designation, c.department, c.email, c.phone, c.seniority,
         c.influence_level AS influenceLevel, c.stand, c.intel_notes AS intelNotes
    FROM contact c WHERE c.account_id = p_id AND c.is_active = 1
   ORDER BY c.influence_level IS NULL, c.influence_level DESC, c.name;

  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, o.stage_code AS stageCode, s.name AS stageName,
         s.is_open AS isOpen, u.full_name AS ownerName, o.source,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(o.weighted_value AS DECIMAL(18,2)) AS weighted,
         CAST(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate AS DECIMAL(18,2)) AS closedValue,
         o.expected_close_date AS expectedCloseDate, o.closed_at AS closedAt, o.health
    FROM opportunity o
    JOIN tmp_rows r ON r.id = o.id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   ORDER BY s.is_open DESC, s.sequence_no DESC, o.expected_close_date;

  SELECT so.id, so.order_no AS orderNo, o.opportunity_no AS opportunityNo, o.title, so.po_number AS poNumber,
         so.po_date AS poDate, CAST(so.po_value AS DECIMAL(18,2)) AS poValue, so.status,
         CAST(so.invoiced_value AS DECIMAL(18,2)) AS invoicedValue,
         CAST(so.received_value AS DECIMAL(18,2)) AS receivedValue
    FROM sales_order so
    JOIN tmp_rows r ON r.id = so.opportunity_id
    JOIN opportunity o ON o.id = so.opportunity_id
   ORDER BY so.po_date DESC;

  SELECT p.id AS partnerId, COALESCE(p.short_name, p.legal_name) AS partnerName, p.tier,
         GROUP_CONCAT(DISTINCT op.partner_role ORDER BY op.partner_role SEPARATOR ', ') AS roles,
         CAST(COUNT(DISTINCT op.opportunity_id) AS SIGNED) AS deals
    FROM opportunity_partner op
    JOIN tmp_rows r ON r.id = op.opportunity_id
    JOIN partner p ON p.id = op.partner_id
   GROUP BY p.id, p.short_name, p.legal_name, p.tier
   ORDER BY deals DESC, partnerName;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject, ac.notes,
         ac.outcome, ac.people_met AS peopleMet, u.full_name AS byName,
         o.opportunity_no AS opportunityNo, o.title AS opportunityTitle
    FROM activity ac
    JOIN `user` u ON u.id = ac.by_user_id
    LEFT JOIN opportunity o ON o.id = ac.opportunity_id
   WHERE ac.is_active = 1
     AND (ac.account_id = p_id OR (ac.entity_type = 'ACCOUNT' AND ac.entity_id = p_id))
     AND (ac.opportunity_id IS NULL OR ac.opportunity_id IN (SELECT id FROM tmp_rows))
   ORDER BY ac.activity_at DESC, ac.id DESC
   LIMIT 50;

  DROP TEMPORARY TABLE IF EXISTS tmp_rows;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V020', 'Account write side: create, update, duplicate check; sp_account_get edit fields', UTC_TIMESTAMP());
