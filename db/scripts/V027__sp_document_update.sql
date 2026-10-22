-- =============================================================================
-- V027  Sales CRM - edit document tags and notes                       (2026-10-14)
--
--   sp_document_update   PATCH /documents/{id}: replace the tags and / or the notes of a
--                        document the user can see (BR-DC-01, 12.13). The file, title,
--                        type and sharing stay as uploaded. Audited with from / to.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V026 (uses spi_document_visible, V023).
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_document_update $$
CREATE PROCEDURE sp_document_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_set_notes     TINYINT(1),      -- 1 = write p_notes (NULL clears), 0 = keep
  IN p_notes         VARCHAR(1000),
  IN p_tags          JSON             -- array of strings replaces the tags; NULL = keep
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible   TINYINT;
  DECLARE v_old_notes VARCHAR(1000);
  DECLARE v_old_tags  TEXT;
  DECLARE v_new_tags  TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_document_visible(p_actor_user_id, p_id, v_visible);
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Document not found or not visible to you.', 'id');
  END IF;

  SELECT notes INTO v_old_notes FROM document WHERE id = p_id;
  SELECT GROUP_CONCAT(tag ORDER BY tag SEPARATOR ',') INTO v_old_tags
    FROM document_tag WHERE document_id = p_id;

  START TRANSACTION;
  IF p_set_notes = 1 THEN
    UPDATE document SET notes = NULLIF(TRIM(p_notes), ''),
                        updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
     WHERE id = p_id;
  END IF;

  IF p_tags IS NOT NULL THEN
    DELETE FROM document_tag WHERE document_id = p_id;
    INSERT IGNORE INTO document_tag (document_id, tag)
    SELECT p_id, LOWER(TRIM(j.tag))
      FROM JSON_TABLE(p_tags, '$[*]' COLUMNS (tag VARCHAR(60) PATH '$')) j
     WHERE TRIM(IFNULL(j.tag, '')) <> '';
    UPDATE document SET updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id WHERE id = p_id;
  END IF;

  SELECT GROUP_CONCAT(tag ORDER BY tag SEPARATOR ',') INTO v_new_tags
    FROM document_tag WHERE document_id = p_id;

  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('document', p_id, 'DOCUMENT_UPDATE',
          JSON_OBJECT('notes', JSON_OBJECT('from', v_old_notes,
                                           'to', IF(p_set_notes = 1, NULLIF(TRIM(p_notes), ''), v_old_notes)),
                      'tags', JSON_OBJECT('from', v_old_tags, 'to', v_new_tags)),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT p_id AS id, IFNULL(v_new_tags, '') AS tags,
         (SELECT notes FROM document WHERE id = p_id) AS notes;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V027', 'Edit document tags and notes', UTC_TIMESTAMP());
