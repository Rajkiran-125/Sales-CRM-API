-- =============================================================================
-- V005  Sales CRM - administration stored procedures (M02)        (2026-10-09)
--
-- Users (invite, edit, status, unlock, revoke sessions, bootstrap admin), roles
-- with the permission matrix, permission catalogue, and the audit-log readers.
-- Rules (11.4, 10.7): e-mail unique; reporting line without cycles; at least one
-- role; at least one active CRM Admin always remains; system roles cannot be
-- deactivated; the CRM Admin role keeps user.manage + role.manage (lock-out
-- protection); users are never hard-deleted.
--
-- Re-runnable. Prerequisite: V001-V004. Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- spi_validate_role_ids: every id exists and is active, and there is at least one
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_validate_role_ids $$
CREATE PROCEDURE spi_validate_role_ids(IN p_role_ids JSON)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_requested INT DEFAULT 0;
  DECLARE v_valid     INT DEFAULT 0;

  IF p_role_ids IS NULL OR JSON_TYPE(p_role_ids) <> 'ARRAY' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Select at least one role.', 'roleIds');
  END IF;

  SELECT COUNT(DISTINCT jt.role_id) INTO v_requested
    FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt;

  SELECT COUNT(DISTINCT r.id) INTO v_valid
    FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt
    JOIN role r ON r.id = jt.role_id AND r.is_active = 1;

  IF v_requested = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Select at least one role.', 'roleIds');
  END IF;
  IF v_valid <> v_requested THEN
    CALL spi_raise('VALIDATION_FAILED', 'One or more roles are invalid or inactive.', 'roleIds');
  END IF;
END $$

-- -----------------------------------------------------------------------------
-- spi_validate_manager: the reporting manager exists, is not inactive and the
-- new line does not create a loop (10.8 rule 1)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_validate_manager $$
CREATE PROCEDURE spi_validate_manager(IN p_user_id BIGINT UNSIGNED, IN p_manager_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_status VARCHAR(10) DEFAULT NULL;

  IF p_manager_id IS NOT NULL THEN
    IF p_user_id IS NOT NULL AND p_manager_id = p_user_id THEN
      CALL spi_raise('VALIDATION_FAILED', 'A user cannot report to themselves.', 'reportingToUserId');
    END IF;

    SELECT status INTO v_status FROM `user` WHERE id = p_manager_id;
    IF v_status IS NULL OR v_status = 'INACTIVE' THEN
      CALL spi_raise('VALIDATION_FAILED', 'The reporting manager does not exist or is inactive.', 'reportingToUserId');
    END IF;

    IF p_user_id IS NOT NULL AND EXISTS (SELECT 1 FROM user_hierarchy
                                          WHERE ancestor_user_id = p_user_id
                                            AND descendant_user_id = p_manager_id) THEN
      CALL spi_raise('VALIDATION_FAILED', 'This reporting line would create a loop.', 'reportingToUserId');
    END IF;
  END IF;
END $$

-- -----------------------------------------------------------------------------
-- spi_user_insert: shared by sp_user_create and sp_user_bootstrap_admin
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_user_insert $$
CREATE PROCEDURE spi_user_insert(
  IN  p_actor_user_id BIGINT UNSIGNED,
  IN  p_request_id    VARCHAR(64),
  IN  p_ip            VARCHAR(45),
  IN  p_email         VARCHAR(150),
  IN  p_full_name     VARCHAR(150),
  IN  p_mobile        VARCHAR(20),
  IN  p_designation   VARCHAR(100),
  IN  p_department    VARCHAR(100),
  IN  p_reporting_to  BIGINT UNSIGNED,
  IN  p_role_ids      JSON,
  IN  p_invite_hash   CHAR(64),
  OUT p_user_id       BIGINT UNSIGNED,
  OUT p_expires_at    DATETIME(3)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_now   DATETIME(3)  DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_email VARCHAR(150) DEFAULT LOWER(TRIM(p_email));
  DECLARE v_hours INT;
  DECLARE v_roles VARCHAR(1000);

  IF EXISTS (SELECT 1 FROM `user` WHERE email = v_email) THEN
    CALL spi_raise('DUPLICATE', 'A user with this email already exists.', 'email');
  END IF;
  CALL spi_validate_manager(NULL, p_reporting_to);
  CALL spi_validate_role_ids(p_role_ids);
  CALL spi_setting_int('auth.invite_token.hours', 72, v_hours);

  INSERT INTO `user` (email, full_name, mobile, designation, department, reporting_to_user_id,
                      status, created_at, created_by)
  VALUES (v_email, TRIM(p_full_name), NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_designation), ''),
          NULLIF(TRIM(p_department), ''), p_reporting_to, 'INVITED', v_now, p_actor_user_id);
  SET p_user_id = LAST_INSERT_ID();

  INSERT INTO user_role (user_id, role_id, assigned_by, assigned_at)
  SELECT DISTINCT p_user_id, jt.role_id, p_actor_user_id, v_now
    FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt;

  CALL spi_user_hierarchy_rebuild();

  SET p_expires_at = v_now + INTERVAL v_hours HOUR;
  INSERT INTO password_reset_token (user_id, token_hash, purpose, expires_at, requested_ip, created_at, created_by)
  VALUES (p_user_id, p_invite_hash, 'INVITE', p_expires_at, p_ip, v_now, p_actor_user_id);

  SELECT GROUP_CONCAT(r.code ORDER BY r.code) INTO v_roles
    FROM user_role ur JOIN role r ON r.id = ur.role_id WHERE ur.user_id = p_user_id;

  CALL spi_audit_write('USER', p_user_id, 'CREATE',
       JSON_OBJECT('email',             JSON_OBJECT('from', NULL, 'to', v_email),
                   'fullName',          JSON_OBJECT('from', NULL, 'to', TRIM(p_full_name)),
                   'reportingToUserId', JSON_OBJECT('from', NULL, 'to', p_reporting_to),
                   'roles',             JSON_OBJECT('from', NULL, 'to', v_roles),
                   'status',            JSON_OBJECT('from', NULL, 'to', 'INVITED')),
       NULL, p_actor_user_id, p_ip, p_request_id);
  CALL spi_security_event('USER_CREATED', p_actor_user_id, p_user_id, p_ip, NULL, p_request_id, NULL);
  CALL spi_security_event('ROLE_ASSIGNED', p_actor_user_id, p_user_id, p_ip, NULL, p_request_id,
                          JSON_OBJECT('roles', v_roles));
  CALL spi_security_event('INVITATION_SENT', p_actor_user_id, p_user_id, p_ip, NULL, p_request_id, NULL);
END $$

-- -----------------------------------------------------------------------------
-- Users: read
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_user_list $$
CREATE PROCEDURE sp_user_list(
  IN p_search     VARCHAR(100),
  IN p_status     VARCHAR(10),
  IN p_role_id    BIGINT UNSIGNED,
  IN p_manager_id BIGINT UNSIGNED,
  IN p_sort       VARCHAR(30),
  IN p_offset     INT,
  IN p_limit      INT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_search VARCHAR(100) DEFAULT NULLIF(TRIM(p_search), '');
  DECLARE v_like   VARCHAR(310);
  SET v_like = CONCAT('%', REPLACE(REPLACE(REPLACE(IFNULL(v_search, ''), '\\', '\\\\'), '%', '\\%'), '_', '\\_'), '%');

  SELECT u.id, u.email, u.full_name AS fullName, u.mobile, u.designation, u.department, u.status,
         u.reporting_to_user_id AS reportingToUserId, m.full_name AS reportingToName,
         u.last_login_at AS lastLoginAt, u.locked_until AS lockedUntil, u.created_at AS createdAt,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', r.id, 'code', r.code, 'name', r.name))
            FROM user_role ur JOIN role r ON r.id = ur.role_id
           WHERE ur.user_id = u.id) AS roles
    FROM `user` u
    LEFT JOIN `user` m ON m.id = u.reporting_to_user_id
   WHERE (v_search IS NULL OR u.full_name LIKE v_like OR u.email LIKE v_like)
     AND (p_status IS NULL OR u.status = p_status)
     AND (p_role_id IS NULL OR EXISTS (SELECT 1 FROM user_role ur2 WHERE ur2.user_id = u.id AND ur2.role_id = p_role_id))
     AND (p_manager_id IS NULL OR u.reporting_to_user_id = p_manager_id)
   ORDER BY
     CASE WHEN p_sort = 'name'         THEN u.full_name     END ASC,
     CASE WHEN p_sort = '-name'        THEN u.full_name     END DESC,
     CASE WHEN p_sort = 'email'        THEN u.email         END ASC,
     CASE WHEN p_sort = '-email'       THEN u.email         END DESC,
     CASE WHEN p_sort = 'status'       THEN u.status        END ASC,
     CASE WHEN p_sort = '-status'      THEN u.status        END DESC,
     CASE WHEN p_sort = 'lastLoginAt'  THEN u.last_login_at END ASC,
     CASE WHEN p_sort = '-lastLoginAt' THEN u.last_login_at END DESC,
     CASE WHEN p_sort = 'createdAt'    THEN u.created_at    END ASC,
     CASE WHEN p_sort = '-createdAt'   THEN u.created_at    END DESC,
     u.full_name ASC, u.id ASC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total
    FROM `user` u
   WHERE (v_search IS NULL OR u.full_name LIKE v_like OR u.email LIKE v_like)
     AND (p_status IS NULL OR u.status = p_status)
     AND (p_role_id IS NULL OR EXISTS (SELECT 1 FROM user_role ur2 WHERE ur2.user_id = u.id AND ur2.role_id = p_role_id))
     AND (p_manager_id IS NULL OR u.reporting_to_user_id = p_manager_id);
END $$

DROP PROCEDURE IF EXISTS sp_user_get $$
CREATE PROCEDURE sp_user_get(IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  SELECT u.id, u.email, u.full_name AS fullName, u.mobile, u.designation, u.department, u.status,
         u.reporting_to_user_id AS reportingToUserId, m.full_name AS reportingToName,
         u.must_change_password AS mustChangePassword, u.failed_login_count AS failedLoginCount,
         u.locked_until AS lockedUntil, u.last_login_at AS lastLoginAt,
         u.password_changed_at AS passwordChangedAt, u.deactivated_at AS deactivatedAt,
         u.deactivation_reason AS deactivationReason, u.created_at AS createdAt, u.updated_at AS updatedAt,
         u.row_version AS rowVersion,
         (SELECT COUNT(*) FROM refresh_token rt
           WHERE rt.user_id = u.id AND rt.revoked_at IS NULL AND rt.expires_at > UTC_TIMESTAMP(3)) AS activeSessions
    FROM `user` u
    LEFT JOIN `user` m ON m.id = u.reporting_to_user_id
   WHERE u.id = p_id;

  SELECT r.id, r.code, r.name, r.data_scope AS dataScope, r.is_active AS isActive
    FROM user_role ur JOIN role r ON r.id = ur.role_id
   WHERE ur.user_id = p_id
   ORDER BY r.name;
END $$

-- Lightweight picker for owners / managers (any signed-in user)
DROP PROCEDURE IF EXISTS sp_user_lookup $$
CREATE PROCEDURE sp_user_lookup(IN p_search VARCHAR(100), IN p_include_inactive TINYINT, IN p_limit INT)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_search VARCHAR(100) DEFAULT NULLIF(TRIM(p_search), '');
  DECLARE v_like   VARCHAR(310);
  SET v_like = CONCAT('%', REPLACE(REPLACE(REPLACE(IFNULL(v_search, ''), '\\', '\\\\'), '%', '\\%'), '_', '\\_'), '%');

  SELECT u.id, u.full_name AS fullName, u.email, u.designation, u.status
    FROM `user` u
   WHERE (v_search IS NULL OR u.full_name LIKE v_like OR u.email LIKE v_like)
     AND (IFNULL(p_include_inactive, 0) = 1 OR u.status IN ('ACTIVE', 'LOCKED', 'INVITED'))
   ORDER BY u.full_name
   LIMIT p_limit;
END $$

-- -----------------------------------------------------------------------------
-- Users: write
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_user_create $$
CREATE PROCEDURE sp_user_create(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_email         VARCHAR(150),
  IN p_full_name     VARCHAR(150),
  IN p_mobile        VARCHAR(20),
  IN p_designation   VARCHAR(100),
  IN p_department    VARCHAR(100),
  IN p_reporting_to  BIGINT UNSIGNED,
  IN p_role_ids      JSON,
  IN p_invite_hash   CHAR(64)
)
  SQL SECURITY DEFINER
  COMMENT 'Create a user in status INVITED with an invitation link (11.4, 10.5)'
BEGIN
  DECLARE v_user_id BIGINT UNSIGNED;
  DECLARE v_expires DATETIME(3);
  DECLARE v_hours   INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  CALL spi_user_insert(p_actor_user_id, p_request_id, p_ip, p_email, p_full_name, p_mobile, p_designation,
                       p_department, p_reporting_to, p_role_ids, p_invite_hash, v_user_id, v_expires);
  COMMIT;

  CALL spi_setting_int('auth.invite_token.hours', 72, v_hours);
  SELECT id, email, full_name AS fullName, v_expires AS expiresAt, v_hours * 60 AS expiresInMinutes
    FROM `user` WHERE id = v_user_id;
END $$

DROP PROCEDURE IF EXISTS sp_user_bootstrap_admin $$
CREATE PROCEDURE sp_user_bootstrap_admin(
  IN p_email       VARCHAR(150),
  IN p_full_name   VARCHAR(150),
  IN p_invite_hash CHAR(64),
  IN p_ip          VARCHAR(45),
  IN p_request_id  VARCHAR(64)
)
  SQL SECURITY DEFINER
  COMMENT 'Create the first CRM Admin (11.5); refused once any CRM Admin exists'
BEGIN
  DECLARE v_user_id  BIGINT UNSIGNED;
  DECLARE v_expires  DATETIME(3);
  DECLARE v_hours    INT;
  DECLARE v_role_id  BIGINT UNSIGNED DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  IF EXISTS (SELECT 1 FROM `user` u
               JOIN user_role ur ON ur.user_id = u.id
               JOIN role r ON r.id = ur.role_id
              WHERE r.code = 'CRM_ADMIN' AND u.status IN ('ACTIVE', 'LOCKED', 'INVITED')) THEN
    CALL spi_raise('BUSINESS_RULE_VIOLATION', 'A CRM Admin already exists. Use the Users screen to invite more users.', NULL);
  END IF;

  SELECT id INTO v_role_id FROM role WHERE code = 'CRM_ADMIN' AND is_active = 1;
  IF v_role_id IS NULL THEN
    CALL spi_raise('BUSINESS_RULE_VIOLATION', 'The CRM_ADMIN role is missing. Run the seed script V002 first.', NULL);
  END IF;

  CALL spi_user_insert(NULL, p_request_id, p_ip, p_email, p_full_name, NULL, NULL, NULL, NULL,
                       JSON_ARRAY(v_role_id), p_invite_hash, v_user_id, v_expires);
  CALL spi_security_event('BOOTSTRAP_ADMIN_CREATED', NULL, v_user_id, p_ip, NULL, p_request_id, NULL);
  COMMIT;

  CALL spi_setting_int('auth.invite_token.hours', 72, v_hours);
  SELECT id, email, full_name AS fullName, v_expires AS expiresAt, v_hours * 60 AS expiresInMinutes
    FROM `user` WHERE id = v_user_id;
END $$

DROP PROCEDURE IF EXISTS sp_user_update $$
CREATE PROCEDURE sp_user_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_row_version   INT UNSIGNED,
  IN p_full_name     VARCHAR(150),
  IN p_mobile        VARCHAR(20),
  IN p_designation   VARCHAR(100),
  IN p_department    VARCHAR(100),
  IN p_reporting_to  BIGINT UNSIGNED,
  IN p_role_ids      JSON
)
  SQL SECURITY DEFINER
  COMMENT 'Edit profile, reporting manager and roles (11.4)'
BEGIN
  DECLARE v_now           DATETIME(3)     DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_found         BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_row_version   INT UNSIGNED;
  DECLARE v_full_name     VARCHAR(150);
  DECLARE v_mobile        VARCHAR(20);
  DECLARE v_designation   VARCHAR(100);
  DECLARE v_department    VARCHAR(100);
  DECLARE v_reporting_to  BIGINT UNSIGNED;
  DECLARE v_status        VARCHAR(10);
  DECLARE v_admin_role_id BIGINT UNSIGNED;
  DECLARE v_was_admin     TINYINT DEFAULT 0;
  DECLARE v_will_be_admin TINYINT DEFAULT 0;
  DECLARE v_admins_left   INT DEFAULT 0;
  DECLARE v_old_roles     VARCHAR(1000);
  DECLARE v_new_roles     VARCHAR(1000);
  DECLARE v_added         VARCHAR(1000);
  DECLARE v_removed       VARCHAR(1000);
  DECLARE v_changes       JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;

  SELECT id, row_version, full_name, mobile, designation, department, reporting_to_user_id, status
    INTO v_found, v_row_version, v_full_name, v_mobile, v_designation, v_department, v_reporting_to, v_status
    FROM `user` WHERE id = p_id FOR UPDATE;

  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'User not found.', 'id');
  END IF;
  IF v_row_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This user was changed by someone else. Reload and try again.', 'rowVersion');
  END IF;

  CALL spi_validate_manager(p_id, p_reporting_to);
  CALL spi_validate_role_ids(p_role_ids);

  SELECT id INTO v_admin_role_id FROM role WHERE code = 'CRM_ADMIN';
  SET v_was_admin = EXISTS (SELECT 1 FROM user_role WHERE user_id = p_id AND role_id = v_admin_role_id);
  SET v_will_be_admin = EXISTS (SELECT 1 FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt
                                 WHERE jt.role_id = v_admin_role_id);
  IF v_was_admin = 1 AND v_will_be_admin = 0 AND v_status IN ('ACTIVE', 'LOCKED') THEN
    CALL spi_active_admin_count(p_id, v_admins_left);
    IF v_admins_left = 0 THEN
      CALL spi_raise('BUSINESS_RULE_VIOLATION', 'At least one active CRM Admin must remain.', 'roleIds');
    END IF;
  END IF;

  SELECT GROUP_CONCAT(r.code ORDER BY r.code) INTO v_old_roles
    FROM user_role ur JOIN role r ON r.id = ur.role_id WHERE ur.user_id = p_id;
  SELECT GROUP_CONCAT(DISTINCT r.code ORDER BY r.code) INTO v_new_roles
    FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt
    JOIN role r ON r.id = jt.role_id;
  SELECT GROUP_CONCAT(DISTINCT r.code ORDER BY r.code) INTO v_added
    FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt
    JOIN role r ON r.id = jt.role_id
   WHERE NOT EXISTS (SELECT 1 FROM user_role ur WHERE ur.user_id = p_id AND ur.role_id = jt.role_id);
  SELECT GROUP_CONCAT(r.code ORDER BY r.code) INTO v_removed
    FROM user_role ur JOIN role r ON r.id = ur.role_id
   WHERE ur.user_id = p_id
     AND ur.role_id NOT IN (SELECT jt.role_id
                              FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt);

  CALL spi_diff(v_changes, 'fullName',          v_full_name,    TRIM(p_full_name));
  CALL spi_diff(v_changes, 'mobile',            v_mobile,       NULLIF(TRIM(p_mobile), ''));
  CALL spi_diff(v_changes, 'designation',       v_designation,  NULLIF(TRIM(p_designation), ''));
  CALL spi_diff(v_changes, 'department',        v_department,   NULLIF(TRIM(p_department), ''));
  CALL spi_diff(v_changes, 'reportingToUserId', v_reporting_to, p_reporting_to);
  CALL spi_diff(v_changes, 'roles',             v_old_roles,    v_new_roles);

  UPDATE `user`
     SET full_name = TRIM(p_full_name),
         mobile = NULLIF(TRIM(p_mobile), ''),
         designation = NULLIF(TRIM(p_designation), ''),
         department = NULLIF(TRIM(p_department), ''),
         reporting_to_user_id = p_reporting_to,
         row_version = row_version + 1,
         updated_at = v_now,
         updated_by = p_actor_user_id
   WHERE id = p_id;

  DELETE FROM user_role
   WHERE user_id = p_id
     AND role_id NOT IN (SELECT jt.role_id
                           FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt);
  INSERT IGNORE INTO user_role (user_id, role_id, assigned_by, assigned_at)
  SELECT DISTINCT p_id, jt.role_id, p_actor_user_id, v_now
    FROM JSON_TABLE(p_role_ids, '$[*]' COLUMNS (role_id BIGINT UNSIGNED PATH '$')) jt;

  IF NOT (v_reporting_to <=> p_reporting_to) THEN
    CALL spi_user_hierarchy_rebuild();
  END IF;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write('USER', p_id, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
    CALL spi_security_event('USER_UPDATED', p_actor_user_id, p_id, p_ip, NULL, p_request_id,
                            JSON_OBJECT('fields', JSON_KEYS(v_changes)));
  END IF;
  IF v_added IS NOT NULL THEN
    CALL spi_security_event('ROLE_ASSIGNED', p_actor_user_id, p_id, p_ip, NULL, p_request_id, JSON_OBJECT('roles', v_added));
  END IF;
  IF v_removed IS NOT NULL THEN
    CALL spi_security_event('ROLE_REMOVED', p_actor_user_id, p_id, p_ip, NULL, p_request_id, JSON_OBJECT('roles', v_removed));
  END IF;

  COMMIT;
  CALL sp_user_get(p_id);
END $$

DROP PROCEDURE IF EXISTS sp_user_set_status $$
CREATE PROCEDURE sp_user_set_status(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_status        VARCHAR(10),
  IN p_reason        VARCHAR(500)
)
  SQL SECURITY DEFINER
  COMMENT 'Activate / deactivate a user with a reason (10.7)'
BEGIN
  DECLARE v_now         DATETIME(3)     DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_found       BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_status      VARCHAR(10);
  DECLARE v_has_pw      TINYINT;
  DECLARE v_new_status  VARCHAR(10);
  DECLARE v_admins_left INT DEFAULT 0;
  DECLARE v_is_admin    TINYINT DEFAULT 0;
  DECLARE v_reason      VARCHAR(500) DEFAULT NULLIF(TRIM(p_reason), '');
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_status NOT IN ('ACTIVE', 'INACTIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Status must be ACTIVE or INACTIVE.', 'status');
  END IF;
  IF v_reason IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'A reason is required.', 'reason');
  END IF;

  START TRANSACTION;
  SELECT id, status, password_hash IS NOT NULL INTO v_found, v_status, v_has_pw
    FROM `user` WHERE id = p_id FOR UPDATE;
  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'User not found.', 'id');
  END IF;

  IF p_status = 'INACTIVE' THEN
    IF p_id = p_actor_user_id THEN
      CALL spi_raise('BUSINESS_RULE_VIOLATION', 'You cannot deactivate your own account.', NULL);
    END IF;
    SET v_new_status = 'INACTIVE';
    IF v_status <> 'INACTIVE' THEN
      SET v_is_admin = EXISTS (SELECT 1 FROM user_role ur JOIN role r ON r.id = ur.role_id
                                WHERE ur.user_id = p_id AND r.code = 'CRM_ADMIN' AND r.is_active = 1);
      IF v_is_admin = 1 AND v_status IN ('ACTIVE', 'LOCKED') THEN
        CALL spi_active_admin_count(p_id, v_admins_left);
        IF v_admins_left = 0 THEN
          CALL spi_raise('BUSINESS_RULE_VIOLATION', 'At least one active CRM Admin must remain.', NULL);
        END IF;
      END IF;

      UPDATE `user`
         SET status = 'INACTIVE', deactivated_at = v_now, deactivation_reason = v_reason,
             token_version = token_version + 1, row_version = row_version + 1,
             updated_at = v_now, updated_by = p_actor_user_id
       WHERE id = p_id;
      UPDATE refresh_token SET revoked_at = v_now, revoked_reason = 'USER_DEACTIVATED'
       WHERE user_id = p_id AND revoked_at IS NULL;
      UPDATE password_reset_token SET invalidated_at = v_now
       WHERE user_id = p_id AND used_at IS NULL AND invalidated_at IS NULL;
      CALL spi_security_event('USER_DEACTIVATED', p_actor_user_id, p_id, p_ip, NULL, p_request_id,
                              JSON_OBJECT('reason', v_reason));
    END IF;
  ELSE
    IF v_status IN ('INVITED', 'LOCKED') THEN
      CALL spi_raise('BUSINESS_RULE_VIOLATION',
                     IF(v_status = 'LOCKED', 'Use Unlock for a locked account.', 'The user has not accepted the invitation yet; resend it instead.'),
                     NULL);
    END IF;
    SET v_new_status = IF(v_status = 'INACTIVE', IF(v_has_pw = 1, 'ACTIVE', 'INVITED'), v_status);
    IF v_status = 'INACTIVE' THEN
      UPDATE `user`
         SET status = v_new_status, deactivated_at = NULL, deactivation_reason = NULL,
             failed_login_count = 0, locked_until = NULL,
             row_version = row_version + 1, updated_at = v_now, updated_by = p_actor_user_id
       WHERE id = p_id;
      CALL spi_security_event('USER_ACTIVATED', p_actor_user_id, p_id, p_ip, NULL, p_request_id,
                              JSON_OBJECT('reason', v_reason, 'status', v_new_status));
    END IF;
  END IF;

  IF v_new_status <> v_status THEN
    CALL spi_audit_write('USER', p_id, 'STATUS_CHANGE',
                         JSON_OBJECT('status', JSON_OBJECT('from', v_status, 'to', v_new_status)),
                         v_reason, p_actor_user_id, p_ip, p_request_id);
  END IF;

  COMMIT;
  CALL sp_user_get(p_id);
END $$

DROP PROCEDURE IF EXISTS sp_user_unlock $$
CREATE PROCEDURE sp_user_unlock(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_status VARCHAR(10) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT status INTO v_status FROM `user` WHERE id = p_id FOR UPDATE;
  IF v_status IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'User not found.', 'id');
  END IF;
  IF v_status <> 'LOCKED' THEN
    CALL spi_raise('BUSINESS_RULE_VIOLATION', 'The account is not locked.', NULL);
  END IF;

  UPDATE `user`
     SET status = 'ACTIVE', failed_login_count = 0, locked_until = NULL,
         row_version = row_version + 1, updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE id = p_id;
  CALL spi_audit_write('USER', p_id, 'STATUS_CHANGE',
                       JSON_OBJECT('status', JSON_OBJECT('from', 'LOCKED', 'to', 'ACTIVE')),
                       'Unlocked by administrator', p_actor_user_id, p_ip, p_request_id);
  CALL spi_security_event('ACCOUNT_UNLOCKED', p_actor_user_id, p_id, p_ip, NULL, p_request_id,
                          JSON_OBJECT('by', 'ADMIN'));
  COMMIT;
  CALL sp_user_get(p_id);
END $$

DROP PROCEDURE IF EXISTS sp_user_revoke_sessions $$
CREATE PROCEDURE sp_user_revoke_sessions(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
  COMMENT 'Log a user out everywhere (11.4)'
BEGIN
  DECLARE v_found BIGINT UNSIGNED DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT id INTO v_found FROM `user` WHERE id = p_id FOR UPDATE;
  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'User not found.', 'id');
  END IF;
  UPDATE `user` SET token_version = token_version + 1, updated_at = UTC_TIMESTAMP(3) WHERE id = p_id;
  UPDATE refresh_token SET revoked_at = UTC_TIMESTAMP(3), revoked_reason = 'ADMIN_REVOKED'
   WHERE user_id = p_id AND revoked_at IS NULL;
  CALL spi_security_event('SESSIONS_REVOKED', p_actor_user_id, p_id, p_ip, NULL, p_request_id, NULL);
  COMMIT;
END $$

-- -----------------------------------------------------------------------------
-- Roles and permissions
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_permission_list $$
CREATE PROCEDURE sp_permission_list()
  SQL SECURITY DEFINER
BEGIN
  SELECT code, module, action, description, is_sensitive AS isSensitive, sort_order AS sortOrder
    FROM permission
   ORDER BY sort_order, code;
END $$

DROP PROCEDURE IF EXISTS sp_role_list $$
CREATE PROCEDURE sp_role_list(IN p_include_inactive TINYINT)
  SQL SECURITY DEFINER
BEGIN
  SELECT r.id, r.code, r.name, r.description, r.data_scope AS dataScope,
         r.is_system AS isSystem, r.is_active AS isActive,
         (SELECT COUNT(*) FROM user_role ur JOIN `user` u ON u.id = ur.user_id
           WHERE ur.role_id = r.id AND u.status <> 'INACTIVE') AS userCount,
         (SELECT COUNT(*) FROM role_permission rp WHERE rp.role_id = r.id) AS permissionCount,
         r.row_version AS rowVersion, r.updated_at AS updatedAt
    FROM role r
   WHERE IFNULL(p_include_inactive, 0) = 1 OR r.is_active = 1
   ORDER BY r.is_system DESC, r.name;
END $$

DROP PROCEDURE IF EXISTS sp_role_get $$
CREATE PROCEDURE sp_role_get(IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  SELECT r.id, r.code, r.name, r.description, r.data_scope AS dataScope,
         r.is_system AS isSystem, r.is_active AS isActive, r.row_version AS rowVersion,
         r.created_at AS createdAt, r.updated_at AS updatedAt,
         (SELECT COUNT(*) FROM user_role ur JOIN `user` u ON u.id = ur.user_id
           WHERE ur.role_id = r.id AND u.status <> 'INACTIVE') AS userCount
    FROM role r
   WHERE r.id = p_id;

  SELECT p.code
    FROM role_permission rp JOIN permission p ON p.id = rp.permission_id
   WHERE rp.role_id = p_id
   ORDER BY p.sort_order;

  SELECT module FROM role_module_scope WHERE role_id = p_id ORDER BY module;
END $$

-- Internal: validate the permission codes and module scopes of a role
DROP PROCEDURE IF EXISTS spi_validate_role_payload $$
CREATE PROCEDURE spi_validate_role_payload(IN p_data_scope VARCHAR(20), IN p_permission_codes JSON, IN p_module_scopes JSON)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_requested INT DEFAULT 0;
  DECLARE v_valid     INT DEFAULT 0;
  DECLARE v_modules   INT DEFAULT 0;
  DECLARE v_bad       INT DEFAULT 0;

  IF p_data_scope NOT IN ('OWN_AND_TEAM', 'ASSIGNED_AND_TEAM', 'PARTNER_OWNED', 'MODULE_LIMITED', 'ALL') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown data scope.', 'dataScope');
  END IF;

  IF p_permission_codes IS NULL OR JSON_TYPE(p_permission_codes) <> 'ARRAY' THEN
    CALL spi_raise('VALIDATION_FAILED', 'Permission codes must be a list.', 'permissionCodes');
  END IF;
  SELECT COUNT(DISTINCT jt.code) INTO v_requested
    FROM JSON_TABLE(p_permission_codes, '$[*]' COLUMNS (code VARCHAR(80) PATH '$')) jt;
  SELECT COUNT(DISTINCT p.id) INTO v_valid
    FROM JSON_TABLE(p_permission_codes, '$[*]' COLUMNS (code VARCHAR(80) PATH '$')) jt
    JOIN permission p ON p.code = jt.code;
  IF v_valid <> v_requested THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown permission code.', 'permissionCodes');
  END IF;

  IF p_module_scopes IS NOT NULL AND JSON_TYPE(p_module_scopes) = 'ARRAY' THEN
    SELECT COUNT(*), SUM(jt.module NOT IN ('LEADS', 'OPPORTUNITIES', 'ACCOUNTS', 'PARTNERS', 'TENDERS', 'ORDERS'))
      INTO v_modules, v_bad
      FROM JSON_TABLE(p_module_scopes, '$[*]' COLUMNS (module VARCHAR(40) PATH '$')) jt;
  END IF;
  IF IFNULL(v_bad, 0) > 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown module in the module scope.', 'moduleScopes');
  END IF;
  IF p_data_scope = 'MODULE_LIMITED' AND v_modules = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose at least one module for a module-limited role.', 'moduleScopes');
  END IF;
END $$

DROP PROCEDURE IF EXISTS sp_role_create $$
CREATE PROCEDURE sp_role_create(
  IN p_actor_user_id    BIGINT UNSIGNED,
  IN p_request_id       VARCHAR(64),
  IN p_ip               VARCHAR(45),
  IN p_code             VARCHAR(40),
  IN p_name             VARCHAR(100),
  IN p_description      VARCHAR(500),
  IN p_data_scope       VARCHAR(20),
  IN p_permission_codes JSON,
  IN p_module_scopes    JSON
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_now     DATETIME(3) DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_role_id BIGINT UNSIGNED;
  DECLARE v_code    VARCHAR(40) DEFAULT UPPER(TRIM(p_code));
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_validate_role_payload(p_data_scope, p_permission_codes, p_module_scopes);

  START TRANSACTION;
  IF EXISTS (SELECT 1 FROM role WHERE code = v_code) THEN
    CALL spi_raise('DUPLICATE', 'A role with this code already exists.', 'code');
  END IF;
  IF EXISTS (SELECT 1 FROM role WHERE name = TRIM(p_name)) THEN
    CALL spi_raise('DUPLICATE', 'A role with this name already exists.', 'name');
  END IF;

  INSERT INTO role (code, name, description, data_scope, is_system, is_active, created_at, created_by)
  VALUES (v_code, TRIM(p_name), NULLIF(TRIM(p_description), ''), p_data_scope, 0, 1, v_now, p_actor_user_id);
  SET v_role_id = LAST_INSERT_ID();

  INSERT INTO role_permission (role_id, permission_id, created_at, created_by)
  SELECT DISTINCT v_role_id, p.id, v_now, p_actor_user_id
    FROM JSON_TABLE(p_permission_codes, '$[*]' COLUMNS (code VARCHAR(80) PATH '$')) jt
    JOIN permission p ON p.code = jt.code;

  IF p_data_scope = 'MODULE_LIMITED' THEN
    INSERT INTO role_module_scope (role_id, module, created_at, created_by)
    SELECT DISTINCT v_role_id, jt.module, v_now, p_actor_user_id
      FROM JSON_TABLE(p_module_scopes, '$[*]' COLUMNS (module VARCHAR(40) PATH '$')) jt;
  END IF;

  CALL spi_audit_write('ROLE', v_role_id, 'CREATE',
       JSON_OBJECT('code',            JSON_OBJECT('from', NULL, 'to', v_code),
                   'name',            JSON_OBJECT('from', NULL, 'to', TRIM(p_name)),
                   'dataScope',       JSON_OBJECT('from', NULL, 'to', p_data_scope),
                   'permissionCodes', JSON_OBJECT('from', NULL, 'to', p_permission_codes)),
       NULL, p_actor_user_id, p_ip, p_request_id);
  CALL spi_security_event('ROLE_CREATED', p_actor_user_id, NULL, p_ip, NULL, p_request_id,
                          JSON_OBJECT('roleId', v_role_id, 'code', v_code));
  COMMIT;
  CALL sp_role_get(v_role_id);
END $$

DROP PROCEDURE IF EXISTS sp_role_update $$
CREATE PROCEDURE sp_role_update(
  IN p_actor_user_id    BIGINT UNSIGNED,
  IN p_request_id       VARCHAR(64),
  IN p_ip               VARCHAR(45),
  IN p_id               BIGINT UNSIGNED,
  IN p_row_version      INT UNSIGNED,
  IN p_name             VARCHAR(100),
  IN p_description      VARCHAR(500),
  IN p_data_scope       VARCHAR(20),
  IN p_is_active        TINYINT,
  IN p_permission_codes JSON,
  IN p_module_scopes    JSON
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_now         DATETIME(3)     DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_found       BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_code        VARCHAR(40);
  DECLARE v_name        VARCHAR(100);
  DECLARE v_description VARCHAR(500);
  DECLARE v_data_scope  VARCHAR(20);
  DECLARE v_is_active   TINYINT;
  DECLARE v_is_system   TINYINT;
  DECLARE v_row_version INT UNSIGNED;
  DECLARE v_added       TEXT;
  DECLARE v_removed     TEXT;
  DECLARE v_old_modules VARCHAR(500);
  DECLARE v_new_modules VARCHAR(500);
  DECLARE v_changes     JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_validate_role_payload(p_data_scope, p_permission_codes, p_module_scopes);

  START TRANSACTION;
  SELECT id, code, name, description, data_scope, is_active, is_system, row_version
    INTO v_found, v_code, v_name, v_description, v_data_scope, v_is_active, v_is_system, v_row_version
    FROM role WHERE id = p_id FOR UPDATE;

  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Role not found.', 'id');
  END IF;
  IF v_row_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This role was changed by someone else. Reload and try again.', 'rowVersion');
  END IF;
  IF v_is_system = 1 AND IFNULL(p_is_active, 1) = 0 THEN
    CALL spi_raise('BUSINESS_RULE_VIOLATION', 'System roles cannot be deactivated.', 'isActive');
  END IF;
  IF EXISTS (SELECT 1 FROM role WHERE name = TRIM(p_name) AND id <> p_id) THEN
    CALL spi_raise('DUPLICATE', 'A role with this name already exists.', 'name');
  END IF;
  IF v_code = 'CRM_ADMIN' THEN
    IF p_data_scope <> 'ALL' THEN
      CALL spi_raise('BUSINESS_RULE_VIOLATION', 'The CRM Admin role must keep the ALL data scope.', 'dataScope');
    END IF;
    IF NOT JSON_CONTAINS(p_permission_codes, JSON_QUOTE('user.manage'))
       OR NOT JSON_CONTAINS(p_permission_codes, JSON_QUOTE('role.manage')) THEN
      CALL spi_raise('BUSINESS_RULE_VIOLATION', 'The CRM Admin role must keep user.manage and role.manage.', 'permissionCodes');
    END IF;
  END IF;

  SELECT GROUP_CONCAT(DISTINCT jt.code ORDER BY jt.code) INTO v_added
    FROM JSON_TABLE(p_permission_codes, '$[*]' COLUMNS (code VARCHAR(80) PATH '$')) jt
    JOIN permission p ON p.code = jt.code
   WHERE NOT EXISTS (SELECT 1 FROM role_permission rp WHERE rp.role_id = p_id AND rp.permission_id = p.id);
  SELECT GROUP_CONCAT(p.code ORDER BY p.code) INTO v_removed
    FROM role_permission rp JOIN permission p ON p.id = rp.permission_id
   WHERE rp.role_id = p_id
     AND p.code NOT IN (SELECT jt.code FROM JSON_TABLE(p_permission_codes, '$[*]' COLUMNS (code VARCHAR(80) PATH '$')) jt);
  SELECT GROUP_CONCAT(module ORDER BY module) INTO v_old_modules FROM role_module_scope WHERE role_id = p_id;
  IF p_data_scope = 'MODULE_LIMITED' THEN
    SELECT GROUP_CONCAT(DISTINCT jt.module ORDER BY jt.module) INTO v_new_modules
      FROM JSON_TABLE(p_module_scopes, '$[*]' COLUMNS (module VARCHAR(40) PATH '$')) jt;
  END IF;

  CALL spi_diff(v_changes, 'name',         v_name,        TRIM(p_name));
  CALL spi_diff(v_changes, 'description',  v_description, NULLIF(TRIM(p_description), ''));
  CALL spi_diff(v_changes, 'dataScope',    v_data_scope,  p_data_scope);
  CALL spi_diff(v_changes, 'isActive',     v_is_active,   IFNULL(p_is_active, 1));
  CALL spi_diff(v_changes, 'moduleScopes', v_old_modules, v_new_modules);
  IF v_added IS NOT NULL OR v_removed IS NOT NULL THEN
    SET v_changes = JSON_SET(v_changes, '$.permissionCodes', JSON_OBJECT('added', v_added, 'removed', v_removed));
  END IF;

  UPDATE role
     SET name = TRIM(p_name), description = NULLIF(TRIM(p_description), ''), data_scope = p_data_scope,
         is_active = IFNULL(p_is_active, 1), row_version = row_version + 1,
         updated_at = v_now, updated_by = p_actor_user_id
   WHERE id = p_id;

  DELETE FROM role_permission
   WHERE role_id = p_id
     AND permission_id NOT IN (SELECT p.id
                                 FROM JSON_TABLE(p_permission_codes, '$[*]' COLUMNS (code VARCHAR(80) PATH '$')) jt
                                 JOIN permission p ON p.code = jt.code);
  INSERT IGNORE INTO role_permission (role_id, permission_id, created_at, created_by)
  SELECT DISTINCT p_id, p.id, v_now, p_actor_user_id
    FROM JSON_TABLE(p_permission_codes, '$[*]' COLUMNS (code VARCHAR(80) PATH '$')) jt
    JOIN permission p ON p.code = jt.code;

  DELETE FROM role_module_scope WHERE role_id = p_id;
  IF p_data_scope = 'MODULE_LIMITED' THEN
    INSERT INTO role_module_scope (role_id, module, created_at, created_by)
    SELECT DISTINCT p_id, jt.module, v_now, p_actor_user_id
      FROM JSON_TABLE(p_module_scopes, '$[*]' COLUMNS (module VARCHAR(40) PATH '$')) jt;
  END IF;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write('ROLE', p_id, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
    CALL spi_security_event('ROLE_UPDATED', p_actor_user_id, NULL, p_ip, NULL, p_request_id,
                            JSON_OBJECT('roleId', p_id, 'code', v_code));
  END IF;
  IF v_added IS NOT NULL OR v_removed IS NOT NULL THEN
    CALL spi_security_event('ROLE_PERMISSIONS_CHANGED', p_actor_user_id, NULL, p_ip, NULL, p_request_id,
                            JSON_OBJECT('roleId', p_id, 'code', v_code, 'added', v_added, 'removed', v_removed));
  END IF;

  COMMIT;
  CALL sp_role_get(p_id);
END $$

-- -----------------------------------------------------------------------------
-- Audit readers (18.5). Dates are UTC; p_to is exclusive.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_audit_log_list $$
CREATE PROCEDURE sp_audit_log_list(
  IN p_entity_type VARCHAR(40),
  IN p_entity_id   VARCHAR(80),
  IN p_user_id     BIGINT UNSIGNED,
  IN p_action      VARCHAR(30),
  IN p_from        DATETIME(3),
  IN p_to          DATETIME(3),
  IN p_offset      INT,
  IN p_limit       INT
)
  SQL SECURITY DEFINER
BEGIN
  SELECT a.id, a.entity_type AS entityType, a.entity_id AS entityId, a.action,
         a.changed_fields_json AS changes, a.reason, a.user_id AS userId, u.full_name AS userName,
         a.ip_address AS ipAddress, a.request_id AS requestId, a.occurred_at AS occurredAt
    FROM audit_log a
    LEFT JOIN `user` u ON u.id = a.user_id
   WHERE (p_entity_type IS NULL OR a.entity_type = p_entity_type)
     AND (p_entity_id IS NULL OR a.entity_id = p_entity_id)
     AND (p_user_id IS NULL OR a.user_id = p_user_id)
     AND (p_action IS NULL OR a.action = p_action)
     AND (p_from IS NULL OR a.occurred_at >= p_from)
     AND (p_to IS NULL OR a.occurred_at < p_to)
   ORDER BY a.occurred_at DESC, a.id DESC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total
    FROM audit_log a
   WHERE (p_entity_type IS NULL OR a.entity_type = p_entity_type)
     AND (p_entity_id IS NULL OR a.entity_id = p_entity_id)
     AND (p_user_id IS NULL OR a.user_id = p_user_id)
     AND (p_action IS NULL OR a.action = p_action)
     AND (p_from IS NULL OR a.occurred_at >= p_from)
     AND (p_to IS NULL OR a.occurred_at < p_to);
END $$

DROP PROCEDURE IF EXISTS sp_security_event_list $$
CREATE PROCEDURE sp_security_event_list(
  IN p_event_code VARCHAR(50),
  IN p_user_id    BIGINT UNSIGNED,
  IN p_from       DATETIME(3),
  IN p_to         DATETIME(3),
  IN p_offset     INT,
  IN p_limit      INT
)
  SQL SECURITY DEFINER
  COMMENT 'p_user_id matches the actor or the target user'
BEGIN
  SELECT e.id, e.event_code AS eventCode, e.user_id AS userId, u.full_name AS userName,
         e.target_user_id AS targetUserId, t.full_name AS targetUserName,
         e.ip_address AS ipAddress, e.user_agent AS userAgent, e.request_id AS requestId,
         e.detail_json AS detail, e.occurred_at AS occurredAt
    FROM security_event_log e
    LEFT JOIN `user` u ON u.id = e.user_id
    LEFT JOIN `user` t ON t.id = e.target_user_id
   WHERE (p_event_code IS NULL OR e.event_code = p_event_code)
     AND (p_user_id IS NULL OR e.user_id = p_user_id OR e.target_user_id = p_user_id)
     AND (p_from IS NULL OR e.occurred_at >= p_from)
     AND (p_to IS NULL OR e.occurred_at < p_to)
   ORDER BY e.occurred_at DESC, e.id DESC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total
    FROM security_event_log e
   WHERE (p_event_code IS NULL OR e.event_code = p_event_code)
     AND (p_user_id IS NULL OR e.user_id = p_user_id OR e.target_user_id = p_user_id)
     AND (p_from IS NULL OR e.occurred_at >= p_from)
     AND (p_to IS NULL OR e.occurred_at < p_to);
END $$

DROP PROCEDURE IF EXISTS sp_record_access_log_list $$
CREATE PROCEDURE sp_record_access_log_list(
  IN p_entity_type VARCHAR(40),
  IN p_entity_id   BIGINT UNSIGNED,
  IN p_user_id     BIGINT UNSIGNED,
  IN p_access_type VARCHAR(10),
  IN p_from        DATETIME(3),
  IN p_to          DATETIME(3),
  IN p_offset      INT,
  IN p_limit       INT
)
  SQL SECURITY DEFINER
BEGIN
  SELECT r.id, r.entity_type AS entityType, r.entity_id AS entityId, r.user_id AS userId,
         u.full_name AS userName, r.access_type AS accessType, r.detail,
         r.ip_address AS ipAddress, r.request_id AS requestId, r.occurred_at AS occurredAt
    FROM record_access_log r
    LEFT JOIN `user` u ON u.id = r.user_id
   WHERE (p_entity_type IS NULL OR r.entity_type = p_entity_type)
     AND (p_entity_id IS NULL OR r.entity_id = p_entity_id)
     AND (p_user_id IS NULL OR r.user_id = p_user_id)
     AND (p_access_type IS NULL OR r.access_type = p_access_type)
     AND (p_from IS NULL OR r.occurred_at >= p_from)
     AND (p_to IS NULL OR r.occurred_at < p_to)
   ORDER BY r.occurred_at DESC, r.id DESC
   LIMIT p_offset, p_limit;

  SELECT COUNT(*) AS total
    FROM record_access_log r
   WHERE (p_entity_type IS NULL OR r.entity_type = p_entity_type)
     AND (p_entity_id IS NULL OR r.entity_id = p_entity_id)
     AND (p_user_id IS NULL OR r.user_id = p_user_id)
     AND (p_access_type IS NULL OR r.access_type = p_access_type)
     AND (p_from IS NULL OR r.occurred_at >= p_from)
     AND (p_to IS NULL OR r.occurred_at < p_to);
END $$

DELIMITER ;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V005', 'Administration stored procedures', 'V005__sp_admin.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
