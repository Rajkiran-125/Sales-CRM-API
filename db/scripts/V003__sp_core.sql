-- =============================================================================
-- V003  Sales CRM - core stored procedures                        (2026-10-09)
--
-- Shared building blocks used by every module's procedures.
--
-- Stored-procedure conventions (decision log D-02):
--   * sp_<module>_<action>  public procedures, called by the API repositories
--                           with CALL sp_x(?, ?, ...) (parameterised, never concatenated)
--   * spi_<name>            internal helpers; called only by other procedures;
--                           they never START / COMMIT a transaction
--   * Only public write procedures own a transaction:
--         DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
--   * Business-rule failures:  CALL spi_raise('<ERROR_CODE>', '<message>', '<field>')
--       -> SIGNAL SQLSTATE '45000', MESSAGE_TEXT = 'ERROR_CODE|field|message'
--       The API maps ERROR_CODE to the HTTP status of tech doc 8.7.
--   * Write procedures take the request context first:
--         p_actor_user_id, p_request_id, p_ip
--   * Result-set columns are aliased in camelCase (API JSON convention, 8.8).
--   * All timestamps use UTC_TIMESTAMP(3); IST (UTC+05:30, no DST) only for
--     business dates and numbers.
--   * No stored FUNCTIONS: with binary logging on they need SUPER, so every
--     helper is a procedure with OUT parameters.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001, V002.
-- Run as the existing account that owns unigr8ways_sales_crm. That account becomes
-- the DEFINER of the procedures (SQL SECURITY DEFINER).
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- spi_raise: raise a business error the API understands
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_raise $$
CREATE PROCEDURE spi_raise(
  IN p_code    VARCHAR(40),
  IN p_message VARCHAR(255),
  IN p_field   VARCHAR(60)
)
  SQL SECURITY DEFINER
  COMMENT 'Raises SQLSTATE 45000 with MESSAGE_TEXT = CODE|field|message'
BEGIN
  DECLARE v_text VARCHAR(128);
  SET v_text = LEFT(CONCAT(p_code, '|', IFNULL(p_field, ''), '|', p_message), 128);
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_text;
END $$

-- -----------------------------------------------------------------------------
-- spi_diff: add "field: {from, to}" to a change set when the value changed
-- (byte comparison, so a change of letter case is recorded too)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_diff $$
CREATE PROCEDURE spi_diff(
  INOUT p_changes JSON,
  IN    p_field   VARCHAR(64),
  IN    p_old     TEXT,
  IN    p_new     TEXT
)
  SQL SECURITY DEFINER
BEGIN
  IF NOT (CAST(p_old AS BINARY) <=> CAST(p_new AS BINARY)) THEN
    SET p_changes = JSON_SET(IFNULL(p_changes, JSON_OBJECT()), CONCAT('$.', p_field),
                             JSON_OBJECT('from', p_old, 'to', p_new));
  END IF;
END $$

-- -----------------------------------------------------------------------------
-- spi_audit_write: append a data-audit row (18.2)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_audit_write $$
CREATE PROCEDURE spi_audit_write(
  IN p_entity_type VARCHAR(40),
  IN p_entity_id   VARCHAR(80),
  IN p_action      VARCHAR(30),
  IN p_changes     JSON,
  IN p_reason      VARCHAR(1000),
  IN p_user_id     BIGINT UNSIGNED,
  IN p_ip          VARCHAR(45),
  IN p_request_id  VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, reason,
                         user_id, ip_address, request_id, occurred_at)
  VALUES (p_entity_type, p_entity_id, p_action, p_changes, p_reason,
          p_user_id, p_ip, p_request_id, UTC_TIMESTAMP(3));
END $$

-- -----------------------------------------------------------------------------
-- spi_security_event: append a security event (10.13)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_security_event $$
CREATE PROCEDURE spi_security_event(
  IN p_event_code     VARCHAR(50),
  IN p_user_id        BIGINT UNSIGNED,
  IN p_target_user_id BIGINT UNSIGNED,
  IN p_ip             VARCHAR(45),
  IN p_user_agent     VARCHAR(255),
  IN p_request_id     VARCHAR(64),
  IN p_detail         JSON
)
  SQL SECURITY DEFINER
BEGIN
  INSERT INTO security_event_log (event_code, user_id, target_user_id, ip_address, user_agent,
                                  request_id, detail_json, occurred_at)
  VALUES (p_event_code, p_user_id, p_target_user_id, p_ip, LEFT(p_user_agent, 255),
          p_request_id, p_detail, UTC_TIMESTAMP(3));
END $$

-- -----------------------------------------------------------------------------
-- Settings readers (thresholds are never hard-coded, 16.1)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_setting_int $$
CREATE PROCEDURE spi_setting_int(IN p_key VARCHAR(80), IN p_default INT, OUT p_value INT)
  SQL SECURITY DEFINER
BEGIN
  SET p_value = NULL;
  SELECT CAST(setting_value AS SIGNED) INTO p_value FROM setting WHERE setting_key = p_key;
  SET p_value = IFNULL(p_value, p_default);
END $$

DROP PROCEDURE IF EXISTS spi_setting_decimal $$
CREATE PROCEDURE spi_setting_decimal(IN p_key VARCHAR(80), IN p_default DECIMAL(16,2), OUT p_value DECIMAL(16,2))
  SQL SECURITY DEFINER
BEGIN
  SET p_value = NULL;
  SELECT CAST(setting_value AS DECIMAL(16,2)) INTO p_value FROM setting WHERE setting_key = p_key;
  SET p_value = IFNULL(p_value, p_default);
END $$

DROP PROCEDURE IF EXISTS spi_setting_text $$
CREATE PROCEDURE spi_setting_text(IN p_key VARCHAR(80), IN p_default VARCHAR(1000), OUT p_value VARCHAR(1000))
  SQL SECURITY DEFINER
BEGIN
  SET p_value = NULL;
  SELECT setting_value INTO p_value FROM setting WHERE setting_key = p_key;
  SET p_value = IFNULL(p_value, p_default);
END $$

-- -----------------------------------------------------------------------------
-- spi_next_number: business numbers LD-2026-0001, ACC-0001 ... (9.1)
-- Locks the sequence row until the caller's transaction ends.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_next_number $$
CREATE PROCEDURE spi_next_number(IN p_prefix VARCHAR(10), IN p_yearly TINYINT, OUT p_number VARCHAR(30))
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_year SMALLINT UNSIGNED;
  DECLARE v_next INT UNSIGNED;

  SET v_year = IF(p_yearly = 1, YEAR(UTC_TIMESTAMP() + INTERVAL 330 MINUTE), 0);

  INSERT IGNORE INTO number_sequence (prefix, seq_year, current_value, updated_at)
  VALUES (p_prefix, v_year, 0, UTC_TIMESTAMP(3));

  UPDATE number_sequence
     SET current_value = current_value + 1, updated_at = UTC_TIMESTAMP(3)
   WHERE prefix = p_prefix AND seq_year = v_year;

  SELECT current_value INTO v_next
    FROM number_sequence WHERE prefix = p_prefix AND seq_year = v_year;

  SET p_number = CONCAT(p_prefix, '-',
                        IF(p_yearly = 1, CONCAT(v_year, '-'), ''),
                        IF(v_next > 9999, v_next, LPAD(v_next, 4, '0')));
END $$

-- -----------------------------------------------------------------------------
-- spi_user_hierarchy_rebuild: rebuild the reporting-tree closure table (10.8)
-- Called inside the transaction of any change to user.reporting_to_user_id.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_user_hierarchy_rebuild $$
CREATE PROCEDURE spi_user_hierarchy_rebuild()
  SQL SECURITY DEFINER
BEGIN
  DELETE FROM user_hierarchy;

  INSERT INTO user_hierarchy (ancestor_user_id, descendant_user_id, depth)
  WITH RECURSIVE tree (ancestor_user_id, descendant_user_id, depth) AS (
    SELECT id, id, 0 FROM `user`
    UNION ALL
    SELECT t.ancestor_user_id, u.id, t.depth + 1
      FROM tree t
      JOIN `user` u ON u.reporting_to_user_id = t.descendant_user_id
     WHERE t.depth < 20
  )
  SELECT ancestor_user_id, descendant_user_id, MIN(depth)
    FROM tree
   GROUP BY ancestor_user_id, descendant_user_id;
END $$

-- -----------------------------------------------------------------------------
-- spi_scope_flags: the user's data scope as the union of their active roles (10.8)
--   p_all            ALL records
--   p_own_team       owner / backup owner is the user or someone below them
--   p_assigned       + pre-sales owner / executive sponsor in the team
--   p_partner_owned  + partners owned by the team and all deals of those partners
--   p_module_limited records of the modules in role_module_scope (Finance)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_scope_flags $$
CREATE PROCEDURE spi_scope_flags(
  IN  p_user_id        BIGINT UNSIGNED,
  OUT p_all            TINYINT,
  OUT p_own_team       TINYINT,
  OUT p_assigned       TINYINT,
  OUT p_partner_owned  TINYINT,
  OUT p_module_limited TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  SELECT IFNULL(MAX(r.data_scope = 'ALL'), 0),
         IFNULL(MAX(r.data_scope IN ('OWN_AND_TEAM', 'ASSIGNED_AND_TEAM', 'PARTNER_OWNED')), 0),
         IFNULL(MAX(r.data_scope = 'ASSIGNED_AND_TEAM'), 0),
         IFNULL(MAX(r.data_scope = 'PARTNER_OWNED'), 0),
         IFNULL(MAX(r.data_scope = 'MODULE_LIMITED'), 0)
    INTO p_all, p_own_team, p_assigned, p_partner_owned, p_module_limited
    FROM user_role ur
    JOIN role r ON r.id = ur.role_id AND r.is_active = 1
   WHERE ur.user_id = p_user_id;
END $$

-- -----------------------------------------------------------------------------
-- spi_active_admin_count: active users holding the active CRM_ADMIN role,
-- optionally excluding one user (last-admin protection, 11.4)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_active_admin_count $$
CREATE PROCEDURE spi_active_admin_count(IN p_exclude_user_id BIGINT UNSIGNED, OUT p_count INT)
  SQL SECURITY DEFINER
BEGIN
  SELECT COUNT(DISTINCT u.id) INTO p_count
    FROM `user` u
    JOIN user_role ur ON ur.user_id = u.id
    JOIN role r ON r.id = ur.role_id
   WHERE r.code = 'CRM_ADMIN' AND r.is_active = 1
     AND u.status IN ('ACTIVE', 'LOCKED')
     AND (p_exclude_user_id IS NULL OR u.id <> p_exclude_user_id);
END $$

-- -----------------------------------------------------------------------------
-- Public helpers called by the API
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_security_event_write $$
CREATE PROCEDURE sp_security_event_write(
  IN p_event_code     VARCHAR(50),
  IN p_user_id        BIGINT UNSIGNED,
  IN p_target_user_id BIGINT UNSIGNED,
  IN p_ip             VARCHAR(45),
  IN p_user_agent     VARCHAR(255),
  IN p_request_id     VARCHAR(64),
  IN p_detail         JSON
)
  SQL SECURITY DEFINER
  COMMENT 'Security events raised by the API middleware (ACCESS_DENIED, SCOPE_DENIED, ...)'
BEGIN
  CALL spi_security_event(p_event_code, p_user_id, p_target_user_id, p_ip, p_user_agent, p_request_id, p_detail);
END $$

DROP PROCEDURE IF EXISTS sp_record_access_write $$
CREATE PROCEDURE sp_record_access_write(
  IN p_user_id     BIGINT UNSIGNED,
  IN p_entity_type VARCHAR(40),
  IN p_entity_id   BIGINT UNSIGNED,
  IN p_access_type VARCHAR(10),
  IN p_detail      VARCHAR(500),
  IN p_ip          VARCHAR(45),
  IN p_request_id  VARCHAR(64)
)
  SQL SECURITY DEFINER
  COMMENT '"Every view is logged" (UM 12): detail views, exports and downloads'
BEGIN
  INSERT INTO record_access_log (entity_type, entity_id, user_id, access_type, detail, ip_address, request_id, occurred_at)
  VALUES (p_entity_type, p_entity_id, p_user_id, p_access_type, LEFT(p_detail, 500), p_ip, p_request_id, UTC_TIMESTAMP(3));
END $$

DROP PROCEDURE IF EXISTS sp_email_log_create $$
CREATE PROCEDURE sp_email_log_create(
  IN p_template_code VARCHAR(60),
  IN p_to_address    VARCHAR(500),
  IN p_subject       VARCHAR(255),
  IN p_entity_type   VARCHAR(40),
  IN p_entity_id     BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  INSERT INTO email_log (template_code, to_address, subject, entity_type, entity_id, status, created_at)
  VALUES (p_template_code, p_to_address, LEFT(p_subject, 255), p_entity_type, p_entity_id, 'QUEUED', UTC_TIMESTAMP(3));
  SELECT LAST_INSERT_ID() AS id;
END $$

DROP PROCEDURE IF EXISTS sp_email_log_update $$
CREATE PROCEDURE sp_email_log_update(
  IN p_id       BIGINT UNSIGNED,
  IN p_status   VARCHAR(8),
  IN p_error    VARCHAR(1000),
  IN p_attempts TINYINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  UPDATE email_log
     SET status = p_status,
         error = LEFT(p_error, 1000),
         attempts = p_attempts,
         sent_at = IF(p_status = 'SENT', UTC_TIMESTAMP(3), sent_at),
         updated_at = UTC_TIMESTAMP(3)
   WHERE id = p_id;
END $$

DROP PROCEDURE IF EXISTS sp_template_get_for_send $$
CREATE PROCEDURE sp_template_get_for_send(IN p_code VARCHAR(60))
  SQL SECURITY DEFINER
  COMMENT 'Active email template used by the mailer'
BEGIN
  SELECT code, subject, body_html AS bodyHtml, placeholders
    FROM email_template
   WHERE code = p_code AND is_active = 1;
END $$

DELIMITER ;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V003', 'Core stored procedures', 'V003__sp_core.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
