-- =============================================================================
-- V036  Sales CRM - data import batches (partners first)                (2026-10-14)
--
--   sp_import_lookups        partner types by code / name and active users by email.
--   sp_import_batch_create   POST /imports: store the uploaded file, the batch (PREVIEW) and
--                            every row with the API's validation (VALID / INVALID + errors):
--                            the preview is the dry run (12.17).
--   sp_import_batch_get      GET /imports/{id}: the batch and its rows.
--   sp_import_row_done       one committed row: CREATED (with the record and an IMPORTED audit
--                            entry carrying the batch and row number) or SKIPPED (duplicate).
--   sp_import_batch_finish   COMMITTED with the counts, or FAILED.
--
-- The API validates and creates the records (partners through sp_partner_create, V030), so the
-- rules are the same as in the screens. Re-runnable (DROP + CREATE). Prerequisite: V001-V035.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- sp_import_lookups: what the API needs to map partner rows (types by code or name, users by email)
DROP PROCEDURE IF EXISTS sp_import_lookups $$
CREATE PROCEDURE sp_import_lookups()
  SQL SECURITY DEFINER
BEGIN
  SELECT id, code, name FROM partner_type WHERE is_active = 1;
  SELECT id, LOWER(email) AS email, full_name AS fullName FROM `user` WHERE status = 'ACTIVE';
END $$

DROP PROCEDURE IF EXISTS sp_import_batch_create $$
CREATE PROCEDURE sp_import_batch_create(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_entity        VARCHAR(20),
  IN p_storage_key   VARCHAR(100),
  IN p_original_name VARCHAR(255),
  IN p_mime_type     VARCHAR(150),
  IN p_size_bytes    BIGINT UNSIGNED,
  IN p_checksum      CHAR(64),
  IN p_rows          JSON              -- [{rowNo, raw, mapped, status, errors}]
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_file  BIGINT UNSIGNED;
  DECLARE v_batch BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  INSERT INTO file_object (storage_key, original_name, mime_type, size_bytes, checksum_sha256, scan_status, uploaded_by)
  VALUES (p_storage_key, p_original_name, p_mime_type, p_size_bytes, p_checksum, 'SKIPPED', p_actor_user_id);
  SET v_file = LAST_INSERT_ID();

  INSERT INTO import_batch (entity, file_object_id, status, total_rows, error_count, created_by)
  SELECT p_entity, v_file, 'PREVIEW', COUNT(*), IFNULL(SUM(j.status = 'INVALID'), 0), p_actor_user_id
    FROM JSON_TABLE(p_rows, '$[*]' COLUMNS (status VARCHAR(10) PATH '$.status')) j;
  SET v_batch = LAST_INSERT_ID();

  INSERT INTO import_row (batch_id, row_no, raw_json, mapped_json, status, errors_json)
  SELECT v_batch, j.row_no, j.raw, j.mapped, j.status, j.errors
    FROM JSON_TABLE(p_rows, '$[*]' COLUMNS (
           row_no INT UNSIGNED PATH '$.rowNo',
           raw    JSON         PATH '$.raw',
           mapped JSON         PATH '$.mapped',
           status VARCHAR(10)  PATH '$.status',
           errors JSON         PATH '$.errors')) j;
  COMMIT;

  SELECT v_batch AS id;
END $$

DROP PROCEDURE IF EXISTS sp_import_batch_get $$
CREATE PROCEDURE sp_import_batch_get(IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  IF NOT EXISTS (SELECT 1 FROM import_batch WHERE id = p_id) THEN
    CALL spi_raise('NOT_FOUND', 'Import batch not found.', 'id');
  END IF;

  SELECT b.id, b.entity, b.status, b.total_rows AS totalRows, b.created_count AS createdCount,
         b.skipped_count AS skippedCount, b.error_count AS errorCount, f.original_name AS fileName,
         u.full_name AS createdByName, b.created_at AS createdAt, b.committed_at AS committedAt
    FROM import_batch b
    JOIN file_object f ON f.id = b.file_object_id
    LEFT JOIN `user` u ON u.id = b.created_by
   WHERE b.id = p_id;

  SELECT row_no AS rowNo, raw_json AS raw, mapped_json AS mapped, status, errors_json AS errors,
         created_entity_id AS createdEntityId
    FROM import_row WHERE batch_id = p_id ORDER BY row_no;
END $$

DROP PROCEDURE IF EXISTS sp_import_row_done $$
CREATE PROCEDURE sp_import_row_done(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_batch_id      BIGINT UNSIGNED,
  IN p_row_no        INT UNSIGNED,
  IN p_status        VARCHAR(10),       -- CREATED / SKIPPED / INVALID
  IN p_entity_id     BIGINT UNSIGNED,
  IN p_errors        JSON
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_entity VARCHAR(20);

  SELECT entity INTO v_entity FROM import_batch WHERE id = p_batch_id;
  UPDATE import_row
     SET status = p_status, created_entity_id = p_entity_id, errors_json = IFNULL(p_errors, errors_json)
   WHERE batch_id = p_batch_id AND row_no = p_row_no;
  IF p_status = 'CREATED' THEN
    INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
    VALUES (LOWER(v_entity), p_entity_id, 'IMPORTED',
            JSON_OBJECT('batchId', p_batch_id, 'rowNo', p_row_no),
            p_actor_user_id, p_ip, p_request_id);
  END IF;
END $$

DROP PROCEDURE IF EXISTS sp_import_batch_finish $$
CREATE PROCEDURE sp_import_batch_finish(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_batch_id      BIGINT UNSIGNED,
  IN p_status        VARCHAR(10)        -- COMMITTED / FAILED
)
  SQL SECURITY DEFINER
BEGIN
  UPDATE import_batch b
     SET b.status = p_status,
         b.created_count = (SELECT COUNT(*) FROM import_row r WHERE r.batch_id = b.id AND r.status = 'CREATED'),
         b.skipped_count = (SELECT COUNT(*) FROM import_row r WHERE r.batch_id = b.id AND r.status = 'SKIPPED'),
         b.error_count = (SELECT COUNT(*) FROM import_row r WHERE r.batch_id = b.id AND r.status = 'INVALID'),
         b.committed_by = p_actor_user_id, b.committed_at = UTC_TIMESTAMP(3),
         b.updated_at = UTC_TIMESTAMP(3), b.updated_by = p_actor_user_id
   WHERE b.id = p_batch_id;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V036', 'Data import batches (partners)', UTC_TIMESTAMP());
