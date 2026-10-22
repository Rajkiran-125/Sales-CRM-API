-- =============================================================================
-- V023  Sales CRM - documents, write side                             (2026-10-14)
--
--   spi_document_parent   The parent record is visible to the user; resolves the
--                         denormalised lead / opportunity / account / partner ids.
--   spi_document_visible  One document has the visibility of its parent (as V010).
--   sp_document_limits    Upload limits from settings (size, count, extensions).
--   sp_document_create    Store file metadata + document + tags (BR-DC-01/02, 17.9).
--                         Same title on the same record = next version_no.
--   sp_document_file      Download lookup: storage key and name of a visible document.
--   sp_document_delete    Soft delete: the uploader, or ALL scope (V002 "admins: any").
--
-- Files live on disk under random keys (API FILE_DIR); this script holds metadata only.
-- No malware scanner yet (OD-18): file_object.scan_status = 'SKIPPED'.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V022.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- spi_document_parent
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_document_parent $$
CREATE PROCEDURE spi_document_parent(
  IN  p_user_id     BIGINT UNSIGNED,
  IN  p_entity_type VARCHAR(10),
  IN  p_entity_id   BIGINT UNSIGNED,
  OUT o_lead_id     BIGINT UNSIGNED,
  OUT o_opp_id      BIGINT UNSIGNED,
  OUT o_account_id  BIGINT UNSIGNED,
  OUT o_partner_id  BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;
  SET o_lead_id = NULL, o_opp_id = NULL, o_account_id = NULL, o_partner_id = NULL;

  CASE p_entity_type
    WHEN 'OPP' THEN
      CALL spi_visible_accounts(p_user_id);
      SELECT COUNT(*) INTO v_visible FROM tmp_dash_opp WHERE id = p_entity_id;
      SELECT id, account_id INTO o_opp_id, o_account_id FROM opportunity WHERE id = p_entity_id;
    WHEN 'ORDER' THEN
      CALL spi_visible_accounts(p_user_id);
      SELECT opportunity_id, account_id INTO o_opp_id, o_account_id FROM sales_order WHERE id = p_entity_id;
      SELECT COUNT(*) INTO v_visible FROM tmp_dash_opp WHERE id = o_opp_id;
    WHEN 'ACCOUNT' THEN
      CALL spi_visible_accounts(p_user_id);
      SELECT COUNT(*) INTO v_visible FROM tmp_vis_acc WHERE id = p_entity_id;
      SET o_account_id = p_entity_id;
    WHEN 'LEAD' THEN
      CALL spi_visible_leads(p_user_id);
      SELECT COUNT(*) INTO v_visible FROM tmp_vis_lead WHERE id = p_entity_id;
      SELECT id, account_id INTO o_lead_id, o_account_id FROM sales_lead WHERE id = p_entity_id;
    WHEN 'PARTNER' THEN
      CALL spi_visible_partners(p_user_id);
      SELECT COUNT(*) INTO v_visible FROM tmp_vis_ptr WHERE id = p_entity_id;
      SET o_partner_id = p_entity_id;
    WHEN 'TENDER' THEN
      CALL spi_visible_tenders(p_user_id);
      SELECT COUNT(*) INTO v_visible FROM tmp_vis_tender WHERE id = p_entity_id;
      SELECT account_id INTO o_account_id FROM tender WHERE id = p_entity_id;
    ELSE
      CALL spi_raise('VALIDATION_FAILED', 'Unknown record type.', 'entityType');
  END CASE;

  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_lead;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_tender;

  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'The record was not found or is not visible to you.', 'entityId');
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- spi_document_visible: same rule as sp_document_list (V010), for one document
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_document_visible $$
CREATE PROCEDURE spi_document_visible(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED, OUT o_visible TINYINT)
  SQL SECURITY DEFINER
BEGIN
  CALL spi_visible_tenders(p_user_id);
  CALL spi_visible_partners(p_user_id);
  CALL spi_visible_leads(p_user_id);
  CALL spi_visible_accounts(p_user_id);

  SELECT COUNT(*) INTO o_visible
    FROM document d
   WHERE d.id = p_id AND d.is_active = 1 AND d.deleted_at IS NULL
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
END $$

-- ---------------------------------------------------------------------------
-- sp_document_limits: upload limits from settings (BR-DC-02), so the API can check
-- every file of a request before it stores any of them
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_document_limits $$
CREATE PROCEDURE sp_document_limits()
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_max_mb  INT;
  DECLARE v_files   INT;
  DECLARE v_allowed VARCHAR(1000);
  CALL spi_setting_int('file.max_size_mb', 10, v_max_mb);
  CALL spi_setting_int('file.max_files_per_request', 10, v_files);
  CALL spi_setting_text('file.allowed_extensions', 'pdf,doc,docx,xls,xlsx,ppt,pptx,png,jpg,jpeg,zip', v_allowed);
  SELECT v_max_mb AS maxSizeMb, v_files AS maxFiles, REPLACE(v_allowed, ' ', '') AS allowedExtensions;
END $$

-- ---------------------------------------------------------------------------
-- sp_document_create
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_document_create $$
CREATE PROCEDURE sp_document_create(
  IN p_actor_user_id   BIGINT UNSIGNED,
  IN p_request_id      VARCHAR(36),
  IN p_ip              VARCHAR(45),
  IN p_entity_type     VARCHAR(10),
  IN p_entity_id       BIGINT UNSIGNED,
  IN p_type_code       VARCHAR(40),
  IN p_title           VARCHAR(250),
  IN p_original_name   VARCHAR(255),
  IN p_extension       VARCHAR(10),
  IN p_mime_type       VARCHAR(150),
  IN p_size_bytes      BIGINT UNSIGNED,
  IN p_checksum        CHAR(64),
  IN p_storage_key     VARCHAR(100),
  IN p_shared_with     VARCHAR(10),
  IN p_shared_partner  BIGINT UNSIGNED,
  IN p_shared_on       DATE,
  IN p_notes           VARCHAR(1000),
  IN p_tags            JSON             -- array of strings, may be NULL
)
  SQL SECURITY DEFINER
  COMMENT 'Attach an uploaded file to a record (12.13, BR-DC-01/02)'
BEGIN
  DECLARE v_lead     BIGINT UNSIGNED;
  DECLARE v_opp      BIGINT UNSIGNED;
  DECLARE v_account  BIGINT UNSIGNED;
  DECLARE v_partner  BIGINT UNSIGNED;
  DECLARE v_type_id  BIGINT UNSIGNED;
  DECLARE v_max_mb   INT;
  DECLARE v_allowed  VARCHAR(1000);
  DECLARE v_version  INT UNSIGNED;
  DECLARE v_file_id  BIGINT UNSIGNED;
  DECLARE v_doc_id   BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_document_parent(p_actor_user_id, p_entity_type, p_entity_id, v_lead, v_opp, v_account, v_partner);

  -- BR-DC-02: limits from settings (17.9)
  CALL spi_setting_int('file.max_size_mb', 10, v_max_mb);
  CALL spi_setting_text('file.allowed_extensions', 'pdf,doc,docx,xls,xlsx,ppt,pptx,png,jpg,jpeg,zip', v_allowed);
  IF p_size_bytes > v_max_mb * 1048576 THEN
    CALL spi_raise('FILE_TOO_LARGE', CONCAT('A file may be at most ', v_max_mb, ' MB.'), 'files');
  END IF;
  IF FIND_IN_SET(LOWER(p_extension), REPLACE(v_allowed, ' ', '')) = 0 THEN
    CALL spi_raise('UNSUPPORTED_FILE_TYPE', CONCAT('Allowed file types: ', v_allowed, '.'), 'files');
  END IF;

  SELECT id INTO v_type_id FROM document_type WHERE code = p_type_code AND is_active = 1;
  IF v_type_id IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose a document type.', 'documentTypeCode');
  END IF;
  IF p_shared_with NOT IN ('CUSTOMER','PARTNER','INTERNAL') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Invalid "shared with" value.', 'sharedWith');
  END IF;
  IF p_shared_with = 'PARTNER' AND (p_shared_partner IS NULL OR
       NOT EXISTS (SELECT 1 FROM partner WHERE id = p_shared_partner AND is_active = 1)) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the partner the document was shared with.', 'sharedWithPartnerId');
  END IF;

  START TRANSACTION;
  INSERT INTO file_object (storage_key, original_name, mime_type, size_bytes, checksum_sha256, scan_status, uploaded_by)
  VALUES (p_storage_key, p_original_name, p_mime_type, p_size_bytes, p_checksum, 'SKIPPED', p_actor_user_id);
  SET v_file_id = LAST_INSERT_ID();

  SELECT IFNULL(MAX(version_no), 0) + 1 INTO v_version
    FROM document
   WHERE entity_type = p_entity_type AND entity_id = p_entity_id AND title = TRIM(p_title) AND is_active = 1;

  INSERT INTO document (entity_type, entity_id, lead_id, opportunity_id, account_id, partner_id, file_object_id,
                        title, document_type_id, shared_with, shared_with_partner_id, shared_on, shared_by,
                        version_no, notes, created_at, created_by)
  VALUES (p_entity_type, p_entity_id, v_lead, v_opp, v_account, v_partner, v_file_id,
          TRIM(p_title), v_type_id, p_shared_with, IF(p_shared_with = 'PARTNER', p_shared_partner, NULL),
          p_shared_on, IF(p_shared_with = 'INTERNAL', NULL, p_actor_user_id),
          v_version, p_notes, UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_doc_id = LAST_INSERT_ID();

  IF p_tags IS NOT NULL THEN
    INSERT IGNORE INTO document_tag (document_id, tag)
    SELECT v_doc_id, LOWER(TRIM(j.tag))
      FROM JSON_TABLE(p_tags, '$[*]' COLUMNS (tag VARCHAR(60) PATH '$')) j
     WHERE TRIM(IFNULL(j.tag, '')) <> '';
  END IF;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('document', v_doc_id, 'DOCUMENT_UPLOAD',
          JSON_OBJECT('entityType', p_entity_type, 'entityId', p_entity_id, 'fileName', p_original_name,
                      'sizeBytes', p_size_bytes, 'versionNo', v_version),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_doc_id AS id, v_version AS versionNo;
END $$

-- ---------------------------------------------------------------------------
-- sp_document_file: what the download endpoint streams
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_document_file $$
CREATE PROCEDURE sp_document_file(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible TINYINT;
  CALL spi_document_visible(p_user_id, p_id, v_visible);
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Document not found or not visible to you.', 'id');
  END IF;

  SELECT f.storage_key AS storageKey, f.original_name AS originalName, f.mime_type AS mimeType,
         f.size_bytes AS sizeBytes, f.scan_status AS scanStatus
    FROM document d JOIN file_object f ON f.id = d.file_object_id
   WHERE d.id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- sp_document_delete: soft delete; the file stays on disk for audit / restore
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_document_delete $$
CREATE PROCEDURE sp_document_delete(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible  TINYINT;
  DECLARE v_uploader BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_document_visible(p_actor_user_id, p_id, v_visible);
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Document not found or not visible to you.', 'id');
  END IF;
  SELECT created_by INTO v_uploader FROM document WHERE id = p_id;
  IF p_allow_any = 0 AND IFNULL(v_uploader, 0) <> p_actor_user_id THEN
    CALL spi_raise('FORBIDDEN', 'Only the uploader or an administrator can delete this document.', 'id');
  END IF;

  START TRANSACTION;
  UPDATE document SET is_active = 0, deleted_at = UTC_TIMESTAMP(3),
                      updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE id = p_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('document', p_id, 'DOCUMENT_DELETE', NULL, p_actor_user_id, p_ip, p_request_id);
  COMMIT;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V023', 'Document upload, download lookup, soft delete', UTC_TIMESTAMP());
