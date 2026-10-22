-- =============================================================================
-- V032  Sales CRM - custom fields engine                               (2026-10-14)
--
--   sp_custom_field_list          GET /custom-fields?entity=: the definitions of an entity.
--   sp_custom_field_save          POST / PATCH /custom-fields: the CRM Admin adds or changes a
--                                 field (12.15). Entity, key and type never change after
--                                 creation; deactivating hides the field and keeps its values.
--   spi_custom_record_visible     Is the record visible to the user (same rules as its pages).
--   sp_custom_field_values_get    GET /custom-fields/values?entity=&recordId=
--   sp_custom_field_values_save   PUT /custom-fields/values: the API validates types, options and
--                                 mandatory fields (BR-PT-06) and sends one typed value per field;
--                                 a field sent with every value empty is cleared.
--
-- Entities (OD-45 default): PARTNER (sections ENTITY / TYPE / INDUSTRY / ENGAGEMENT), ACCOUNT,
-- CONTACT, LEAD, OPPORTUNITY, TENDER.
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V031.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_custom_field_list $$
CREATE PROCEDURE sp_custom_field_list(IN p_entity VARCHAR(20), IN p_include_inactive TINYINT(1))
  SQL SECURITY DEFINER
BEGIN
  SELECT id, entity, section, field_key AS fieldKey, label, field_type AS fieldType,
         options_json AS options, is_mandatory AS isMandatory, is_filterable AS isFilterable,
         sort_order AS sortOrder, help_text AS helpText, is_active AS isActive
    FROM custom_field_definition
   WHERE (p_entity IS NULL OR entity = p_entity)
     AND (p_include_inactive = 1 OR is_active = 1)
   ORDER BY entity, IFNULL(section, ''), sort_order, label;
END $$

-- ---------------------------------------------------------------------------
-- sp_custom_field_save: p_id NULL = create
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_custom_field_save $$
CREATE PROCEDURE sp_custom_field_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_entity        VARCHAR(20),
  IN p_section       VARCHAR(40),
  IN p_key           VARCHAR(60),
  IN p_label         VARCHAR(150),
  IN p_type          VARCHAR(15),
  IN p_options       JSON,
  IN p_mandatory     TINYINT(1),
  IN p_filterable    TINYINT(1),
  IN p_sort          SMALLINT UNSIGNED,
  IN p_help          VARCHAR(500),
  IN p_active        TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id     BIGINT UNSIGNED;
  DECLARE v_type   VARCHAR(15);
  DECLARE v_entity VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_id IS NULL THEN
    IF EXISTS (SELECT 1 FROM custom_field_definition WHERE entity = p_entity AND field_key = p_key) THEN
      CALL spi_raise('VALIDATION_FAILED', 'A field with this key already exists for the entity.', 'fieldKey');
    END IF;
    SET v_type = p_type;
    SET v_entity = p_entity;
  ELSE
    SELECT field_type, entity INTO v_type, v_entity FROM custom_field_definition WHERE id = p_id;
    IF v_type IS NULL THEN
      CALL spi_raise('NOT_FOUND', 'Custom field not found.', 'id');
    END IF;
  END IF;
  IF v_entity = 'PARTNER' AND IFNULL(p_section, '') NOT IN ('ENTITY', 'TYPE', 'INDUSTRY', 'ENGAGEMENT') THEN
    CALL spi_raise('VALIDATION_FAILED', 'A partner field belongs to section ENTITY, TYPE, INDUSTRY or ENGAGEMENT.', 'section');
  END IF;
  IF v_type IN ('SINGLE_SELECT', 'MULTI_SELECT') AND IFNULL(JSON_LENGTH(p_options), 0) = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'A select field needs at least one option.', 'options');
  END IF;

  START TRANSACTION;
  IF p_id IS NULL THEN
    INSERT INTO custom_field_definition (entity, section, field_key, label, field_type, options_json,
                                         is_mandatory, is_filterable, sort_order, help_text, is_active, created_by)
    VALUES (p_entity, p_section, p_key, p_label, p_type,
            IF(p_type IN ('SINGLE_SELECT', 'MULTI_SELECT'), p_options, NULL),
            p_mandatory, p_filterable, p_sort, p_help, p_active, p_actor_user_id);
    SET v_id = LAST_INSERT_ID();
  ELSE
    UPDATE custom_field_definition
       SET section = p_section, label = p_label,
           options_json = IF(v_type IN ('SINGLE_SELECT', 'MULTI_SELECT'), p_options, NULL),
           is_mandatory = p_mandatory, is_filterable = p_filterable, sort_order = p_sort,
           help_text = p_help, is_active = p_active,
           updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
     WHERE id = p_id;
    SET v_id = p_id;
  END IF;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('custom_field', v_id, IF(p_id IS NULL, 'CUSTOM_FIELD_CREATE', 'CUSTOM_FIELD_UPDATE'),
          JSON_OBJECT('entity', v_entity, 'label', p_label, 'active', p_active = 1),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id;
END $$

-- ---------------------------------------------------------------------------
-- spi_custom_record_visible: the record pages' visibility rules
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_custom_record_visible $$
CREATE PROCEDURE spi_custom_record_visible(
  IN  p_user_id   BIGINT UNSIGNED,
  IN  p_entity    VARCHAR(20),
  IN  p_record_id BIGINT UNSIGNED,
  OUT o_visible   TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_all     TINYINT;
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_partner BIGINT UNSIGNED;

  SET o_visible = 0;
  CASE p_entity
    WHEN 'PARTNER' THEN
      CALL spi_visible_partners(p_user_id);
      SELECT COUNT(*) INTO o_visible FROM tmp_vis_ptr WHERE id = p_record_id;
    WHEN 'ACCOUNT' THEN
      CALL spi_visible_accounts(p_user_id);
      SELECT COUNT(*) INTO o_visible FROM tmp_vis_acc WHERE id = p_record_id;
    WHEN 'LEAD' THEN
      CALL spi_visible_leads(p_user_id);
      SELECT COUNT(*) INTO o_visible FROM tmp_vis_lead WHERE id = p_record_id;
    WHEN 'TENDER' THEN
      CALL spi_visible_tenders(p_user_id);
      SELECT COUNT(*) INTO o_visible FROM tmp_vis_tender WHERE id = p_record_id;
    WHEN 'OPPORTUNITY' THEN
      CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);
      SELECT COUNT(*) INTO o_visible FROM tmp_dash_opp WHERE id = p_record_id;
    WHEN 'CONTACT' THEN
      -- a contact has the visibility of its account or partner
      SELECT account_id, partner_id INTO v_account, v_partner
        FROM contact WHERE id = p_record_id AND is_active = 1;
      IF v_account IS NOT NULL THEN
        CALL spi_visible_accounts(p_user_id);
        SELECT COUNT(*) INTO o_visible FROM tmp_vis_acc WHERE id = v_account;
      ELSEIF v_partner IS NOT NULL THEN
        CALL spi_visible_partners(p_user_id);
        SELECT COUNT(*) INTO o_visible FROM tmp_vis_ptr WHERE id = v_partner;
      END IF;
    ELSE
      SET o_visible = 0;
  END CASE;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_acc;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_lead;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_tender;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;
END $$

-- ---------------------------------------------------------------------------
-- sp_custom_field_values_get: values of the active fields of one record
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_custom_field_values_get $$
CREATE PROCEDURE sp_custom_field_values_get(
  IN p_user_id   BIGINT UNSIGNED,
  IN p_entity    VARCHAR(20),
  IN p_record_id BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible TINYINT;

  CALL spi_custom_record_visible(p_user_id, p_entity, p_record_id, v_visible);
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Record not found or not visible to you.', 'recordId');
  END IF;

  SELECT d.id AS fieldId, d.field_key AS fieldKey, v.value_text AS valueText,
         CAST(v.value_number AS CHAR) AS valueNumber, v.value_date AS valueDate,
         v.value_bool AS valueBool, v.value_json AS valueJson
    FROM custom_field_value v
    JOIN custom_field_definition d ON d.id = v.field_id AND d.is_active = 1
   WHERE v.entity = p_entity AND v.record_id = p_record_id;
END $$

-- ---------------------------------------------------------------------------
-- sp_custom_field_values_save
--   p_values: [{fieldId, text, number, date, bool, json}] already validated by the API
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_custom_field_values_save $$
CREATE PROCEDURE sp_custom_field_values_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_entity        VARCHAR(20),
  IN p_record_id     BIGINT UNSIGNED,
  IN p_values        JSON,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible TINYINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_custom_record_visible(p_actor_user_id, p_entity, p_record_id, v_visible);
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Record not found or not visible to you.', 'recordId');
  END IF;
  -- partner sections follow the Partner Master edit rule (V030)
  IF p_entity = 'PARTNER' THEN
    CALL spi_partner_owner_check(p_actor_user_id, p_record_id, p_allow_any);
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_cf;
  CREATE TEMPORARY TABLE tmp_cf AS
  SELECT j.field_id, j.vtext, j.vnumber, j.vdate, j.vbool, j.vjson
    FROM JSON_TABLE(p_values, '$[*]' COLUMNS (
           field_id BIGINT UNSIGNED PATH '$.fieldId',
           vtext    TEXT            PATH '$.text',
           vnumber  DECIMAL(18,4)   PATH '$.number',
           vdate    DATE            PATH '$.date',
           vbool    TINYINT         PATH '$.bool',
           vjson    JSON            PATH '$.json')) j
    JOIN custom_field_definition d ON d.id = j.field_id AND d.entity = p_entity AND d.is_active = 1;
  IF (SELECT COUNT(*) FROM tmp_cf) <> JSON_LENGTH(p_values) THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_cf;
    CALL spi_raise('VALIDATION_FAILED', 'Unknown or inactive custom field.', 'values');
  END IF;

  START TRANSACTION;
  DELETE v FROM custom_field_value v JOIN tmp_cf t ON t.field_id = v.field_id
   WHERE v.record_id = p_record_id
     AND t.vtext IS NULL AND t.vnumber IS NULL AND t.vdate IS NULL AND t.vbool IS NULL
     AND (t.vjson IS NULL OR JSON_LENGTH(t.vjson) = 0);
  INSERT INTO custom_field_value (field_id, entity, record_id, value_text, value_number, value_date,
                                  value_bool, value_json, created_by)
  SELECT t.field_id, p_entity, p_record_id, t.vtext, t.vnumber, t.vdate, t.vbool, t.vjson, p_actor_user_id
    FROM tmp_cf t
   WHERE NOT (t.vtext IS NULL AND t.vnumber IS NULL AND t.vdate IS NULL AND t.vbool IS NULL
              AND (t.vjson IS NULL OR JSON_LENGTH(t.vjson) = 0))
  ON DUPLICATE KEY UPDATE value_text = t.vtext, value_number = t.vnumber, value_date = t.vdate,
                          value_bool = t.vbool, value_json = t.vjson,
                          updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  SELECT LOWER(p_entity), p_record_id, 'CUSTOM_FIELDS_UPDATE',
         JSON_OBJECT('fields', JSON_ARRAYAGG(d.field_key)), p_actor_user_id, p_ip, p_request_id
    FROM tmp_cf t JOIN custom_field_definition d ON d.id = t.field_id;
  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_cf;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V032', 'Custom fields: definitions, values, visibility', UTC_TIMESTAMP());
