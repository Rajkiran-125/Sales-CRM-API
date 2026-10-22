-- =============================================================================
-- V004  Sales CRM - authentication stored procedures (M01)        (2026-10-09)
--
-- Business rules of tech doc 10.2-10.7 live here: login outcome, lockout and
-- automatic unlock, refresh-token rotation with reuse detection, logout,
-- logout everywhere, sessions, password change, reset and invitation links.
--
-- The API keeps only what MySQL cannot do: password hashing / verification
-- (Argon2id), JWT signing, generating random tokens (only their SHA-256 hashes
-- reach the database) and the password-strength policy.
--
-- Outcome-style procedures (sp_auth_login, sp_auth_refresh) COMMIT and return
-- an `outcome` column instead of raising an error, because a failed login must
-- still persist its failure counter and audit rows.
--
-- Re-runnable. Prerequisite: V001-V003. Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- sp_auth_get_login_user: the hash to verify (the API verifies it in constant time)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_auth_get_login_user $$
CREATE PROCEDURE sp_auth_get_login_user(IN p_email VARCHAR(150))
  SQL SECURITY DEFINER
BEGIN
  SELECT id, password_hash AS passwordHash
    FROM `user`
   WHERE email = LOWER(TRIM(p_email));
END $$

-- -----------------------------------------------------------------------------
-- sp_auth_login: decide the login outcome (10.2) and record it
--   outcome = SUCCESS | INVALID_CREDENTIALS   (one generic failure, OD-06)
--   lockedNow = 1 when this attempt locked the account (API emails the user)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_auth_login $$
CREATE PROCEDURE sp_auth_login(
  IN p_email               VARCHAR(150),
  IN p_password_ok         TINYINT,
  IN p_refresh_hash        CHAR(64),
  IN p_family_id           CHAR(36),
  IN p_refresh_ttl_minutes INT,
  IN p_ip                  VARCHAR(45),
  IN p_user_agent          VARCHAR(255),
  IN p_request_id          VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_now          DATETIME(3)       DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_email        VARCHAR(150)      DEFAULT LEFT(LOWER(TRIM(p_email)), 150);
  DECLARE v_user_id      BIGINT UNSIGNED   DEFAULT NULL;
  DECLARE v_status       VARCHAR(10)       DEFAULT NULL;
  DECLARE v_failed       SMALLINT UNSIGNED DEFAULT 0;
  DECLARE v_locked_until DATETIME(3)       DEFAULT NULL;
  DECLARE v_threshold    INT;
  DECLARE v_lock_minutes INT;
  DECLARE v_outcome      VARCHAR(30)       DEFAULT 'INVALID_CREDENTIALS';
  DECLARE v_reason       VARCHAR(30)       DEFAULT NULL;
  DECLARE v_locked_now   TINYINT           DEFAULT 0;
  DECLARE v_session_end  DATETIME(3)       DEFAULT NULL;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_setting_int('auth.lockout.threshold', 5, v_threshold);
  CALL spi_setting_int('auth.lockout.minutes', 15, v_lock_minutes);

  START TRANSACTION;

  SELECT id, status, failed_login_count, locked_until
    INTO v_user_id, v_status, v_failed, v_locked_until
    FROM `user`
   WHERE email = v_email
     FOR UPDATE;

  -- automatic unlock once the lock period is over (10.5)
  IF v_user_id IS NOT NULL AND v_status = 'LOCKED' AND v_locked_until IS NOT NULL AND v_locked_until <= v_now THEN
    UPDATE `user`
       SET status = 'ACTIVE', failed_login_count = 0, locked_until = NULL, updated_at = v_now
     WHERE id = v_user_id;
    CALL spi_security_event('ACCOUNT_UNLOCKED', NULL, v_user_id, p_ip, p_user_agent, p_request_id,
                            JSON_OBJECT('by', 'TIMEOUT'));
    SET v_status = 'ACTIVE', v_failed = 0, v_locked_until = NULL;
  END IF;

  IF v_user_id IS NULL THEN
    SET v_reason = 'UNKNOWN_USER';
  ELSEIF v_status = 'LOCKED' THEN
    SET v_reason = 'ACCOUNT_LOCKED';
  ELSEIF v_status <> 'ACTIVE' THEN
    SET v_reason = CONCAT('ACCOUNT_', v_status);
  ELSEIF IFNULL(p_password_ok, 0) <> 1 THEN
    SET v_reason = 'BAD_PASSWORD';
    SET v_failed = v_failed + 1;
    IF v_failed >= v_threshold THEN
      SET v_locked_until = v_now + INTERVAL v_lock_minutes MINUTE;
      SET v_locked_now = 1;
      UPDATE `user`
         SET failed_login_count = v_failed, status = 'LOCKED', locked_until = v_locked_until, updated_at = v_now
       WHERE id = v_user_id;
      CALL spi_security_event('ACCOUNT_LOCKED', NULL, v_user_id, p_ip, p_user_agent, p_request_id,
                              JSON_OBJECT('failedAttempts', v_failed, 'lockedUntil', v_locked_until));
    ELSE
      UPDATE `user` SET failed_login_count = v_failed WHERE id = v_user_id;
    END IF;
  ELSE
    SET v_outcome = 'SUCCESS';
    SET v_session_end = v_now + INTERVAL p_refresh_ttl_minutes MINUTE;
    UPDATE `user`
       SET failed_login_count = 0, locked_until = NULL, last_login_at = v_now
     WHERE id = v_user_id;
    INSERT INTO refresh_token (user_id, token_hash, family_id, issued_at, expires_at, ip_address, user_agent)
    VALUES (v_user_id, p_refresh_hash, p_family_id, v_now, v_session_end, p_ip, LEFT(p_user_agent, 255));
  END IF;

  INSERT INTO login_attempt (email_attempted, user_id, success, failure_reason, ip_address, user_agent, request_id, attempted_at)
  VALUES (v_email, v_user_id, IF(v_outcome = 'SUCCESS', 1, 0), v_reason, p_ip, LEFT(p_user_agent, 255), p_request_id, v_now);

  CALL spi_security_event(IF(v_outcome = 'SUCCESS', 'LOGIN_SUCCESS', 'LOGIN_FAILED'), v_user_id, NULL,
                          p_ip, p_user_agent, p_request_id,
                          IF(v_reason IS NULL, NULL, JSON_OBJECT('reason', v_reason)));

  COMMIT;

  SELECT v_outcome    AS outcome,
         v_reason     AS failureReason,
         v_locked_now AS lockedNow,
         v_locked_until AS lockedUntil,
         v_failed     AS failedAttempts,
         v_session_end AS sessionExpiresAt,
         u.id         AS userId,
         u.email      AS email,
         u.full_name  AS fullName,
         u.token_version AS tokenVersion,
         u.must_change_password AS mustChangePassword
    FROM (SELECT 1 AS one) x
    LEFT JOIN `user` u ON u.id = v_user_id;
END $$

-- -----------------------------------------------------------------------------
-- sp_auth_refresh: rotate a refresh token (10.4)
--   outcome = SUCCESS | INVALID | EXPIRED | REUSED | RACE | INACTIVE
--   REUSED: a rotated token came back -> whole family revoked (theft signal)
--   RACE:   rotated less than 10 s ago (two tabs refreshing) -> family kept
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_auth_refresh $$
CREATE PROCEDURE sp_auth_refresh(
  IN p_old_hash   CHAR(64),
  IN p_new_hash   CHAR(64),
  IN p_ip         VARCHAR(45),
  IN p_user_agent VARCHAR(255),
  IN p_request_id VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_now          DATETIME(3)     DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_id           BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_user_id      BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_replaced_by  BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_family       CHAR(36)        DEFAULT NULL;
  DECLARE v_expires      DATETIME(3)     DEFAULT NULL;
  DECLARE v_revoked      DATETIME(3)     DEFAULT NULL;
  DECLARE v_status       VARCHAR(10)     DEFAULT NULL;
  DECLARE v_locked_until DATETIME(3)     DEFAULT NULL;
  DECLARE v_outcome      VARCHAR(20)     DEFAULT 'INVALID';
  DECLARE v_new_id       BIGINT UNSIGNED DEFAULT NULL;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;

  SELECT id, user_id, family_id, expires_at, revoked_at, replaced_by_id
    INTO v_id, v_user_id, v_family, v_expires, v_revoked, v_replaced_by
    FROM refresh_token
   WHERE token_hash = p_old_hash
     FOR UPDATE;

  IF v_id IS NULL THEN
    SET v_outcome = 'INVALID';
  ELSEIF v_revoked IS NOT NULL THEN
    IF v_replaced_by IS NOT NULL AND v_revoked > v_now - INTERVAL 10 SECOND THEN
      SET v_outcome = 'RACE';
    ELSEIF v_replaced_by IS NOT NULL THEN
      SET v_outcome = 'REUSED';
      UPDATE refresh_token
         SET revoked_at = v_now, revoked_reason = 'REUSE_DETECTED'
       WHERE family_id = v_family AND revoked_at IS NULL;
      CALL spi_security_event('REFRESH_TOKEN_REUSE', v_user_id, NULL, p_ip, p_user_agent, p_request_id,
                              JSON_OBJECT('familyId', v_family));
    ELSE
      SET v_outcome = 'INVALID';
    END IF;
  ELSEIF v_expires <= v_now THEN
    SET v_outcome = 'EXPIRED';
    UPDATE refresh_token SET revoked_at = v_now, revoked_reason = 'EXPIRED' WHERE id = v_id;
  ELSE
    SELECT status, locked_until INTO v_status, v_locked_until FROM `user` WHERE id = v_user_id;
    IF v_status = 'ACTIVE' OR (v_status = 'LOCKED' AND v_locked_until IS NOT NULL AND v_locked_until <= v_now) THEN
      INSERT INTO refresh_token (user_id, token_hash, family_id, issued_at, expires_at, ip_address, user_agent)
      VALUES (v_user_id, p_new_hash, v_family, v_now, v_expires, p_ip, LEFT(p_user_agent, 255));
      SET v_new_id = LAST_INSERT_ID();
      UPDATE refresh_token
         SET revoked_at = v_now, revoked_reason = 'ROTATED', replaced_by_id = v_new_id, last_used_at = v_now
       WHERE id = v_id;
      SET v_outcome = 'SUCCESS';
    ELSE
      UPDATE refresh_token
         SET revoked_at = v_now, revoked_reason = 'USER_NOT_ACTIVE'
       WHERE family_id = v_family AND revoked_at IS NULL;
      SET v_outcome = 'INACTIVE';
    END IF;
  END IF;

  COMMIT;

  SELECT v_outcome AS outcome,
         u.id AS userId,
         u.token_version AS tokenVersion,
         u.must_change_password AS mustChangePassword,
         IF(v_outcome = 'SUCCESS', v_expires, NULL) AS sessionExpiresAt
    FROM (SELECT 1 AS one) x
    LEFT JOIN `user` u ON u.id = IF(v_outcome = 'SUCCESS', v_user_id, NULL);
END $$

-- -----------------------------------------------------------------------------
-- sp_auth_logout: end the current session (refresh-token family) (10.3)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_auth_logout $$
CREATE PROCEDURE sp_auth_logout(
  IN p_user_id      BIGINT UNSIGNED,
  IN p_refresh_hash CHAR(64),
  IN p_ip           VARCHAR(45),
  IN p_user_agent   VARCHAR(255),
  IN p_request_id   VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_family CHAR(36) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT family_id INTO v_family
    FROM refresh_token
   WHERE token_hash = p_refresh_hash AND user_id = p_user_id;

  IF v_family IS NOT NULL THEN
    UPDATE refresh_token
       SET revoked_at = UTC_TIMESTAMP(3), revoked_reason = 'LOGOUT'
     WHERE family_id = v_family AND revoked_at IS NULL;
  END IF;

  CALL spi_security_event('LOGOUT', p_user_id, NULL, p_ip, p_user_agent, p_request_id, NULL);
  COMMIT;
END $$

-- -----------------------------------------------------------------------------
-- sp_auth_logout_all: "log out of all devices" (10.3)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_auth_logout_all $$
CREATE PROCEDURE sp_auth_logout_all(
  IN p_user_id    BIGINT UNSIGNED,
  IN p_ip         VARCHAR(45),
  IN p_user_agent VARCHAR(255),
  IN p_request_id VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  UPDATE `user` SET token_version = token_version + 1, updated_at = UTC_TIMESTAMP(3) WHERE id = p_user_id;
  UPDATE refresh_token
     SET revoked_at = UTC_TIMESTAMP(3), revoked_reason = 'LOGOUT_ALL'
   WHERE user_id = p_user_id AND revoked_at IS NULL;
  CALL spi_security_event('LOGOUT_ALL', p_user_id, NULL, p_ip, p_user_agent, p_request_id, NULL);
  COMMIT;
END $$

-- -----------------------------------------------------------------------------
-- sp_auth_user_context: user context for loadUserContext and GET /auth/me (8.4)
--   RS1 user · RS2 active roles · RS3 effective permission codes
--   RS4 MODULE_LIMITED modules · RS5 team size (people below the user)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_auth_user_context $$
CREATE PROCEDURE sp_auth_user_context(IN p_user_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  SELECT u.id, u.email, u.full_name AS fullName, u.mobile, u.designation, u.department,
         u.reporting_to_user_id AS reportingToUserId, m.full_name AS reportingToName,
         u.status, u.token_version AS tokenVersion, u.must_change_password AS mustChangePassword,
         u.locked_until AS lockedUntil, u.last_login_at AS lastLoginAt, u.password_changed_at AS passwordChangedAt
    FROM `user` u
    LEFT JOIN `user` m ON m.id = u.reporting_to_user_id
   WHERE u.id = p_user_id;

  SELECT r.id, r.code, r.name, r.data_scope AS dataScope
    FROM user_role ur
    JOIN role r ON r.id = ur.role_id AND r.is_active = 1
   WHERE ur.user_id = p_user_id
   ORDER BY r.name;

  SELECT DISTINCT p.code
    FROM user_role ur
    JOIN role r ON r.id = ur.role_id AND r.is_active = 1
    JOIN role_permission rp ON rp.role_id = r.id
    JOIN permission p ON p.id = rp.permission_id
   WHERE ur.user_id = p_user_id
   ORDER BY p.code;

  SELECT DISTINCT rms.module
    FROM user_role ur
    JOIN role r ON r.id = ur.role_id AND r.is_active = 1 AND r.data_scope = 'MODULE_LIMITED'
    JOIN role_module_scope rms ON rms.role_id = r.id
   WHERE ur.user_id = p_user_id;

  SELECT COUNT(*) AS teamSize
    FROM user_hierarchy
   WHERE ancestor_user_id = p_user_id AND depth > 0;
END $$

-- -----------------------------------------------------------------------------
-- Sessions ("My sessions")
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_auth_sessions_list $$
CREATE PROCEDURE sp_auth_sessions_list(IN p_user_id BIGINT UNSIGNED, IN p_current_refresh_hash CHAR(64))
  SQL SECURITY DEFINER
BEGIN
  SELECT a.family_id   AS id,
         f.started_at  AS startedAt,
         a.issued_at   AS lastRefreshAt,
         a.expires_at  AS expiresAt,
         a.ip_address  AS ipAddress,
         a.user_agent  AS userAgent,
         IF(a.token_hash = p_current_refresh_hash, 1, 0) AS isCurrent
    FROM refresh_token a
    JOIN (SELECT family_id, MIN(issued_at) AS started_at
            FROM refresh_token
           WHERE user_id = p_user_id
           GROUP BY family_id) f ON f.family_id = a.family_id
   WHERE a.user_id = p_user_id
     AND a.revoked_at IS NULL
     AND a.expires_at > UTC_TIMESTAMP(3)
   ORDER BY a.issued_at DESC;
END $$

DROP PROCEDURE IF EXISTS sp_auth_session_revoke $$
CREATE PROCEDURE sp_auth_session_revoke(
  IN p_user_id    BIGINT UNSIGNED,
  IN p_family_id  CHAR(36),
  IN p_ip         VARCHAR(45),
  IN p_user_agent VARCHAR(255),
  IN p_request_id VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_count INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  UPDATE refresh_token
     SET revoked_at = UTC_TIMESTAMP(3), revoked_reason = 'SESSION_REVOKED'
   WHERE user_id = p_user_id AND family_id = p_family_id AND revoked_at IS NULL;
  SET v_count = ROW_COUNT();

  IF v_count = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Session not found.', 'id');
  END IF;

  CALL spi_security_event('SESSION_REVOKED', p_user_id, NULL, p_ip, p_user_agent, p_request_id,
                          JSON_OBJECT('familyId', p_family_id));
  COMMIT;
END $$

-- -----------------------------------------------------------------------------
-- Passwords
-- -----------------------------------------------------------------------------

-- RS1 user (for the "must not contain email / name" rule) · RS2 current + recent hashes
DROP PROCEDURE IF EXISTS sp_auth_password_hashes $$
CREATE PROCEDURE sp_auth_password_hashes(IN p_user_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_history INT;
  CALL spi_setting_int('auth.password.history_count', 5, v_history);

  SELECT id, email, full_name AS fullName, status FROM `user` WHERE id = p_user_id;

  SELECT password_hash AS passwordHash, 'CURRENT' AS kind
    FROM `user`
   WHERE id = p_user_id AND password_hash IS NOT NULL
  UNION ALL
  SELECT h.password_hash, 'HISTORY'
    FROM (SELECT password_hash
            FROM password_history
           WHERE user_id = p_user_id
           ORDER BY created_at DESC, id DESC
           LIMIT v_history) h;
END $$

-- Internal: set a new password hash, keep history, reset lockout, bump token version
DROP PROCEDURE IF EXISTS spi_password_set $$
CREATE PROCEDURE spi_password_set(IN p_user_id BIGINT UNSIGNED, IN p_new_hash VARCHAR(255))
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_history INT;
  DECLARE v_now DATETIME(3) DEFAULT UTC_TIMESTAMP(3);
  CALL spi_setting_int('auth.password.history_count', 5, v_history);

  INSERT INTO password_history (user_id, password_hash, created_at)
  SELECT id, password_hash, v_now FROM `user` WHERE id = p_user_id AND password_hash IS NOT NULL;

  UPDATE `user`
     SET password_hash = p_new_hash,
         password_changed_at = v_now,
         must_change_password = 0,
         token_version = token_version + 1,
         failed_login_count = 0,
         locked_until = NULL,
         status = IF(status IN ('INVITED', 'LOCKED'), 'ACTIVE', status),
         updated_at = v_now
   WHERE id = p_user_id;

  DELETE FROM password_history
   WHERE user_id = p_user_id
     AND id NOT IN (SELECT id FROM (SELECT id
                                      FROM password_history
                                     WHERE user_id = p_user_id
                                     ORDER BY created_at DESC, id DESC
                                     LIMIT v_history) keep_rows);
END $$

-- Change own password (10.5): other sessions are signed out, the current one is kept
DROP PROCEDURE IF EXISTS sp_auth_password_change $$
CREATE PROCEDURE sp_auth_password_change(
  IN p_user_id           BIGINT UNSIGNED,
  IN p_new_hash          VARCHAR(255),
  IN p_keep_refresh_hash CHAR(64),
  IN p_ip                VARCHAR(45),
  IN p_user_agent        VARCHAR(255),
  IN p_request_id        VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_status      VARCHAR(10) DEFAULT NULL;
  DECLARE v_keep_family CHAR(36)    DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT status INTO v_status FROM `user` WHERE id = p_user_id FOR UPDATE;
  IF v_status IS NULL OR v_status <> 'ACTIVE' THEN
    CALL spi_raise('FORBIDDEN', 'The account is not active.', NULL);
  END IF;

  SELECT family_id INTO v_keep_family
    FROM refresh_token
   WHERE token_hash = p_keep_refresh_hash AND user_id = p_user_id AND revoked_at IS NULL;

  CALL spi_password_set(p_user_id, p_new_hash);

  UPDATE refresh_token
     SET revoked_at = UTC_TIMESTAMP(3), revoked_reason = 'PASSWORD_CHANGED'
   WHERE user_id = p_user_id AND revoked_at IS NULL
     AND (v_keep_family IS NULL OR family_id <> v_keep_family);

  CALL spi_security_event('PASSWORD_CHANGED', p_user_id, p_user_id, p_ip, p_user_agent, p_request_id, NULL);
  COMMIT;

  SELECT id, email, full_name AS fullName, token_version AS tokenVersion
    FROM `user` WHERE id = p_user_id;
END $$

-- -----------------------------------------------------------------------------
-- Reset and invitation links (10.5, 10.6). Purpose-bound, single use, hashed.
--   Self-service (p_actor_user_id NULL): an ineligible / unknown user returns an
--   empty result, so the API can always answer "if the account exists ..." (202).
--   Admin action (p_actor_user_id set): an ineligible user raises an error.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_auth_link_token_create $$
CREATE PROCEDURE sp_auth_link_token_create(
  IN p_purpose       VARCHAR(10),
  IN p_email         VARCHAR(150),
  IN p_user_id       BIGINT UNSIGNED,
  IN p_token_hash    CHAR(64),
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_ip            VARCHAR(45),
  IN p_request_id    VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_now       DATETIME(3)     DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_user_id   BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_status    VARCHAR(10)     DEFAULT NULL;
  DECLARE v_minutes   INT             DEFAULT NULL;
  DECLARE v_hours     INT             DEFAULT NULL;
  DECLARE v_eligible  TINYINT         DEFAULT 0;
  DECLARE v_expires   DATETIME(3)     DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_purpose NOT IN ('RESET', 'INVITE') THEN
    CALL spi_raise('BAD_REQUEST', 'Unknown link purpose.', 'purpose');
  END IF;

  IF p_purpose = 'RESET' THEN
    CALL spi_setting_int('auth.reset_token.minutes', 30, v_minutes);
  ELSE
    CALL spi_setting_int('auth.invite_token.hours', 72, v_hours);
    SET v_minutes = v_hours * 60;
  END IF;

  START TRANSACTION;

  IF p_user_id IS NOT NULL THEN
    SELECT id, status INTO v_user_id, v_status FROM `user` WHERE id = p_user_id FOR UPDATE;
  ELSE
    SELECT id, status INTO v_user_id, v_status FROM `user` WHERE email = LOWER(TRIM(p_email)) FOR UPDATE;
  END IF;

  SET v_eligible = CASE
                     WHEN v_user_id IS NULL THEN 0
                     WHEN p_purpose = 'RESET'  AND v_status IN ('ACTIVE', 'LOCKED') THEN 1
                     WHEN p_purpose = 'INVITE' AND v_status = 'INVITED' THEN 1
                     ELSE 0
                   END;

  IF v_eligible = 0 AND p_actor_user_id IS NOT NULL THEN
    IF v_user_id IS NULL THEN
      CALL spi_raise('NOT_FOUND', 'User not found.', 'id');
    ELSEIF p_purpose = 'RESET' THEN
      CALL spi_raise('BUSINESS_RULE_VIOLATION', 'A password reset can be sent only to an active or locked user.', NULL);
    ELSE
      CALL spi_raise('BUSINESS_RULE_VIOLATION', 'An invitation can be resent only to a user who has not accepted it yet.', NULL);
    END IF;
  END IF;

  IF v_eligible = 1 THEN
    SET v_expires = v_now + INTERVAL v_minutes MINUTE;

    UPDATE password_reset_token
       SET invalidated_at = v_now
     WHERE user_id = v_user_id AND purpose = p_purpose AND used_at IS NULL AND invalidated_at IS NULL;

    INSERT INTO password_reset_token (user_id, token_hash, purpose, expires_at, requested_ip, created_at, created_by)
    VALUES (v_user_id, p_token_hash, p_purpose, v_expires, p_ip, v_now, p_actor_user_id);

    CALL spi_security_event(IF(p_purpose = 'RESET', 'PASSWORD_RESET_REQUESTED', 'INVITATION_SENT'),
                            IFNULL(p_actor_user_id, v_user_id), v_user_id, p_ip, NULL, p_request_id,
                            JSON_OBJECT('byAdmin', p_actor_user_id IS NOT NULL));
  END IF;

  COMMIT;

  SELECT u.id AS userId, u.email, u.full_name AS fullName, v_expires AS expiresAt, v_minutes AS expiresInMinutes
    FROM `user` u
   WHERE v_eligible = 1 AND u.id = v_user_id;
END $$

-- Look a link up without using it (to show the form and run the password policy)
DROP PROCEDURE IF EXISTS sp_auth_link_token_peek $$
CREATE PROCEDURE sp_auth_link_token_peek(IN p_token_hash CHAR(64), IN p_purpose VARCHAR(10))
  SQL SECURITY DEFINER
BEGIN
  SELECT u.id AS userId, u.email, u.full_name AS fullName, t.expires_at AS expiresAt
    FROM password_reset_token t
    JOIN `user` u ON u.id = t.user_id
   WHERE t.token_hash = p_token_hash
     AND t.purpose = p_purpose
     AND t.used_at IS NULL
     AND t.invalidated_at IS NULL
     AND t.expires_at > UTC_TIMESTAMP(3)
     AND ((p_purpose = 'INVITE' AND u.status = 'INVITED')
       OR (p_purpose = 'RESET'  AND u.status IN ('ACTIVE', 'LOCKED')));
END $$

-- Use a link: set the password, sign out everywhere, activate an invited user
DROP PROCEDURE IF EXISTS sp_auth_link_token_consume $$
CREATE PROCEDURE sp_auth_link_token_consume(
  IN p_token_hash CHAR(64),
  IN p_purpose    VARCHAR(10),
  IN p_new_hash   VARCHAR(255),
  IN p_ip         VARCHAR(45),
  IN p_user_agent VARCHAR(255),
  IN p_request_id VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_now     DATETIME(3)     DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_id      BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_user_id BIGINT UNSIGNED DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;

  SELECT t.id, t.user_id INTO v_id, v_user_id
    FROM password_reset_token t
    JOIN `user` u ON u.id = t.user_id
   WHERE t.token_hash = p_token_hash
     AND t.purpose = p_purpose
     AND t.used_at IS NULL
     AND t.invalidated_at IS NULL
     AND t.expires_at > v_now
     AND ((p_purpose = 'INVITE' AND u.status = 'INVITED')
       OR (p_purpose = 'RESET'  AND u.status IN ('ACTIVE', 'LOCKED')))
     FOR UPDATE;

  IF v_id IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'This link is invalid or has expired. Please request a new one.', 'token');
  END IF;

  UPDATE password_reset_token SET used_at = v_now WHERE id = v_id;
  UPDATE password_reset_token
     SET invalidated_at = v_now
   WHERE user_id = v_user_id AND used_at IS NULL AND invalidated_at IS NULL;

  CALL spi_password_set(v_user_id, p_new_hash);

  UPDATE refresh_token
     SET revoked_at = v_now, revoked_reason = 'PASSWORD_RESET'
   WHERE user_id = v_user_id AND revoked_at IS NULL;

  CALL spi_security_event(IF(p_purpose = 'INVITE', 'INVITATION_ACCEPTED', 'PASSWORD_RESET'),
                          v_user_id, v_user_id, p_ip, p_user_agent, p_request_id, NULL);
  COMMIT;

  SELECT id AS userId, email, full_name AS fullName FROM `user` WHERE id = v_user_id;
END $$

DELIMITER ;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V004', 'Authentication stored procedures', 'V004__sp_auth.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
