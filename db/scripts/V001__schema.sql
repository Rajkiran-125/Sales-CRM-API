-- =============================================================================
-- V001  Sales CRM - full version 1 schema                         (2026-10-09)
--
-- Creates every table of the conceptual data model (tech doc section 15):
-- identity & access, masters & configuration, accounts & contacts, partners,
-- leads, opportunities & commercial, work tracking & forecast, orders & tenders,
-- system & audit, and the phase-2 partner portal tables.
--
-- Run ONCE, on the EMPTY schema unigr8ways_sales_crm (created beforehand), as the
-- existing account that owns it, e.g. DBeaver > Execute SQL Script (Alt+X), or:
--     mysql -h <host> -P <port> -u <your_user> -p < V001__schema.sql
-- Then run V002, V003 ... in order. Every script records itself in schema_version.
--
-- Conventions (tech doc 9.1, 9.2):
--   * InnoDB, utf8mb4 / utf8mb4_0900_ai_ci, snake_case, singular table names
--   * id BIGINT UNSIGNED AUTO_INCREMENT on every table (junction tables: composite PK)
--   * money DECIMAL(16,2), percent DECIMAL(5,2), FX DECIMAL(12,6)
--   * business dates DATE; timestamps DATETIME(3) in UTC (UI shows IST, OD-28)
--   * code columns are short VARCHARs; fixed code sets have CHECK constraints,
--     admin-editable lists are FKs to master tables (no MySQL ENUM)
--   * audit columns created_at/created_by/updated_at/updated_by; row_version on
--     key entities (optimistic locking, 9.6); is_active (+ deleted_at) = soft delete
--   * FK naming fk_<table>_<column>, index ix_<table>_<cols>, unique ux_<table>_<cols>
--
-- Deviations from the tech doc names, made to avoid MySQL 8 reserved words:
--   lead            -> sales_lead     (LEAD is reserved, like ORDER -> sales_order)
--   setting.key     -> setting_key, setting.value -> setting_value
--   number_sequence.year/last_value -> seq_year/current_value
-- Additions needed by the stored-procedure design (decision log):
--   user_hierarchy (closure table of the reporting tree, 10.8 rule 1),
--   certification_type (OD-39 default "master list + other"), schema_version.
-- Not created: notification (only if OD-48 = yes; default is no).
--
-- Verify after running:
--   SELECT COUNT(*) FROM information_schema.tables
--    WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE';      -- expect 79
--   SELECT * FROM schema_version;                                        -- V001 row
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- 0. Script tracking
-- -----------------------------------------------------------------------------

CREATE TABLE schema_version (
  version       VARCHAR(10)   NOT NULL,
  description   VARCHAR(200)  NOT NULL,
  script_name   VARCHAR(200)  NOT NULL,
  applied_at    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  applied_by    VARCHAR(100)  NOT NULL DEFAULT (CURRENT_USER()),
  PRIMARY KEY (version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Database scripts applied to this schema (run manually, in order)';

-- -----------------------------------------------------------------------------
-- 1. Identity & access (15.2)
-- -----------------------------------------------------------------------------

CREATE TABLE `user` (
  id                    BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  email                 VARCHAR(150)      NOT NULL COMMENT 'Login id (OD-05), stored trimmed and lower-case',
  full_name             VARCHAR(150)      NOT NULL,
  mobile                VARCHAR(20)       NULL,
  designation           VARCHAR(100)      NULL,
  department            VARCHAR(100)      NULL,
  reporting_to_user_id  BIGINT UNSIGNED   NULL,
  status                VARCHAR(10)       NOT NULL DEFAULT 'INVITED',
  password_hash         VARCHAR(255)      NULL,
  password_changed_at   DATETIME(3)       NULL,
  must_change_password  TINYINT(1)        NOT NULL DEFAULT 0,
  failed_login_count    SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  locked_until          DATETIME(3)       NULL,
  last_login_at         DATETIME(3)       NULL,
  token_version         INT UNSIGNED      NOT NULL DEFAULT 1,
  deactivated_at        DATETIME(3)       NULL,
  deactivation_reason   VARCHAR(500)      NULL,
  created_at            DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by            BIGINT UNSIGNED   NULL,
  updated_at            DATETIME(3)       NULL,
  updated_by            BIGINT UNSIGNED   NULL,
  row_version           INT UNSIGNED      NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_user_email (email),
  KEY ix_user_reporting_to (reporting_to_user_id),
  KEY ix_user_status (status),
  CONSTRAINT fk_user_reporting_to FOREIGN KEY (reporting_to_user_id) REFERENCES `user` (id),
  CONSTRAINT fk_user_created_by   FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_user_updated_by   FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_user_status CHECK (status IN ('INVITED','ACTIVE','LOCKED','INACTIVE'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Internal CRM user; never hard-deleted (10.7)';

CREATE TABLE user_hierarchy (
  ancestor_user_id    BIGINT UNSIGNED   NOT NULL,
  descendant_user_id  BIGINT UNSIGNED   NOT NULL,
  depth               SMALLINT UNSIGNED NOT NULL COMMENT '0 = the user itself',
  PRIMARY KEY (ancestor_user_id, descendant_user_id),
  KEY ix_user_hierarchy_descendant (descendant_user_id),
  CONSTRAINT fk_user_hierarchy_ancestor   FOREIGN KEY (ancestor_user_id)   REFERENCES `user` (id),
  CONSTRAINT fk_user_hierarchy_descendant FOREIGN KEY (descendant_user_id) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Closure table of the reporting tree (data scope, 10.8); rebuilt by spi_user_hierarchy_rebuild';

CREATE TABLE password_history (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id        BIGINT UNSIGNED NOT NULL,
  password_hash  VARCHAR(255)    NOT NULL,
  created_at     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  KEY ix_password_history_user (user_id, created_at),
  CONSTRAINT fk_password_history_user FOREIGN KEY (user_id) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Previous password hashes, to prevent reuse (OD-08)';

CREATE TABLE role (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code         VARCHAR(40)     NOT NULL,
  name         VARCHAR(100)    NOT NULL,
  description  VARCHAR(500)    NULL,
  data_scope   VARCHAR(20)     NOT NULL,
  is_system    TINYINT(1)      NOT NULL DEFAULT 0,
  is_active    TINYINT(1)      NOT NULL DEFAULT 1,
  created_at   DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by   BIGINT UNSIGNED NULL,
  updated_at   DATETIME(3)     NULL,
  updated_by   BIGINT UNSIGNED NULL,
  row_version  INT UNSIGNED    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_role_code (code),
  UNIQUE KEY ux_role_name (name),
  CONSTRAINT fk_role_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_role_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_role_data_scope CHECK (data_scope IN ('OWN_AND_TEAM','ASSIGNED_AND_TEAM','PARTNER_OWNED','MODULE_LIMITED','ALL'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Role = permission bundle + data scope level (10.1, 11.1)';

CREATE TABLE permission (
  id            BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  code          VARCHAR(80)       NOT NULL COMMENT '<module>.<action>, e.g. opportunity.validate',
  module        VARCHAR(40)       NOT NULL,
  action        VARCHAR(40)       NOT NULL,
  description   VARCHAR(255)      NOT NULL,
  is_sensitive  TINYINT(1)        NOT NULL DEFAULT 0,
  sort_order    SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  created_at    DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  UNIQUE KEY ux_permission_code (code),
  KEY ix_permission_module (module)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Permission catalogue; seeded by the application, read-only for admins (11.2)';

CREATE TABLE role_permission (
  role_id        BIGINT UNSIGNED NOT NULL,
  permission_id  BIGINT UNSIGNED NOT NULL,
  created_at     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by     BIGINT UNSIGNED NULL,
  PRIMARY KEY (role_id, permission_id),
  KEY ix_role_permission_permission (permission_id),
  CONSTRAINT fk_role_permission_role       FOREIGN KEY (role_id)       REFERENCES role (id),
  CONSTRAINT fk_role_permission_permission FOREIGN KEY (permission_id) REFERENCES permission (id),
  CONSTRAINT fk_role_permission_created_by FOREIGN KEY (created_by)    REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE user_role (
  user_id      BIGINT UNSIGNED NOT NULL,
  role_id      BIGINT UNSIGNED NOT NULL,
  assigned_by  BIGINT UNSIGNED NULL,
  assigned_at  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (user_id, role_id),
  KEY ix_user_role_role (role_id),
  CONSTRAINT fk_user_role_user        FOREIGN KEY (user_id)     REFERENCES `user` (id),
  CONSTRAINT fk_user_role_role        FOREIGN KEY (role_id)     REFERENCES role (id),
  CONSTRAINT fk_user_role_assigned_by FOREIGN KEY (assigned_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='A user may hold several roles (OD-04): permissions = union, scope = widest';

CREATE TABLE role_module_scope (
  role_id     BIGINT UNSIGNED NOT NULL,
  module      VARCHAR(40)     NOT NULL,
  created_at  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED NULL,
  PRIMARY KEY (role_id, module),
  CONSTRAINT fk_role_module_scope_role       FOREIGN KEY (role_id)    REFERENCES role (id),
  CONSTRAINT fk_role_module_scope_created_by FOREIGN KEY (created_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='MODULE_LIMITED scope: modules whose records are fully visible (OD-11)';

CREATE TABLE refresh_token (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id         BIGINT UNSIGNED NOT NULL,
  token_hash      CHAR(64)        NOT NULL COMMENT 'SHA-256 hex of the opaque token; the token itself is never stored',
  family_id       CHAR(36)        NOT NULL COMMENT 'One family per login session; reuse revokes the family',
  issued_at       DATETIME(3)     NOT NULL,
  expires_at      DATETIME(3)     NOT NULL COMMENT 'Absolute expiry of the session (inherited on rotation)',
  last_used_at    DATETIME(3)     NULL,
  revoked_at      DATETIME(3)     NULL,
  revoked_reason  VARCHAR(30)     NULL,
  replaced_by_id  BIGINT UNSIGNED NULL,
  ip_address      VARCHAR(45)     NULL,
  user_agent      VARCHAR(255)    NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_refresh_token_hash (token_hash),
  KEY ix_refresh_token_user (user_id, revoked_at),
  KEY ix_refresh_token_family (family_id),
  KEY ix_refresh_token_expires (expires_at),
  CONSTRAINT fk_refresh_token_user        FOREIGN KEY (user_id)        REFERENCES `user` (id),
  CONSTRAINT fk_refresh_token_replaced_by FOREIGN KEY (replaced_by_id) REFERENCES refresh_token (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Server-side sessions: rotating refresh tokens (10.4)';

CREATE TABLE password_reset_token (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id         BIGINT UNSIGNED NOT NULL,
  token_hash      CHAR(64)        NOT NULL,
  purpose         VARCHAR(10)     NOT NULL COMMENT 'RESET or INVITE; tokens cannot be swapped between purposes',
  expires_at      DATETIME(3)     NOT NULL,
  used_at         DATETIME(3)     NULL,
  invalidated_at  DATETIME(3)     NULL,
  requested_ip    VARCHAR(45)     NULL,
  created_at      DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by      BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_password_reset_token_hash (token_hash),
  KEY ix_password_reset_token_user (user_id, purpose),
  CONSTRAINT fk_password_reset_token_user       FOREIGN KEY (user_id)    REFERENCES `user` (id),
  CONSTRAINT fk_password_reset_token_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT ck_password_reset_token_purpose CHECK (purpose IN ('RESET','INVITE'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Single-use reset and invitation links, stored hashed (10.5, 10.6)';

CREATE TABLE login_attempt (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  email_attempted  VARCHAR(150)    NOT NULL,
  user_id          BIGINT UNSIGNED NULL,
  success          TINYINT(1)      NOT NULL,
  failure_reason   VARCHAR(30)     NULL,
  ip_address       VARCHAR(45)     NULL,
  user_agent       VARCHAR(255)    NULL,
  request_id       VARCHAR(64)     NULL,
  attempted_at     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  KEY ix_login_attempt_email (email_attempted, attempted_at),
  KEY ix_login_attempt_ip (ip_address, attempted_at),
  KEY ix_login_attempt_user (user_id),
  CONSTRAINT fk_login_attempt_user FOREIGN KEY (user_id) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Throttling and forensics; retained 90 days (18.4)';

CREATE TABLE security_event_log (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  event_code      VARCHAR(50)     NOT NULL,
  user_id         BIGINT UNSIGNED NULL COMMENT 'Actor',
  target_user_id  BIGINT UNSIGNED NULL,
  ip_address      VARCHAR(45)     NULL,
  user_agent      VARCHAR(255)    NULL,
  request_id      VARCHAR(64)     NULL,
  detail_json     JSON            NULL,
  occurred_at     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  KEY ix_security_event_log_event (event_code, occurred_at),
  KEY ix_security_event_log_user (user_id, occurred_at),
  KEY ix_security_event_log_target (target_user_id),
  KEY ix_security_event_log_occurred (occurred_at),
  CONSTRAINT fk_security_event_log_user        FOREIGN KEY (user_id)        REFERENCES `user` (id),
  CONSTRAINT fk_security_event_log_target_user FOREIGN KEY (target_user_id) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Append-only security audit (10.13, 18)';

-- -----------------------------------------------------------------------------
-- 2. Masters & configuration (15.3)
-- -----------------------------------------------------------------------------

CREATE TABLE stage (
  id                      BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  entity                  VARCHAR(10)       NOT NULL,
  code                    VARCHAR(30)       NOT NULL COMMENT 'Fixed by the application (gates depend on it)',
  name                    VARCHAR(100)      NOT NULL,
  sequence_no             SMALLINT UNSIGNED NOT NULL,
  default_confidence_pct  DECIMAL(5,2)      NULL COMMENT 'Opportunity stages only (OD-03)',
  is_open                 TINYINT(1)        NOT NULL DEFAULT 1,
  is_won                  TINYINT(1)        NOT NULL DEFAULT 0,
  is_lost                 TINYINT(1)        NOT NULL DEFAULT 0,
  sla_days                SMALLINT UNSIGNED NULL COMMENT 'Ageing warning threshold (OD-47)',
  colour_token            VARCHAR(40)       NULL,
  is_active               TINYINT(1)        NOT NULL DEFAULT 1,
  created_at              DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by              BIGINT UNSIGNED   NULL,
  updated_at              DATETIME(3)       NULL,
  updated_by              BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_stage_entity_code (entity, code),
  CONSTRAINT fk_stage_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_stage_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_stage_entity CHECK (entity IN ('LEAD','OPP','TENDER','ORDER')),
  CONSTRAINT ck_stage_confidence CHECK (default_confidence_pct IS NULL OR default_confidence_pct BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Lead, opportunity, tender and order stages; names/confidence/SLA editable';

CREATE TABLE partner_type (
  id          BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  code        VARCHAR(40)       NOT NULL,
  name        VARCHAR(100)      NOT NULL,
  sort_order  SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  is_active   TINYINT(1)        NOT NULL DEFAULT 1,
  created_at  DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED   NULL,
  updated_at  DATETIME(3)       NULL,
  updated_by  BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_partner_type_code (code),
  CONSTRAINT fk_partner_type_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_partner_type_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE industry (
  id          BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  code        VARCHAR(40)       NOT NULL,
  name        VARCHAR(100)      NOT NULL,
  sort_order  SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  is_active   TINYINT(1)        NOT NULL DEFAULT 1,
  created_at  DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED   NULL,
  updated_at  DATETIME(3)       NULL,
  updated_by  BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_industry_code (code),
  CONSTRAINT fk_industry_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_industry_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE product (
  id          BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  code        VARCHAR(40)       NOT NULL,
  name        VARCHAR(100)      NOT NULL,
  sort_order  SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  is_active   TINYINT(1)        NOT NULL DEFAULT 1,
  created_at  DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED   NULL,
  updated_at  DATETIME(3)       NULL,
  updated_by  BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_product_code (code),
  CONSTRAINT fk_product_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_product_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE solution (
  id           BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  product_id   BIGINT UNSIGNED   NOT NULL,
  name         VARCHAR(150)      NOT NULL,
  description  VARCHAR(500)      NULL,
  sort_order   SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  is_active    TINYINT(1)        NOT NULL DEFAULT 1,
  created_at   DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by   BIGINT UNSIGNED   NULL,
  updated_at   DATETIME(3)       NULL,
  updated_by   BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_solution_product_name (product_id, name),
  CONSTRAINT fk_solution_product    FOREIGN KEY (product_id) REFERENCES product (id),
  CONSTRAINT fk_solution_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_solution_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Solution options per product (UM 6.2)';

CREATE TABLE reason (
  id                   BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  reason_type          VARCHAR(12)       NOT NULL,
  code                 VARCHAR(40)       NOT NULL,
  name                 VARCHAR(150)      NOT NULL,
  category             VARCHAR(100)      NULL,
  competitor_required  TINYINT(1)        NOT NULL DEFAULT 0 COMMENT 'LOSS: competitor mandatory when closing with this reason (16.3)',
  sort_order           SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  is_active            TINYINT(1)        NOT NULL DEFAULT 1,
  created_at           DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by           BIGINT UNSIGNED   NULL,
  updated_at           DATETIME(3)       NULL,
  updated_by           BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_reason_type_code (reason_type, code),
  CONSTRAINT fk_reason_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_reason_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_reason_type CHECK (reason_type IN ('WIN','LOSS','DISQUALIFY','DORMANT','NOT_VALID'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Win / loss / disqualify / dormant / not-valid reasons (UM 6.4)';

CREATE TABLE competitor (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name        VARCHAR(150)    NOT NULL,
  products    VARCHAR(500)    NULL,
  strengths   TEXT            NULL,
  weaknesses  TEXT            NULL,
  is_active   TINYINT(1)      NOT NULL DEFAULT 1,
  created_at  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED NULL,
  updated_at  DATETIME(3)     NULL,
  updated_by  BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_competitor_name (name),
  CONSTRAINT fk_competitor_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_competitor_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE procurement_type (
  id          BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  code        VARCHAR(40)       NOT NULL,
  name        VARCHAR(100)      NOT NULL,
  sort_order  SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  is_active   TINYINT(1)        NOT NULL DEFAULT 1,
  created_at  DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED   NULL,
  updated_at  DATETIME(3)       NULL,
  updated_by  BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_procurement_type_code (code),
  CONSTRAINT fk_procurement_type_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_procurement_type_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE procurement_step (
  id                   BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  procurement_type_id  BIGINT UNSIGNED   NOT NULL,
  sequence_no          SMALLINT UNSIGNED NOT NULL,
  name                 VARCHAR(150)      NOT NULL,
  hint_confidence_pct  DECIMAL(5,2)      NULL,
  is_active            TINYINT(1)        NOT NULL DEFAULT 1,
  created_at           DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by           BIGINT UNSIGNED   NULL,
  updated_at           DATETIME(3)       NULL,
  updated_by           BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_procurement_step_type_seq (procurement_type_id, sequence_no),
  CONSTRAINT fk_procurement_step_type       FOREIGN KEY (procurement_type_id) REFERENCES procurement_type (id),
  CONSTRAINT fk_procurement_step_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_procurement_step_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_procurement_step_hint CHECK (hint_confidence_pct IS NULL OR hint_confidence_pct BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE document_type (
  id          BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  code        VARCHAR(40)       NOT NULL,
  name        VARCHAR(100)      NOT NULL,
  sort_order  SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  is_active   TINYINT(1)        NOT NULL DEFAULT 1,
  created_at  DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED   NULL,
  updated_at  DATETIME(3)       NULL,
  updated_by  BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_document_type_code (code),
  CONSTRAINT fk_document_type_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_document_type_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE certification_type (
  id          BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  code        VARCHAR(40)       NOT NULL,
  name        VARCHAR(100)      NOT NULL,
  sort_order  SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  is_active   TINYINT(1)        NOT NULL DEFAULT 1,
  created_at  DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED   NULL,
  updated_at  DATETIME(3)       NULL,
  updated_by  BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_certification_type_code (code),
  CONSTRAINT fk_certification_type_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_certification_type_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Partner business certifications (OD-39 default: master list + other)';

CREATE TABLE custom_field_definition (
  id             BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  entity         VARCHAR(20)       NOT NULL,
  section        VARCHAR(40)       NULL COMMENT 'Partner: ENTITY / TYPE / INDUSTRY / ENGAGEMENT',
  field_key      VARCHAR(60)       NOT NULL COMMENT 'Cannot change after creation',
  label          VARCHAR(150)      NOT NULL,
  field_type     VARCHAR(15)       NOT NULL,
  options_json   JSON              NULL COMMENT 'Options for SINGLE_SELECT / MULTI_SELECT',
  is_mandatory   TINYINT(1)        NOT NULL DEFAULT 0,
  is_filterable  TINYINT(1)        NOT NULL DEFAULT 0,
  sort_order     SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  help_text      VARCHAR(500)      NULL,
  is_active      TINYINT(1)        NOT NULL DEFAULT 1,
  created_at     DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by     BIGINT UNSIGNED   NULL,
  updated_at     DATETIME(3)       NULL,
  updated_by     BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_custom_field_definition_key (entity, field_key),
  CONSTRAINT fk_custom_field_definition_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_custom_field_definition_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_custom_field_definition_entity CHECK (entity IN ('PARTNER','ACCOUNT','CONTACT','LEAD','OPPORTUNITY','TENDER')),
  CONSTRAINT ck_custom_field_definition_type CHECK (field_type IN ('TEXT','LONG_TEXT','NUMBER','MONEY','DATE','SINGLE_SELECT','MULTI_SELECT','YES_NO','URL','EMAIL'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Admin-defined fields (12.15)';

CREATE TABLE custom_field_value (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  field_id      BIGINT UNSIGNED NOT NULL,
  entity        VARCHAR(20)     NOT NULL,
  record_id     BIGINT UNSIGNED NOT NULL,
  value_text    TEXT            NULL,
  value_number  DECIMAL(18,4)   NULL,
  value_date    DATE            NULL,
  value_bool    TINYINT(1)      NULL,
  value_json    JSON            NULL COMMENT 'MULTI_SELECT values as a JSON array (OD-45)',
  created_at    DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by    BIGINT UNSIGNED NULL,
  updated_at    DATETIME(3)     NULL,
  updated_by    BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_custom_field_value_field_record (field_id, record_id),
  KEY ix_custom_field_value_entity_record (entity, record_id),
  CONSTRAINT fk_custom_field_value_field      FOREIGN KEY (field_id)   REFERENCES custom_field_definition (id),
  CONSTRAINT fk_custom_field_value_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_custom_field_value_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE target (
  id               BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  owner_user_id    BIGINT UNSIGNED  NOT NULL,
  fiscal_year      SMALLINT         NOT NULL COMMENT 'Start year of the fiscal year, e.g. 2026 = FY 2026-27 (OD-56)',
  quarter          TINYINT UNSIGNED NOT NULL,
  target_value     DECIMAL(16,2)    NOT NULL DEFAULT 0,
  target_count     INT UNSIGNED     NOT NULL DEFAULT 0,
  new_logo_target  INT UNSIGNED     NULL,
  created_at       DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by       BIGINT UNSIGNED  NULL,
  updated_at       DATETIME(3)      NULL,
  updated_by       BIGINT UNSIGNED  NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_target_owner_period (owner_user_id, fiscal_year, quarter),
  CONSTRAINT fk_target_owner      FOREIGN KEY (owner_user_id) REFERENCES `user` (id),
  CONSTRAINT fk_target_created_by FOREIGN KEY (created_by)    REFERENCES `user` (id),
  CONSTRAINT fk_target_updated_by FOREIGN KEY (updated_by)    REFERENCES `user` (id),
  CONSTRAINT ck_target_quarter CHECK (quarter BETWEEN 1 AND 4)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Targets per owner per quarter (UM 10 Q10, OD-15)';

CREATE TABLE setting (
  setting_key     VARCHAR(80)     NOT NULL,
  setting_value   VARCHAR(1000)   NOT NULL,
  value_type      VARCHAR(10)     NOT NULL,
  min_value       DECIMAL(16,2)   NULL,
  max_value       DECIMAL(16,2)   NULL,
  allowed_values  VARCHAR(500)    NULL COMMENT 'Comma-separated, for DAY / LIST checks',
  module          VARCHAR(40)     NOT NULL,
  description     VARCHAR(500)    NOT NULL,
  is_editable     TINYINT(1)      NOT NULL DEFAULT 1,
  created_at      DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  updated_at      DATETIME(3)     NULL,
  updated_by      BIGINT UNSIGNED NULL,
  PRIMARY KEY (setting_key),
  CONSTRAINT fk_setting_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_setting_value_type CHECK (value_type IN ('INT','DECIMAL','TEXT','BOOL','TIME','DAY','LIST'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Business settings editable by the CRM Admin; every change audited';

CREATE TABLE email_template (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code          VARCHAR(60)     NOT NULL,
  name          VARCHAR(150)    NOT NULL,
  subject       VARCHAR(255)    NOT NULL,
  body_html     MEDIUMTEXT      NOT NULL,
  placeholders  JSON            NOT NULL COMMENT 'Allowed {{placeholder}} names',
  is_active     TINYINT(1)      NOT NULL DEFAULT 1,
  created_at    DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by    BIGINT UNSIGNED NULL,
  updated_at    DATETIME(3)     NULL,
  updated_by    BIGINT UNSIGNED NULL,
  row_version   INT UNSIGNED    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_email_template_code (code),
  CONSTRAINT fk_email_template_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_email_template_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE number_sequence (
  prefix         VARCHAR(10)       NOT NULL,
  seq_year       SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0 for non-yearly numbers (ACC, PTR)',
  current_value  INT UNSIGNED      NOT NULL DEFAULT 0,
  updated_at     DATETIME(3)       NULL,
  PRIMARY KEY (prefix, seq_year)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Business number generator (LD-2026-0001 ...); row-locked when a number is issued';

-- -----------------------------------------------------------------------------
-- 3. Accounts & contacts (15.4)
-- -----------------------------------------------------------------------------

CREATE TABLE account (
  id                      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_no              VARCHAR(20)     NOT NULL,
  name                    VARCHAR(200)    NOT NULL,
  legal_name              VARCHAR(250)    NULL,
  industry_id             BIGINT UNSIGNED NULL,
  segment                 VARCHAR(60)     NULL,
  account_type            VARCHAR(12)     NOT NULL DEFAULT 'PROSPECT',
  is_strategic            TINYINT(1)      NOT NULL DEFAULT 0,
  country                 VARCHAR(80)     NOT NULL DEFAULT 'India',
  state                   VARCHAR(80)     NULL,
  city                    VARCHAR(100)    NULL,
  address                 VARCHAR(500)    NULL,
  website                 VARCHAR(255)    NULL,
  gst_no                  VARCHAR(15)     NULL,
  pan_no                  VARCHAR(10)     NULL,
  locations_count         INT UNSIGNED    NULL,
  existing_vendor         VARCHAR(200)    NULL,
  owner_user_id           BIGINT UNSIGNED NOT NULL,
  backup_owner_user_id    BIGINT UNSIGNED NULL,
  first_won_on            DATE            NULL COMMENT 'New-logo date (BR-AC-03)',
  notes                   TEXT            NULL,
  merged_into_account_id  BIGINT UNSIGNED NULL,
  is_active               TINYINT(1)      NOT NULL DEFAULT 1,
  deleted_at              DATETIME(3)     NULL,
  created_at              DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by              BIGINT UNSIGNED NULL,
  updated_at              DATETIME(3)     NULL,
  updated_by              BIGINT UNSIGNED NULL,
  row_version             INT UNSIGNED    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_account_no (account_no),
  KEY ix_account_name (name),
  KEY ix_account_gst (gst_no),
  KEY ix_account_owner (owner_user_id),
  KEY ix_account_backup_owner (backup_owner_user_id),
  KEY ix_account_industry (industry_id),
  CONSTRAINT fk_account_industry     FOREIGN KEY (industry_id)            REFERENCES industry (id),
  CONSTRAINT fk_account_owner        FOREIGN KEY (owner_user_id)          REFERENCES `user` (id),
  CONSTRAINT fk_account_backup_owner FOREIGN KEY (backup_owner_user_id)   REFERENCES `user` (id),
  CONSTRAINT fk_account_merged_into  FOREIGN KEY (merged_into_account_id) REFERENCES account (id),
  CONSTRAINT fk_account_created_by   FOREIGN KEY (created_by)             REFERENCES `user` (id),
  CONSTRAINT fk_account_updated_by   FOREIGN KEY (updated_by)             REFERENCES `user` (id),
  CONSTRAINT ck_account_type CHECK (account_type IN ('PROSPECT','CUSTOMER','STRATEGIC','DORMANT'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Customer organisation (Account 360)';

CREATE TABLE contact (
  id               BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  account_id       BIGINT UNSIGNED  NULL,
  partner_id       BIGINT UNSIGNED  NULL,
  name             VARCHAR(150)     NOT NULL,
  designation      VARCHAR(100)     NULL,
  department       VARCHAR(100)     NULL,
  email            VARCHAR(150)     NULL,
  phone            VARCHAR(20)      NULL,
  seniority        VARCHAR(40)      NULL,
  influence_level  TINYINT UNSIGNED NULL,
  stand            VARCHAR(10)      NOT NULL DEFAULT 'UNKNOWN',
  intel_notes      TEXT             NULL,
  spoc_type        VARCHAR(12)      NULL COMMENT 'Partner contacts only',
  is_active        TINYINT(1)       NOT NULL DEFAULT 1,
  created_at       DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by       BIGINT UNSIGNED  NULL,
  updated_at       DATETIME(3)      NULL,
  updated_by       BIGINT UNSIGNED  NULL,
  row_version      INT UNSIGNED     NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  KEY ix_contact_account (account_id),
  KEY ix_contact_partner (partner_id),
  KEY ix_contact_email (email),
  CONSTRAINT fk_contact_account    FOREIGN KEY (account_id) REFERENCES account (id),
  CONSTRAINT fk_contact_partner    FOREIGN KEY (partner_id) REFERENCES partner (id),
  CONSTRAINT fk_contact_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_contact_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_contact_one_parent CHECK ((account_id IS NULL) <> (partner_id IS NULL)),
  CONSTRAINT ck_contact_influence  CHECK (influence_level IS NULL OR influence_level BETWEEN 1 AND 5),
  CONSTRAINT ck_contact_stand      CHECK (stand IN ('CHAMPION','NEUTRAL','BLOCKER','UNKNOWN')),
  CONSTRAINT ck_contact_spoc_type  CHECK (spoc_type IS NULL OR spoc_type IN ('TOP_MGMT','DMU','TECH','FINANCE','LEGAL','COMMERCIAL'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Person at an account OR a partner (exactly one parent)';

-- -----------------------------------------------------------------------------
-- 4. Partners (15.5)
-- -----------------------------------------------------------------------------

CREATE TABLE partner (
  id                           BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  partner_no                   VARCHAR(20)      NOT NULL,
  -- section 1: entity
  legal_name                   VARCHAR(250)     NOT NULL,
  short_name                   VARCHAR(150)     NULL,
  country                      VARCHAR(80)      NOT NULL,
  address                      VARCHAR(500)     NULL,
  city                         VARCHAR(100)     NULL,
  website                      VARCHAR(255)     NULL,
  email                        VARCHAR(150)     NULL,
  phone                        VARCHAR(20)      NULL,
  registration_no              VARCHAR(50)      NULL COMMENT 'Registration / CIN',
  gst_no                       VARCHAR(15)      NULL,
  pan_no                       VARCHAR(10)      NULL,
  currency                     CHAR(3)          NOT NULL DEFAULT 'INR',
  annual_revenue               DECIMAL(16,2)    NULL,
  revenue_fy                   VARCHAR(10)      NULL,
  credit_rating                VARCHAR(40)      NULL,
  financial_status             VARCHAR(20)      NULL,
  agreement_status             VARCHAR(15)      NOT NULL DEFAULT 'NONE',
  agreement_valid_till         DATE             NULL,
  agreement_document_id        BIGINT UNSIGNED  NULL,
  -- section 2: type
  tier                         VARCHAR(15)      NULL COMMENT 'OD-38 default: STRATEGIC / GROWTH / TRANSACTIONAL',
  -- section 3: industry & expertise
  top_customers                VARCHAR(1000)    NULL,
  our_share_pct                DECIMAL(5,2)     NULL,
  sme_count                    INT UNSIGNED     NULL,
  can_run_poc                  TINYINT(1)       NULL,
  certified_engineers          INT UNSIGNED     NULL,
  sales_force_size             INT UNSIGNED     NULL,
  uses_crm                     TINYINT(1)       NULL,
  sales_coverage               VARCHAR(255)     NULL,
  influencer_connect           VARCHAR(1000)    NULL,
  dmu_impact                   VARCHAR(10)      NULL,
  dmu_impact_notes             VARCHAR(1000)    NULL,
  -- section 4: engagement structure
  top_management               VARCHAR(1000)    NULL,
  partner_dmu                  VARCHAR(1000)    NULL,
  relationship_owner_user_id   BIGINT UNSIGNED  NOT NULL,
  backup_owner_user_id         BIGINT UNSIGNED  NULL,
  tech_onboarding_status       VARCHAR(30)      NULL,
  gtm_plan_status              VARCHAR(30)      NULL,
  gtm_document_id              BIGINT UNSIGNED  NULL,
  poc_investment_count         INT UNSIGNED     NULL,
  poc_investment_value         DECIMAL(16,2)    NULL,
  last_engagement_on           DATE             NULL,
  next_engagement_on           DATE             NULL,
  next_engagement_plan         VARCHAR(1000)    NULL,
  -- section 5: performance (current values, computed)
  perf_pipeline_value          DECIMAL(16,2)    NULL,
  perf_deals_won               INT UNSIGNED     NULL,
  perf_win_pct                 DECIMAL(5,2)     NULL,
  perf_score                   DECIMAL(5,2)     NULL,
  perf_rating                  TINYINT UNSIGNED NULL,
  perf_computed_at             DATETIME(3)      NULL,
  customer_feedback_rating     TINYINT UNSIGNED NULL,
  customer_feedback_notes      VARCHAR(1000)    NULL,
  publications                 TEXT             NULL,
  profile_completeness_pct     DECIMAL(5,2)     NOT NULL DEFAULT 0,
  is_active                    TINYINT(1)       NOT NULL DEFAULT 1,
  deleted_at                   DATETIME(3)      NULL,
  created_at                   DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by                   BIGINT UNSIGNED  NULL,
  updated_at                   DATETIME(3)      NULL,
  updated_by                   BIGINT UNSIGNED  NULL,
  row_version                  INT UNSIGNED     NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_partner_no (partner_no),
  KEY ix_partner_short_name (short_name),
  KEY ix_partner_legal_name (legal_name),
  KEY ix_partner_gst (gst_no),
  KEY ix_partner_relationship_owner (relationship_owner_user_id),
  KEY ix_partner_backup_owner (backup_owner_user_id),
  CONSTRAINT fk_partner_agreement_document FOREIGN KEY (agreement_document_id)      REFERENCES document (id),
  CONSTRAINT fk_partner_gtm_document       FOREIGN KEY (gtm_document_id)            REFERENCES document (id),
  CONSTRAINT fk_partner_relationship_owner FOREIGN KEY (relationship_owner_user_id) REFERENCES `user` (id),
  CONSTRAINT fk_partner_backup_owner       FOREIGN KEY (backup_owner_user_id)       REFERENCES `user` (id),
  CONSTRAINT fk_partner_created_by         FOREIGN KEY (created_by)                 REFERENCES `user` (id),
  CONSTRAINT fk_partner_updated_by         FOREIGN KEY (updated_by)                 REFERENCES `user` (id),
  CONSTRAINT ck_partner_agreement_status CHECK (agreement_status IN ('NONE','IN_NEGOTIATION','SIGNED','EXPIRED')),
  CONSTRAINT ck_partner_tier       CHECK (tier IS NULL OR tier IN ('STRATEGIC','GROWTH','TRANSACTIONAL')),
  CONSTRAINT ck_partner_dmu_impact CHECK (dmu_impact IS NULL OR dmu_impact IN ('HIGH','MEDIUM','LOW')),
  CONSTRAINT ck_partner_share_pct  CHECK (our_share_pct IS NULL OR our_share_pct BETWEEN 0 AND 100),
  CONSTRAINT ck_partner_feedback   CHECK (customer_feedback_rating IS NULL OR customer_feedback_rating BETWEEN 1 AND 5)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Partner Master, five sections (UM 7.1)';

CREATE TABLE partner_type_map (
  partner_id       BIGINT UNSIGNED NOT NULL,
  partner_type_id  BIGINT UNSIGNED NOT NULL,
  created_at       DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by       BIGINT UNSIGNED NULL,
  PRIMARY KEY (partner_id, partner_type_id),
  KEY ix_partner_type_map_type (partner_type_id),
  CONSTRAINT fk_partner_type_map_partner    FOREIGN KEY (partner_id)      REFERENCES partner (id),
  CONSTRAINT fk_partner_type_map_type       FOREIGN KEY (partner_type_id) REFERENCES partner_type (id),
  CONSTRAINT fk_partner_type_map_created_by FOREIGN KEY (created_by)      REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE partner_industry_map (
  partner_id   BIGINT UNSIGNED NOT NULL,
  industry_id  BIGINT UNSIGNED NOT NULL,
  created_at   DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by   BIGINT UNSIGNED NULL,
  PRIMARY KEY (partner_id, industry_id),
  KEY ix_partner_industry_map_industry (industry_id),
  CONSTRAINT fk_partner_industry_map_partner    FOREIGN KEY (partner_id)  REFERENCES partner (id),
  CONSTRAINT fk_partner_industry_map_industry   FOREIGN KEY (industry_id) REFERENCES industry (id),
  CONSTRAINT fk_partner_industry_map_created_by FOREIGN KEY (created_by)  REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE partner_certification (
  id                     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  partner_id             BIGINT UNSIGNED NOT NULL,
  certification_type_id  BIGINT UNSIGNED NULL,
  other_name             VARCHAR(150)    NULL,
  created_at             DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by             BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_partner_certification_type (partner_id, certification_type_id),
  CONSTRAINT fk_partner_certification_partner    FOREIGN KEY (partner_id)            REFERENCES partner (id),
  CONSTRAINT fk_partner_certification_type       FOREIGN KEY (certification_type_id) REFERENCES certification_type (id),
  CONSTRAINT fk_partner_certification_created_by FOREIGN KEY (created_by)            REFERENCES `user` (id),
  CONSTRAINT ck_partner_certification_one CHECK ((certification_type_id IS NULL) <> (other_name IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE partner_customer_code (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  partner_id     BIGINT UNSIGNED NOT NULL,
  account_id     BIGINT UNSIGNED NULL,
  customer_name  VARCHAR(200)    NULL,
  code           VARCHAR(60)     NOT NULL,
  created_at     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by     BIGINT UNSIGNED NULL,
  updated_at     DATETIME(3)     NULL,
  updated_by     BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  KEY ix_partner_customer_code_partner (partner_id),
  KEY ix_partner_customer_code_account (account_id),
  CONSTRAINT fk_partner_customer_code_partner    FOREIGN KEY (partner_id) REFERENCES partner (id),
  CONSTRAINT fk_partner_customer_code_account    FOREIGN KEY (account_id) REFERENCES account (id),
  CONSTRAINT fk_partner_customer_code_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_partner_customer_code_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_partner_customer_code_customer CHECK (account_id IS NOT NULL OR customer_name IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='"Partner code at customers" (UM 7.1)';

CREATE TABLE partner_engagement (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  partner_id       BIGINT UNSIGNED NOT NULL,
  engagement_type  VARCHAR(15)     NOT NULL,
  engagement_on    DATE            NOT NULL,
  with_whom        VARCHAR(500)    NULL,
  by_user_id       BIGINT UNSIGNED NOT NULL,
  notes            TEXT            NULL,
  outcome          VARCHAR(1000)   NULL,
  next_action      VARCHAR(500)    NULL,
  next_action_on   DATE            NULL,
  account_id       BIGINT UNSIGNED NULL,
  created_at       DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by       BIGINT UNSIGNED NULL,
  updated_at       DATETIME(3)     NULL,
  updated_by       BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  KEY ix_partner_engagement_partner (partner_id, engagement_on),
  KEY ix_partner_engagement_account (account_id),
  CONSTRAINT fk_partner_engagement_partner    FOREIGN KEY (partner_id) REFERENCES partner (id),
  CONSTRAINT fk_partner_engagement_by_user    FOREIGN KEY (by_user_id) REFERENCES `user` (id),
  CONSTRAINT fk_partner_engagement_account    FOREIGN KEY (account_id) REFERENCES account (id),
  CONSTRAINT fk_partner_engagement_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_partner_engagement_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_partner_engagement_type CHECK (engagement_type IN ('MEETING','QBR','TRAINING','EVENT','GTM_ACTIVITY','CEC_VISIT','CALL','JOINT_VISIT'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE partner_account_map (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  partner_id   BIGINT UNSIGNED NOT NULL,
  account_id   BIGINT UNSIGNED NOT NULL,
  plan_period  VARCHAR(10)     NOT NULL COMMENT 'e.g. 2026-H2',
  status       VARCHAR(12)     NOT NULL DEFAULT 'PLANNED',
  notes        VARCHAR(1000)   NULL,
  created_at   DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by   BIGINT UNSIGNED NULL,
  updated_at   DATETIME(3)     NULL,
  updated_by   BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_partner_account_map (partner_id, account_id, plan_period),
  KEY ix_partner_account_map_account (account_id),
  CONSTRAINT fk_partner_account_map_partner    FOREIGN KEY (partner_id) REFERENCES partner (id),
  CONSTRAINT fk_partner_account_map_account    FOREIGN KEY (account_id) REFERENCES account (id),
  CONSTRAINT fk_partner_account_map_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_partner_account_map_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_partner_account_map_status CHECK (status IN ('PLANNED','ENGAGED','OPPORTUNITY','DROPPED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='6-month account mapping (UM 7.1)';

CREATE TABLE partner_performance_snapshot (
  id                             BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  partner_id                     BIGINT UNSIGNED  NOT NULL,
  fiscal_year                    SMALLINT         NOT NULL,
  quarter                        TINYINT UNSIGNED NOT NULL,
  sourced_count                  INT UNSIGNED     NOT NULL DEFAULT 0,
  sourced_value                  DECIMAL(16,2)    NOT NULL DEFAULT 0,
  influenced_count               INT UNSIGNED     NOT NULL DEFAULT 0,
  influenced_value               DECIMAL(16,2)    NOT NULL DEFAULT 0,
  active_deals                   INT UNSIGNED     NOT NULL DEFAULT 0,
  closed_deals                   INT UNSIGNED     NOT NULL DEFAULT 0,
  won_deals                      INT UNSIGNED     NOT NULL DEFAULT 0,
  lost_deals                     INT UNSIGNED     NOT NULL DEFAULT 0,
  win_pct                        DECIMAL(5,2)     NULL,
  avg_deal_size                  DECIMAL(16,2)    NULL,
  revenue                        DECIMAL(16,2)    NULL,
  gm_pct                         DECIMAL(5,2)     NULL,
  np_pct                         DECIMAL(5,2)     NULL,
  lead_to_deal_days              DECIMAL(8,1)     NULL,
  order_to_book_days             DECIMAL(8,1)     NULL,
  on_time_payment_pct            DECIMAL(5,2)     NULL,
  avg_payment_delay_days         DECIMAL(8,1)     NULL,
  repeat_business_count          INT UNSIGNED     NOT NULL DEFAULT 0,
  new_logo_count                 INT UNSIGNED     NOT NULL DEFAULT 0,
  strategic_account_count        INT UNSIGNED     NOT NULL DEFAULT 0,
  competition_replacement_count  INT UNSIGNED     NOT NULL DEFAULT 0,
  tender_readiness_pct           DECIMAL(5,2)     NULL,
  tender_pipeline_count          INT UNSIGNED     NOT NULL DEFAULT 0,
  tender_pipeline_value          DECIMAL(16,2)    NOT NULL DEFAULT 0,
  gtm_activity_count             INT UNSIGNED     NOT NULL DEFAULT 0,
  cec_engagement_count           INT UNSIGNED     NOT NULL DEFAULT 0,
  product_mix_count              INT UNSIGNED     NOT NULL DEFAULT 0,
  update_discipline_pct          DECIMAL(5,2)     NULL,
  score                          DECIMAL(5,2)     NULL,
  rating                         TINYINT UNSIGNED NULL,
  tier_recommendation            VARCHAR(15)      NULL,
  loss_reasons_json              JSON             NULL,
  report_file_id                 BIGINT UNSIGNED  NULL,
  is_frozen                      TINYINT(1)       NOT NULL DEFAULT 0 COMMENT '1 = quarter-end snapshot',
  computed_at                    DATETIME(3)      NOT NULL,
  created_at                     DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  UNIQUE KEY ux_partner_performance_snapshot (partner_id, fiscal_year, quarter),
  CONSTRAINT fk_partner_performance_snapshot_partner FOREIGN KEY (partner_id)     REFERENCES partner (id),
  CONSTRAINT fk_partner_performance_snapshot_report  FOREIGN KEY (report_file_id) REFERENCES file_object (id),
  CONSTRAINT ck_partner_performance_snapshot_quarter CHECK (quarter BETWEEN 1 AND 4)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Partner scorecard per quarter (UM 7.2)';

-- -----------------------------------------------------------------------------
-- 5. Leads (15.6)
-- -----------------------------------------------------------------------------

CREATE TABLE sales_lead (
  id                       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  lead_no                  VARCHAR(20)     NOT NULL,
  source                   VARCHAR(10)     NOT NULL,
  partner_id               BIGINT UNSIGNED NULL,
  partner_contact_text     VARCHAR(200)    NULL,
  account_id               BIGINT UNSIGNED NULL,
  account_name_text        VARCHAR(200)    NULL COMMENT 'New account name before the account exists',
  industry_id              BIGINT UNSIGNED NOT NULL,
  contact_id               BIGINT UNSIGNED NULL,
  contact_name             VARCHAR(150)    NOT NULL,
  contact_designation      VARCHAR(100)    NULL,
  contact_email            VARCHAR(150)    NULL,
  contact_phone            VARCHAR(20)     NULL,
  city                     VARCHAR(100)    NOT NULL,
  locations_count          INT UNSIGNED    NULL,
  need_text                TEXT            NOT NULL COMMENT '"What they said" (UM 6.1)',
  rough_value              DECIMAL(16,2)   NULL,
  rough_timing             VARCHAR(40)     NULL,
  owner_user_id            BIGINT UNSIGNED NOT NULL,
  backup_owner_user_id     BIGINT UNSIGNED NULL,
  next_action              VARCHAR(500)    NOT NULL,
  next_action_due_on       DATE            NOT NULL,
  stage_code               VARCHAR(20)     NOT NULL DEFAULT 'NEW',
  stage_entered_at         DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  -- qualification facts (BR-LD-05)
  problem_statement        TEXT            NULL,
  product_id               BIGINT UNSIGNED NULL,
  solution_id              BIGINT UNSIGNED NULL,
  commercial_window_value  DECIMAL(16,2)   NULL,
  budget_known             VARCHAR(7)      NULL,
  budget_min               DECIMAL(16,2)   NULL,
  budget_max               DECIMAL(16,2)   NULL,
  procurement_type_id      BIGINT UNSIGNED NULL,
  procurement_steps_known  TINYINT(1)      NOT NULL DEFAULT 0,
  expected_close_date      DATE            NULL,
  qualification_pct        DECIMAL(5,2)    NOT NULL DEFAULT 0,
  disqualify_reason_id     BIGINT UNSIGNED NULL,
  disqualify_note          VARCHAR(1000)   NULL,
  disqualified_at          DATETIME(3)     NULL,
  opportunity_id           BIGINT UNSIGNED NULL,
  converted_at             DATETIME(3)     NULL,
  last_activity_at         DATETIME(3)     NULL,
  is_active                TINYINT(1)      NOT NULL DEFAULT 1,
  created_at               DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by               BIGINT UNSIGNED NULL,
  updated_at               DATETIME(3)     NULL,
  updated_by               BIGINT UNSIGNED NULL,
  row_version              INT UNSIGNED    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_sales_lead_no (lead_no),
  UNIQUE KEY ux_sales_lead_opportunity (opportunity_id),
  KEY ix_sales_lead_owner_stage (owner_user_id, stage_code),
  KEY ix_sales_lead_backup_owner (backup_owner_user_id),
  KEY ix_sales_lead_account (account_id),
  KEY ix_sales_lead_partner (partner_id),
  KEY ix_sales_lead_created (created_at),
  CONSTRAINT fk_sales_lead_partner           FOREIGN KEY (partner_id)           REFERENCES partner (id),
  CONSTRAINT fk_sales_lead_account           FOREIGN KEY (account_id)           REFERENCES account (id),
  CONSTRAINT fk_sales_lead_industry          FOREIGN KEY (industry_id)          REFERENCES industry (id),
  CONSTRAINT fk_sales_lead_contact           FOREIGN KEY (contact_id)           REFERENCES contact (id),
  CONSTRAINT fk_sales_lead_owner             FOREIGN KEY (owner_user_id)        REFERENCES `user` (id),
  CONSTRAINT fk_sales_lead_backup_owner      FOREIGN KEY (backup_owner_user_id) REFERENCES `user` (id),
  CONSTRAINT fk_sales_lead_product           FOREIGN KEY (product_id)           REFERENCES product (id),
  CONSTRAINT fk_sales_lead_solution          FOREIGN KEY (solution_id)          REFERENCES solution (id),
  CONSTRAINT fk_sales_lead_procurement_type  FOREIGN KEY (procurement_type_id)  REFERENCES procurement_type (id),
  CONSTRAINT fk_sales_lead_disqualify_reason FOREIGN KEY (disqualify_reason_id) REFERENCES reason (id),
  CONSTRAINT fk_sales_lead_opportunity       FOREIGN KEY (opportunity_id)       REFERENCES opportunity (id),
  CONSTRAINT fk_sales_lead_created_by        FOREIGN KEY (created_by)           REFERENCES `user` (id),
  CONSTRAINT fk_sales_lead_updated_by        FOREIGN KEY (updated_by)           REFERENCES `user` (id),
  CONSTRAINT ck_sales_lead_source CHECK (source IN ('DIRECT','PARTNER','TENDER','EVENT','WEBSITE','REFERRAL')),
  CONSTRAINT ck_sales_lead_stage  CHECK (stage_code IN ('NEW','CONTACTED','QUALIFYING','CONVERTED','DISQUALIFIED')),
  CONSTRAINT ck_sales_lead_budget_known CHECK (budget_known IS NULL OR budget_known IN ('YES','NO','UNKNOWN')),
  CONSTRAINT ck_sales_lead_partner_required CHECK (source <> 'PARTNER' OR partner_id IS NOT NULL),
  CONSTRAINT ck_sales_lead_account CHECK (account_id IS NOT NULL OR account_name_text IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Lead (table named sales_lead because LEAD is reserved); not in the funnel (BR-LD-03)';

CREATE TABLE lead_product (
  lead_id     BIGINT UNSIGNED NOT NULL,
  product_id  BIGINT UNSIGNED NOT NULL,
  created_at  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED NULL,
  PRIMARY KEY (lead_id, product_id),
  KEY ix_lead_product_product (product_id),
  CONSTRAINT fk_lead_product_lead       FOREIGN KEY (lead_id)    REFERENCES sales_lead (id),
  CONSTRAINT fk_lead_product_product    FOREIGN KEY (product_id) REFERENCES product (id),
  CONSTRAINT fk_lead_product_created_by FOREIGN KEY (created_by) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE lead_dmu (
  id               BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  lead_id          BIGINT UNSIGNED  NOT NULL,
  contact_id       BIGINT UNSIGNED  NULL,
  name             VARCHAR(150)     NOT NULL,
  designation      VARCHAR(100)     NULL,
  dmu_role         VARCHAR(15)      NOT NULL,
  influence_level  TINYINT UNSIGNED NULL,
  stand            VARCHAR(10)      NOT NULL DEFAULT 'UNKNOWN',
  notes            VARCHAR(1000)    NULL,
  created_at       DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by       BIGINT UNSIGNED  NULL,
  updated_at       DATETIME(3)      NULL,
  updated_by       BIGINT UNSIGNED  NULL,
  PRIMARY KEY (id),
  KEY ix_lead_dmu_lead (lead_id),
  KEY ix_lead_dmu_contact (contact_id),
  CONSTRAINT fk_lead_dmu_lead       FOREIGN KEY (lead_id)    REFERENCES sales_lead (id),
  CONSTRAINT fk_lead_dmu_contact    FOREIGN KEY (contact_id) REFERENCES contact (id),
  CONSTRAINT fk_lead_dmu_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_lead_dmu_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_lead_dmu_role      CHECK (dmu_role IN ('TECH_BUYER','COMM_BUYER','INFLUENCER_INT','INFLUENCER_EXT')),
  CONSTRAINT ck_lead_dmu_influence CHECK (influence_level IS NULL OR influence_level BETWEEN 1 AND 5),
  CONSTRAINT ck_lead_dmu_stand     CHECK (stand IN ('CHAMPION','NEUTRAL','BLOCKER','UNKNOWN'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE lead_competitor (
  lead_id        BIGINT UNSIGNED NOT NULL,
  competitor_id  BIGINT UNSIGNED NOT NULL,
  created_at     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by     BIGINT UNSIGNED NULL,
  PRIMARY KEY (lead_id, competitor_id),
  KEY ix_lead_competitor_competitor (competitor_id),
  CONSTRAINT fk_lead_competitor_lead       FOREIGN KEY (lead_id)       REFERENCES sales_lead (id),
  CONSTRAINT fk_lead_competitor_competitor FOREIGN KEY (competitor_id) REFERENCES competitor (id),
  CONSTRAINT fk_lead_competitor_created_by FOREIGN KEY (created_by)    REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- 6. Opportunities & commercial (15.7)
-- -----------------------------------------------------------------------------

CREATE TABLE opportunity (
  id                           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  opportunity_no               VARCHAR(20)     NOT NULL,
  title                        VARCHAR(250)    NOT NULL,
  account_id                   BIGINT UNSIGNED NOT NULL,
  lead_id                      BIGINT UNSIGNED NULL,
  source                       VARCHAR(10)     NOT NULL,
  tender_id                    BIGINT UNSIGNED NULL,
  industry_id                  BIGINT UNSIGNED NULL,
  solution_id                  BIGINT UNSIGNED NULL,
  problem_statement            TEXT            NULL,
  technical_requirement        TEXT            NULL,
  locations_count              INT UNSIGNED    NULL,
  stage_code                   VARCHAR(20)     NOT NULL DEFAULT 'QUALIFIED',
  stage_entered_at             DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  previous_stage_code          VARCHAR(20)     NULL,
  confidence_override_pct      DECIMAL(5,2)    NULL,
  confidence_override_reason   VARCHAR(500)    NULL,
  expected_value               DECIMAL(16,2)   NOT NULL DEFAULT 0,
  currency                     CHAR(3)         NOT NULL DEFAULT 'INR',
  fx_rate                      DECIMAL(12,6)   NOT NULL DEFAULT 1 COMMENT 'To INR, for reporting (OD-51)',
  weighted_value               DECIMAL(16,2)   NOT NULL DEFAULT 0 COMMENT 'Maintained by the stored procedures (15.11)',
  expected_close_date          DATE            NULL,
  close_date_change_count      INT UNSIGNED    NOT NULL DEFAULT 0,
  commercial_window_value      DECIMAL(16,2)   NULL,
  commercial_window_accepted   TINYINT(1)      NOT NULL DEFAULT 0,
  budget_known                 VARCHAR(7)      NULL,
  budget_min                   DECIMAL(16,2)   NULL,
  budget_max                   DECIMAL(16,2)   NULL,
  procurement_type_id          BIGINT UNSIGNED NULL,
  procurement_steps_known      TINYINT(1)      NOT NULL DEFAULT 0,
  current_procurement_step_id  BIGINT UNSIGNED NULL,
  validation_status            VARCHAR(10)     NOT NULL DEFAULT 'PENDING',
  validated_by                 BIGINT UNSIGNED NULL,
  validated_at                 DATETIME(3)     NULL,
  validation_remark            VARCHAR(1000)   NULL,
  owner_user_id                BIGINT UNSIGNED NOT NULL,
  backup_owner_user_id         BIGINT UNSIGNED NULL,
  presales_owner_user_id       BIGINT UNSIGNED NULL,
  sponsor_user_id              BIGINT UNSIGNED NULL,
  partner_tbm                  TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'Partner to be mapped',
  no_competition               TINYINT(1)      NOT NULL DEFAULT 0,
  final_value                  DECIMAL(16,2)   NULL,
  payment_terms                VARCHAR(500)    NULL,
  po_number                    VARCHAR(60)     NULL,
  po_date                      DATE            NULL,
  po_value                     DECIMAL(16,2)   NULL,
  closed_at                    DATETIME(3)     NULL,
  dormant_reason_id            BIGINT UNSIGNED NULL,
  dormant_note                 VARCHAR(1000)   NULL,
  wake_up_date                 DATE            NULL,
  bundle_tag                   VARCHAR(60)     NULL,
  health                       VARCHAR(10)     NOT NULL DEFAULT 'ON_TRACK',
  last_activity_at             DATETIME(3)     NULL,
  last_status_at               DATETIME(3)     NULL,
  is_active                    TINYINT(1)      NOT NULL DEFAULT 1,
  created_at                   DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by                   BIGINT UNSIGNED NULL,
  updated_at                   DATETIME(3)     NULL,
  updated_by                   BIGINT UNSIGNED NULL,
  row_version                  INT UNSIGNED    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_opportunity_no (opportunity_no),
  UNIQUE KEY ux_opportunity_lead (lead_id),
  KEY ix_opportunity_owner_stage (owner_user_id, stage_code),
  KEY ix_opportunity_stage_close (stage_code, expected_close_date),
  KEY ix_opportunity_account (account_id),
  KEY ix_opportunity_backup_owner (backup_owner_user_id),
  KEY ix_opportunity_presales_owner (presales_owner_user_id),
  KEY ix_opportunity_sponsor (sponsor_user_id),
  KEY ix_opportunity_validation (validation_status),
  KEY ix_opportunity_health (health),
  KEY ix_opportunity_tender (tender_id),
  KEY ix_opportunity_bundle (bundle_tag),
  CONSTRAINT fk_opportunity_account           FOREIGN KEY (account_id)                  REFERENCES account (id),
  CONSTRAINT fk_opportunity_lead              FOREIGN KEY (lead_id)                     REFERENCES sales_lead (id),
  CONSTRAINT fk_opportunity_tender            FOREIGN KEY (tender_id)                   REFERENCES tender (id),
  CONSTRAINT fk_opportunity_industry          FOREIGN KEY (industry_id)                 REFERENCES industry (id),
  CONSTRAINT fk_opportunity_solution          FOREIGN KEY (solution_id)                 REFERENCES solution (id),
  CONSTRAINT fk_opportunity_procurement_type  FOREIGN KEY (procurement_type_id)         REFERENCES procurement_type (id),
  CONSTRAINT fk_opportunity_procurement_step  FOREIGN KEY (current_procurement_step_id) REFERENCES procurement_step (id),
  CONSTRAINT fk_opportunity_validated_by      FOREIGN KEY (validated_by)                REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_owner             FOREIGN KEY (owner_user_id)               REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_backup_owner      FOREIGN KEY (backup_owner_user_id)        REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_presales_owner    FOREIGN KEY (presales_owner_user_id)      REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_sponsor           FOREIGN KEY (sponsor_user_id)             REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_dormant_reason    FOREIGN KEY (dormant_reason_id)           REFERENCES reason (id),
  CONSTRAINT fk_opportunity_created_by        FOREIGN KEY (created_by)                  REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_updated_by        FOREIGN KEY (updated_by)                  REFERENCES `user` (id),
  CONSTRAINT ck_opportunity_source CHECK (source IN ('DIRECT','PARTNER','TENDER','EVENT','WEBSITE','REFERRAL')),
  CONSTRAINT ck_opportunity_stage  CHECK (stage_code IN ('QUALIFIED','TECH_ENGAGEMENT','POC','PROPOSAL','NEGOTIATION','COMMERCIAL_CLOSED','CONTRACT_SIGNED','WON','LOST','DORMANT')),
  CONSTRAINT ck_opportunity_validation CHECK (validation_status IN ('PENDING','VALID','NOT_VALID')),
  CONSTRAINT ck_opportunity_health CHECK (health IN ('ON_TRACK','AT_RISK','SLIPPED','STALE')),
  CONSTRAINT ck_opportunity_budget_known CHECK (budget_known IS NULL OR budget_known IN ('YES','NO','UNKNOWN')),
  CONSTRAINT ck_opportunity_override CHECK (confidence_override_pct IS NULL OR confidence_override_pct BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='One record per deal, QUALIFIED to WON / LOST / DORMANT (UM 4.3)';

CREATE TABLE opportunity_product (
  opportunity_id  BIGINT UNSIGNED NOT NULL,
  product_id      BIGINT UNSIGNED NOT NULL,
  is_primary      TINYINT(1)      NOT NULL DEFAULT 0,
  created_at      DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by      BIGINT UNSIGNED NULL,
  PRIMARY KEY (opportunity_id, product_id),
  KEY ix_opportunity_product_product (product_id),
  CONSTRAINT fk_opportunity_product_opportunity FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_opportunity_product_product     FOREIGN KEY (product_id)     REFERENCES product (id),
  CONSTRAINT fk_opportunity_product_created_by  FOREIGN KEY (created_by)     REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE opportunity_dmu (
  id               BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  opportunity_id   BIGINT UNSIGNED  NOT NULL,
  contact_id       BIGINT UNSIGNED  NOT NULL,
  dmu_role         VARCHAR(15)      NOT NULL,
  influence_level  TINYINT UNSIGNED NULL,
  stand            VARCHAR(10)      NOT NULL DEFAULT 'UNKNOWN',
  notes            VARCHAR(1000)    NULL,
  created_at       DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by       BIGINT UNSIGNED  NULL,
  updated_at       DATETIME(3)      NULL,
  updated_by       BIGINT UNSIGNED  NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_opportunity_dmu (opportunity_id, contact_id, dmu_role),
  KEY ix_opportunity_dmu_contact (contact_id),
  CONSTRAINT fk_opportunity_dmu_opportunity FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_opportunity_dmu_contact     FOREIGN KEY (contact_id)     REFERENCES contact (id),
  CONSTRAINT fk_opportunity_dmu_created_by  FOREIGN KEY (created_by)     REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_dmu_updated_by  FOREIGN KEY (updated_by)     REFERENCES `user` (id),
  CONSTRAINT ck_opportunity_dmu_role      CHECK (dmu_role IN ('TECH_BUYER','COMM_BUYER','INFLUENCER_INT','INFLUENCER_EXT','SPONSOR')),
  CONSTRAINT ck_opportunity_dmu_influence CHECK (influence_level IS NULL OR influence_level BETWEEN 1 AND 5),
  CONSTRAINT ck_opportunity_dmu_stand     CHECK (stand IN ('CHAMPION','NEUTRAL','BLOCKER','UNKNOWN'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE opportunity_partner (
  id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  opportunity_id        BIGINT UNSIGNED NOT NULL,
  partner_id            BIGINT UNSIGNED NOT NULL,
  partner_role          VARCHAR(12)     NOT NULL,
  partner_contact_id    BIGINT UNSIGNED NULL,
  engagement_level      VARCHAR(6)      NULL,
  is_primary            TINYINT(1)      NOT NULL DEFAULT 0,
  commercial_confirmed  TINYINT(1)      NOT NULL DEFAULT 0,
  notes                 VARCHAR(1000)   NULL,
  created_at            DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by            BIGINT UNSIGNED NULL,
  updated_at            DATETIME(3)     NULL,
  updated_by            BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_opportunity_partner (opportunity_id, partner_id, partner_role),
  KEY ix_opportunity_partner_partner (partner_id),
  CONSTRAINT fk_opportunity_partner_opportunity FOREIGN KEY (opportunity_id)     REFERENCES opportunity (id),
  CONSTRAINT fk_opportunity_partner_partner     FOREIGN KEY (partner_id)         REFERENCES partner (id),
  CONSTRAINT fk_opportunity_partner_contact     FOREIGN KEY (partner_contact_id) REFERENCES contact (id),
  CONSTRAINT fk_opportunity_partner_created_by  FOREIGN KEY (created_by)         REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_partner_updated_by  FOREIGN KEY (updated_by)         REFERENCES `user` (id),
  CONSTRAINT ck_opportunity_partner_role  CHECK (partner_role IN ('SOURCED','INFLUENCED','FULFILMENT','SERVICE')),
  CONSTRAINT ck_opportunity_partner_level CHECK (engagement_level IS NULL OR engagement_level IN ('HIGH','MEDIUM','LOW'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Several partners per deal, each with a role (BR-OP-12)';

CREATE TABLE opportunity_competitor (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  opportunity_id      BIGINT UNSIGNED NOT NULL,
  competitor_id       BIGINT UNSIGNED NOT NULL,
  their_price         DECIMAL(16,2)   NULL,
  their_strength      VARCHAR(1000)   NULL,
  our_differentiator  VARCHAR(1000)   NULL,
  created_at          DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by          BIGINT UNSIGNED NULL,
  updated_at          DATETIME(3)     NULL,
  updated_by          BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_opportunity_competitor (opportunity_id, competitor_id),
  KEY ix_opportunity_competitor_competitor (competitor_id),
  CONSTRAINT fk_opportunity_competitor_opportunity FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_opportunity_competitor_competitor  FOREIGN KEY (competitor_id)  REFERENCES competitor (id),
  CONSTRAINT fk_opportunity_competitor_created_by  FOREIGN KEY (created_by)     REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_competitor_updated_by  FOREIGN KEY (updated_by)     REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE opportunity_poc (
  id                        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  opportunity_id            BIGINT UNSIGNED NOT NULL,
  external_poc_ref          VARCHAR(60)     NULL,
  status                    VARCHAR(12)     NOT NULL DEFAULT 'REQUESTED',
  start_date                DATE            NULL,
  end_date                  DATE            NULL,
  success_criteria          TEXT            NULL,
  exit_criteria             TEXT            NULL,
  customer_lead_contact_id  BIGINT UNSIGNED NULL,
  cnergee_lead_user_id      BIGINT UNSIGNED NULL,
  result                    VARCHAR(12)     NULL,
  customer_validated        TINYINT(1)      NULL,
  readout_date              DATE            NULL,
  skipped                   TINYINT(1)      NOT NULL DEFAULT 0,
  skip_reason               VARCHAR(1000)   NULL,
  notes                     TEXT            NULL,
  created_at                DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by                BIGINT UNSIGNED NULL,
  updated_at                DATETIME(3)     NULL,
  updated_by                BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_opportunity_poc_opportunity (opportunity_id),
  CONSTRAINT fk_opportunity_poc_opportunity   FOREIGN KEY (opportunity_id)           REFERENCES opportunity (id),
  CONSTRAINT fk_opportunity_poc_customer_lead FOREIGN KEY (customer_lead_contact_id) REFERENCES contact (id),
  CONSTRAINT fk_opportunity_poc_cnergee_lead  FOREIGN KEY (cnergee_lead_user_id)     REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_poc_created_by    FOREIGN KEY (created_by)               REFERENCES `user` (id),
  CONSTRAINT fk_opportunity_poc_updated_by    FOREIGN KEY (updated_by)               REFERENCES `user` (id),
  CONSTRAINT ck_opportunity_poc_status CHECK (status IN ('REQUESTED','IN_PROGRESS','COMPLETED','CANCELLED')),
  CONSTRAINT ck_opportunity_poc_result CHECK (result IS NULL OR result IN ('SUCCESS','FAIL','INCONCLUSIVE')),
  CONSTRAINT ck_opportunity_poc_dates  CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='POC details inside the CRM, one per deal in v1 (12.5.4, OD-13, OD-36)';

CREATE TABLE partner_commercial (
  id                          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  opportunity_id              BIGINT UNSIGNED NOT NULL,
  partner_id                  BIGINT UNSIGNED NOT NULL,
  account_id                  BIGINT UNSIGNED NOT NULL,
  partner_role                VARCHAR(12)     NOT NULL,
  version_no                  INT UNSIGNED    NOT NULL,
  deal_size_basis             VARCHAR(250)    NOT NULL,
  price_to_partner            DECIMAL(16,2)   NOT NULL,
  partner_margin_pct          DECIMAL(5,2)    NULL,
  payment_terms               VARCHAR(250)    NOT NULL,
  pay_partner_after_customer  TINYINT(1)      NOT NULL DEFAULT 1,
  valid_till                  DATE            NULL,
  document_id                 BIGINT UNSIGNED NULL,
  bundle_tag                  VARCHAR(60)     NULL,
  remarks                     VARCHAR(1000)   NULL,
  created_at                  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by                  BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_partner_commercial_version (opportunity_id, partner_id, version_no),
  KEY ix_partner_commercial_partner (partner_id),
  KEY ix_partner_commercial_account (account_id),
  CONSTRAINT fk_partner_commercial_opportunity FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_partner_commercial_partner     FOREIGN KEY (partner_id)     REFERENCES partner (id),
  CONSTRAINT fk_partner_commercial_account     FOREIGN KEY (account_id)     REFERENCES account (id),
  CONSTRAINT fk_partner_commercial_document    FOREIGN KEY (document_id)    REFERENCES document (id),
  CONSTRAINT fk_partner_commercial_created_by  FOREIGN KEY (created_by)     REFERENCES `user` (id),
  CONSTRAINT ck_partner_commercial_role   CHECK (partner_role IN ('SOURCED','INFLUENCED','FULFILMENT','SERVICE')),
  CONSTRAINT ck_partner_commercial_price  CHECK (price_to_partner > 0),
  CONSTRAINT ck_partner_commercial_margin CHECK (partner_margin_pct IS NULL OR partner_margin_pct BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Commercial given to a partner for an account; insert-only versions (BR-OP-13)';

CREATE TABLE offer (
  id                     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  opportunity_id         BIGINT UNSIGNED NOT NULL,
  version_no             INT UNSIGNED    NOT NULL,
  offer_no               VARCHAR(30)     NOT NULL COMMENT 'e.g. OPP-2026-0001/v2',
  offer_value            DECIMAL(16,2)   NOT NULL,
  list_value             DECIMAL(16,2)   NULL,
  discount_pct           DECIMAL(5,2)    NULL,
  value_adds             VARCHAR(2000)   NULL,
  payment_terms          VARCHAR(500)    NULL,
  valid_till             DATE            NOT NULL,
  status                 VARCHAR(16)     NOT NULL DEFAULT 'DRAFT',
  approval_required      TINYINT(1)      NOT NULL DEFAULT 0,
  submitted_by           BIGINT UNSIGNED NULL,
  submitted_at           DATETIME(3)     NULL,
  approved_by            BIGINT UNSIGNED NULL,
  approved_at            DATETIME(3)     NULL,
  approval_remark        VARCHAR(1000)   NULL,
  sent_by                BIGINT UNSIGNED NULL,
  sent_at                DATETIME(3)     NULL,
  sent_to                VARCHAR(500)    NULL,
  document_id            BIGINT UNSIGNED NULL,
  customer_response      VARCHAR(2000)   NULL,
  customer_responded_at  DATETIME(3)     NULL,
  created_at             DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by             BIGINT UNSIGNED NULL,
  updated_at             DATETIME(3)     NULL,
  updated_by             BIGINT UNSIGNED NULL,
  row_version            INT UNSIGNED    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_offer_version (opportunity_id, version_no),
  UNIQUE KEY ux_offer_no (offer_no),
  KEY ix_offer_status (status),
  CONSTRAINT fk_offer_opportunity  FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_offer_submitted_by FOREIGN KEY (submitted_by)   REFERENCES `user` (id),
  CONSTRAINT fk_offer_approved_by  FOREIGN KEY (approved_by)    REFERENCES `user` (id),
  CONSTRAINT fk_offer_sent_by      FOREIGN KEY (sent_by)        REFERENCES `user` (id),
  CONSTRAINT fk_offer_document     FOREIGN KEY (document_id)    REFERENCES document (id),
  CONSTRAINT fk_offer_created_by   FOREIGN KEY (created_by)     REFERENCES `user` (id),
  CONSTRAINT fk_offer_updated_by   FOREIGN KEY (updated_by)     REFERENCES `user` (id),
  CONSTRAINT ck_offer_status   CHECK (status IN ('DRAFT','PENDING_APPROVAL','APPROVED','SENT','ACCEPTED','REJECTED','SUPERSEDED')),
  CONSTRAINT ck_offer_value    CHECK (offer_value > 0),
  CONSTRAINT ck_offer_discount CHECK (discount_pct IS NULL OR discount_pct BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Commercial offer versions; every version kept (BR-OP-05)';

CREATE TABLE win_loss (
  opportunity_id        BIGINT UNSIGNED NOT NULL,
  outcome               VARCHAR(4)      NOT NULL,
  loss_reason_id        BIGINT UNSIGNED NULL COMMENT 'LOST: loss category',
  competitor_id         BIGINT UNSIGNED NULL,
  detail                TEXT            NULL,
  lesson                TEXT            NULL,
  competition_replaced  TINYINT(1)      NOT NULL DEFAULT 0,
  remarks               VARCHAR(1000)   NULL,
  recorded_by           BIGINT UNSIGNED NOT NULL,
  recorded_at           DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (opportunity_id),
  KEY ix_win_loss_outcome (outcome, recorded_at),
  KEY ix_win_loss_competitor (competitor_id),
  CONSTRAINT fk_win_loss_opportunity FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_win_loss_loss_reason FOREIGN KEY (loss_reason_id) REFERENCES reason (id),
  CONSTRAINT fk_win_loss_competitor  FOREIGN KEY (competitor_id)  REFERENCES competitor (id),
  CONSTRAINT fk_win_loss_recorded_by FOREIGN KEY (recorded_by)    REFERENCES `user` (id),
  CONSTRAINT ck_win_loss_outcome CHECK (outcome IN ('WON','LOST'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE win_loss_reason (
  opportunity_id  BIGINT UNSIGNED NOT NULL,
  reason_id       BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (opportunity_id, reason_id),
  KEY ix_win_loss_reason_reason (reason_id),
  CONSTRAINT fk_win_loss_reason_opportunity FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_win_loss_reason_reason      FOREIGN KEY (reason_id)      REFERENCES reason (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Multi-select win reasons';

CREATE TABLE stage_history (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type       VARCHAR(10)     NOT NULL,
  entity_id         BIGINT UNSIGNED NOT NULL,
  from_stage        VARCHAR(20)     NULL,
  to_stage          VARCHAR(20)     NOT NULL,
  changed_by        BIGINT UNSIGNED NULL,
  changed_at        DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  reason            VARCHAR(1000)   NULL,
  days_in_previous  INT UNSIGNED    NULL,
  was_override      TINYINT(1)      NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY ix_stage_history_entity (entity_type, entity_id, changed_at),
  CONSTRAINT fk_stage_history_changed_by FOREIGN KEY (changed_by) REFERENCES `user` (id),
  CONSTRAINT ck_stage_history_entity CHECK (entity_type IN ('LEAD','OPP','TENDER','ORDER'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Append-only lifecycle history';

-- -----------------------------------------------------------------------------
-- 7. Work tracking & forecast (15.8)
-- -----------------------------------------------------------------------------

CREATE TABLE activity (
  id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type           VARCHAR(10)     NOT NULL,
  entity_id             BIGINT UNSIGNED NOT NULL,
  lead_id               BIGINT UNSIGNED NULL,
  opportunity_id        BIGINT UNSIGNED NULL,
  account_id            BIGINT UNSIGNED NULL,
  partner_id            BIGINT UNSIGNED NULL,
  activity_type         VARCHAR(12)     NOT NULL,
  activity_at           DATETIME(3)     NOT NULL,
  people_met            VARCHAR(500)    NULL,
  subject               VARCHAR(250)    NOT NULL,
  notes                 TEXT            NULL,
  outcome               VARCHAR(1000)   NULL,
  next_action           VARCHAR(500)    NULL,
  next_action_on        DATE            NULL,
  next_action_owner_id  BIGINT UNSIGNED NULL,
  by_user_id            BIGINT UNSIGNED NOT NULL,
  is_active             TINYINT(1)      NOT NULL DEFAULT 1,
  created_at            DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by            BIGINT UNSIGNED NULL,
  updated_at            DATETIME(3)     NULL,
  updated_by            BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  KEY ix_activity_entity (entity_type, entity_id, activity_at),
  KEY ix_activity_lead (lead_id),
  KEY ix_activity_opportunity (opportunity_id),
  KEY ix_activity_account (account_id),
  KEY ix_activity_partner (partner_id),
  KEY ix_activity_by_user (by_user_id, activity_at),
  CONSTRAINT fk_activity_lead              FOREIGN KEY (lead_id)              REFERENCES sales_lead (id),
  CONSTRAINT fk_activity_opportunity       FOREIGN KEY (opportunity_id)       REFERENCES opportunity (id),
  CONSTRAINT fk_activity_account           FOREIGN KEY (account_id)           REFERENCES account (id),
  CONSTRAINT fk_activity_partner           FOREIGN KEY (partner_id)           REFERENCES partner (id),
  CONSTRAINT fk_activity_next_action_owner FOREIGN KEY (next_action_owner_id) REFERENCES `user` (id),
  CONSTRAINT fk_activity_by_user           FOREIGN KEY (by_user_id)           REFERENCES `user` (id),
  CONSTRAINT fk_activity_created_by        FOREIGN KEY (created_by)           REFERENCES `user` (id),
  CONSTRAINT fk_activity_updated_by        FOREIGN KEY (updated_by)           REFERENCES `user` (id),
  CONSTRAINT ck_activity_entity CHECK (entity_type IN ('LEAD','OPP','ACCOUNT','PARTNER','TENDER','ORDER')),
  CONSTRAINT ck_activity_type   CHECK (activity_type IN ('CALL','MEETING','EMAIL','VISIT','CEC_VISIT','DEMO','NEGOTIATION','NOTE','INTEL')),
  CONSTRAINT ck_activity_next   CHECK (next_action IS NULL OR next_action_on IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Calls, meetings, notes and intelligence notes (12.20)';

CREATE TABLE activity_contact (
  activity_id  BIGINT UNSIGNED NOT NULL,
  contact_id   BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (activity_id, contact_id),
  KEY ix_activity_contact_contact (contact_id),
  CONSTRAINT fk_activity_contact_activity FOREIGN KEY (activity_id) REFERENCES activity (id),
  CONSTRAINT fk_activity_contact_contact  FOREIGN KEY (contact_id)  REFERENCES contact (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE task (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type       VARCHAR(10)     NULL,
  entity_id         BIGINT UNSIGNED NULL,
  task_type         VARCHAR(16)     NOT NULL,
  title             VARCHAR(250)    NOT NULL,
  description       VARCHAR(1000)   NULL,
  owner_user_id     BIGINT UNSIGNED NOT NULL,
  due_at            DATETIME(3)     NOT NULL,
  status            VARCHAR(10)     NOT NULL DEFAULT 'OPEN',
  completed_at      DATETIME(3)     NULL,
  completed_by      BIGINT UNSIGNED NULL,
  reminder_sent_at  DATETIME(3)     NULL,
  source_ref        VARCHAR(120)    NULL COMMENT 'De-duplication key for system-created tasks',
  created_at        DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by        BIGINT UNSIGNED NULL,
  updated_at        DATETIME(3)     NULL,
  updated_by        BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_task_source_ref (source_ref),
  KEY ix_task_owner_status_due (owner_user_id, status, due_at),
  KEY ix_task_entity (entity_type, entity_id),
  CONSTRAINT fk_task_owner        FOREIGN KEY (owner_user_id) REFERENCES `user` (id),
  CONSTRAINT fk_task_completed_by FOREIGN KEY (completed_by)  REFERENCES `user` (id),
  CONSTRAINT fk_task_created_by   FOREIGN KEY (created_by)    REFERENCES `user` (id),
  CONSTRAINT fk_task_updated_by   FOREIGN KEY (updated_by)    REFERENCES `user` (id),
  CONSTRAINT ck_task_entity CHECK (entity_type IS NULL OR entity_type IN ('LEAD','OPP','ACCOUNT','PARTNER','TENDER','ORDER','OFFER','INVOICE')),
  CONSTRAINT ck_task_type   CHECK (task_type IN ('FOLLOW_UP','VALIDATION','APPROVAL','WEEKLY_STATUS','MONTHLY_COMMIT','ENGAGEMENT','WAKE_UP','INVOICE_DUE','OFFER_EXPIRY','CLOSE_DATE','CUSTOM')),
  CONSTRAINT ck_task_status CHECK (status IN ('OPEN','DONE','CANCELLED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='My day tasks: system-created and manual (12.3)';

CREATE TABLE file_object (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  storage_key      VARCHAR(100)    NOT NULL COMMENT 'Random, non-guessable; files live outside the web root',
  original_name    VARCHAR(255)    NOT NULL,
  mime_type        VARCHAR(150)    NOT NULL,
  size_bytes       BIGINT UNSIGNED NOT NULL,
  checksum_sha256  CHAR(64)        NOT NULL,
  scan_status      VARCHAR(10)     NOT NULL DEFAULT 'PENDING',
  uploaded_by      BIGINT UNSIGNED NULL,
  created_at       DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  UNIQUE KEY ux_file_object_storage_key (storage_key),
  CONSTRAINT fk_file_object_uploaded_by FOREIGN KEY (uploaded_by) REFERENCES `user` (id),
  CONSTRAINT ck_file_object_scan CHECK (scan_status IN ('PENDING','CLEAN','INFECTED','SKIPPED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE document (
  id                      BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  entity_type             VARCHAR(10)      NOT NULL,
  entity_id               BIGINT UNSIGNED  NOT NULL,
  lead_id                 BIGINT UNSIGNED  NULL,
  opportunity_id          BIGINT UNSIGNED  NULL,
  account_id              BIGINT UNSIGNED  NULL,
  partner_id              BIGINT UNSIGNED  NULL,
  file_object_id          BIGINT UNSIGNED  NOT NULL,
  title                   VARCHAR(250)     NOT NULL,
  document_type_id        BIGINT UNSIGNED  NOT NULL,
  shared_with             VARCHAR(10)      NOT NULL DEFAULT 'INTERNAL',
  shared_with_partner_id  BIGINT UNSIGNED  NULL,
  shared_on               DATE             NULL,
  shared_by               BIGINT UNSIGNED  NULL,
  version_no              INT UNSIGNED     NOT NULL DEFAULT 1,
  notes                   VARCHAR(1000)    NULL,
  is_active               TINYINT(1)       NOT NULL DEFAULT 1,
  deleted_at              DATETIME(3)      NULL,
  created_at              DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by              BIGINT UNSIGNED  NULL,
  updated_at              DATETIME(3)      NULL,
  updated_by              BIGINT UNSIGNED  NULL,
  PRIMARY KEY (id),
  KEY ix_document_entity (entity_type, entity_id),
  KEY ix_document_lead (lead_id),
  KEY ix_document_opportunity (opportunity_id),
  KEY ix_document_account (account_id),
  KEY ix_document_partner (partner_id),
  KEY ix_document_shared_with_partner (shared_with_partner_id),
  KEY ix_document_title (title),
  CONSTRAINT fk_document_lead                FOREIGN KEY (lead_id)                REFERENCES sales_lead (id),
  CONSTRAINT fk_document_opportunity         FOREIGN KEY (opportunity_id)         REFERENCES opportunity (id),
  CONSTRAINT fk_document_account             FOREIGN KEY (account_id)             REFERENCES account (id),
  CONSTRAINT fk_document_partner             FOREIGN KEY (partner_id)             REFERENCES partner (id),
  CONSTRAINT fk_document_file_object         FOREIGN KEY (file_object_id)         REFERENCES file_object (id),
  CONSTRAINT fk_document_type                FOREIGN KEY (document_type_id)       REFERENCES document_type (id),
  CONSTRAINT fk_document_shared_with_partner FOREIGN KEY (shared_with_partner_id) REFERENCES partner (id),
  CONSTRAINT fk_document_shared_by           FOREIGN KEY (shared_by)              REFERENCES `user` (id),
  CONSTRAINT fk_document_created_by          FOREIGN KEY (created_by)             REFERENCES `user` (id),
  CONSTRAINT fk_document_updated_by          FOREIGN KEY (updated_by)             REFERENCES `user` (id),
  CONSTRAINT ck_document_entity      CHECK (entity_type IN ('LEAD','OPP','ACCOUNT','PARTNER','TENDER','ORDER')),
  CONSTRAINT ck_document_shared_with CHECK (shared_with IN ('CUSTOMER','PARTNER','INTERNAL'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Every shared document, attached to its record (BR-DC-01)';

CREATE TABLE document_tag (
  document_id  BIGINT UNSIGNED NOT NULL,
  tag          VARCHAR(60)     NOT NULL,
  PRIMARY KEY (document_id, tag),
  KEY ix_document_tag_tag (tag),
  CONSTRAINT fk_document_tag_document FOREIGN KEY (document_id) REFERENCES document (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE weekly_status (
  id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  opportunity_id       BIGINT UNSIGNED NOT NULL,
  week_start           DATE            NOT NULL COMMENT 'Monday',
  status               VARCHAR(10)     NOT NULL,
  this_week            VARCHAR(2000)   NOT NULL,
  next_step            VARCHAR(1000)   NOT NULL,
  expected_close_date  DATE            NULL,
  close_change_reason  VARCHAR(1000)   NULL,
  expected_value       DECIMAL(16,2)   NULL,
  stage_code           VARCHAR(20)     NOT NULL COMMENT 'Snapshot of the deal stage',
  submitted_by         BIGINT UNSIGNED NULL,
  submitted_at         DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  source               VARCHAR(8)      NOT NULL DEFAULT 'INTERNAL',
  created_at           DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by           BIGINT UNSIGNED NULL,
  updated_at           DATETIME(3)     NULL,
  updated_by           BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_weekly_status (opportunity_id, week_start),
  KEY ix_weekly_status_week (week_start, submitted_by),
  CONSTRAINT fk_weekly_status_opportunity  FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_weekly_status_submitted_by FOREIGN KEY (submitted_by)   REFERENCES `user` (id),
  CONSTRAINT fk_weekly_status_created_by   FOREIGN KEY (created_by)     REFERENCES `user` (id),
  CONSTRAINT fk_weekly_status_updated_by   FOREIGN KEY (updated_by)     REFERENCES `user` (id),
  CONSTRAINT ck_weekly_status_status CHECK (status IN ('ON_TRACK','AT_RISK','SLIPPED','STALLED')),
  CONSTRAINT ck_weekly_status_source CHECK (source IN ('INTERNAL','PARTNER')),
  CONSTRAINT ck_weekly_status_monday CHECK (WEEKDAY(week_start) = 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='One weekly status per deal per week (BR-FC-01, BR-FC-02)';

CREATE TABLE monthly_commit (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  opportunity_id  BIGINT UNSIGNED NOT NULL,
  commit_month    DATE            NOT NULL COMMENT 'First day of the month',
  commit_type     VARCHAR(10)     NOT NULL,
  commit_value    DECIMAL(16,2)   NOT NULL,
  committed_by    BIGINT UNSIGNED NULL,
  committed_at    DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  achieved        TINYINT(1)      NULL,
  created_at      DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by      BIGINT UNSIGNED NULL,
  updated_at      DATETIME(3)     NULL,
  updated_by      BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_monthly_commit (opportunity_id, commit_month),
  KEY ix_monthly_commit_month (commit_month),
  CONSTRAINT fk_monthly_commit_opportunity  FOREIGN KEY (opportunity_id) REFERENCES opportunity (id),
  CONSTRAINT fk_monthly_commit_committed_by FOREIGN KEY (committed_by)   REFERENCES `user` (id),
  CONSTRAINT fk_monthly_commit_created_by   FOREIGN KEY (created_by)     REFERENCES `user` (id),
  CONSTRAINT fk_monthly_commit_updated_by   FOREIGN KEY (updated_by)     REFERENCES `user` (id),
  CONSTRAINT ck_monthly_commit_type  CHECK (commit_type IN ('COMMIT','UPSIDE','NEXT_MONTH')),
  CONSTRAINT ck_monthly_commit_month CHECK (DAY(commit_month) = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Monthly closure commitment (BR-FC-03)';

-- -----------------------------------------------------------------------------
-- 8. Orders & tenders (15.9)
-- -----------------------------------------------------------------------------

CREATE TABLE sales_order (
  id                          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_no                    VARCHAR(20)     NOT NULL,
  opportunity_id              BIGINT UNSIGNED NOT NULL,
  account_id                  BIGINT UNSIGNED NOT NULL,
  fulfilment_partner_id       BIGINT UNSIGNED NULL,
  po_number                   VARCHAR(60)     NOT NULL,
  po_date                     DATE            NOT NULL,
  po_value                    DECIMAL(16,2)   NOT NULL,
  po_document_id              BIGINT UNSIGNED NULL,
  billing_to                  VARCHAR(8)      NOT NULL DEFAULT 'CUSTOMER',
  payment_terms               VARCHAR(500)    NULL,
  pay_partner_after_customer  TINYINT(1)      NOT NULL DEFAULT 0,
  status                      VARCHAR(16)     NOT NULL DEFAULT 'PO_RECEIVED',
  po_to_mfr_on                DATE            NULL,
  delivered_on                DATE            NULL,
  deployed_on                 DATE            NULL,
  deployment_reference        VARCHAR(250)    NULL COMMENT 'Free-text link to the implementation record (OD-14)',
  first_invoice_on            DATE            NULL,
  order_to_book_days          INT             NULL,
  invoiced_value              DECIMAL(16,2)   NOT NULL DEFAULT 0,
  received_value              DECIMAL(16,2)   NOT NULL DEFAULT 0,
  released_to_partner_value   DECIMAL(16,2)   NOT NULL DEFAULT 0,
  revenue                     DECIMAL(16,2)   NULL,
  gross_margin_pct            DECIMAL(5,2)    NULL,
  net_profit_pct              DECIMAL(5,2)    NULL,
  revenue_recognised_on       DATE            NULL,
  created_at                  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by                  BIGINT UNSIGNED NULL,
  updated_at                  DATETIME(3)     NULL,
  updated_by                  BIGINT UNSIGNED NULL,
  row_version                 INT UNSIGNED    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_sales_order_no (order_no),
  UNIQUE KEY ux_sales_order_opportunity (opportunity_id),
  KEY ix_sales_order_status (status),
  KEY ix_sales_order_account (account_id),
  KEY ix_sales_order_partner (fulfilment_partner_id),
  CONSTRAINT fk_sales_order_opportunity FOREIGN KEY (opportunity_id)        REFERENCES opportunity (id),
  CONSTRAINT fk_sales_order_account     FOREIGN KEY (account_id)            REFERENCES account (id),
  CONSTRAINT fk_sales_order_partner     FOREIGN KEY (fulfilment_partner_id) REFERENCES partner (id),
  CONSTRAINT fk_sales_order_po_document FOREIGN KEY (po_document_id)        REFERENCES document (id),
  CONSTRAINT fk_sales_order_created_by  FOREIGN KEY (created_by)            REFERENCES `user` (id),
  CONSTRAINT fk_sales_order_updated_by  FOREIGN KEY (updated_by)            REFERENCES `user` (id),
  CONSTRAINT ck_sales_order_billing CHECK (billing_to IN ('CUSTOMER','PARTNER')),
  CONSTRAINT ck_sales_order_status  CHECK (status IN ('PO_RECEIVED','PO_TO_MFR','GOODS_DELIVERED','DEPLOYED','INVOICED','PAID','CLOSED')),
  CONSTRAINT ck_sales_order_gm CHECK (gross_margin_pct IS NULL OR gross_margin_pct BETWEEN -100 AND 100),
  CONSTRAINT ck_sales_order_np CHECK (net_profit_pct IS NULL OR net_profit_pct BETWEEN -100 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Order: PO to payment (UM 6.6); named sales_order because ORDER is reserved';

CREATE TABLE order_event (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id     BIGINT UNSIGNED NOT NULL,
  status       VARCHAR(16)     NOT NULL,
  event_date   DATE            NOT NULL,
  by_user_id   BIGINT UNSIGNED NOT NULL,
  remark       VARCHAR(1000)   NULL,
  document_id  BIGINT UNSIGNED NULL,
  created_at   DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  KEY ix_order_event_order (order_id),
  CONSTRAINT fk_order_event_order    FOREIGN KEY (order_id)    REFERENCES sales_order (id),
  CONSTRAINT fk_order_event_by_user  FOREIGN KEY (by_user_id)  REFERENCES `user` (id),
  CONSTRAINT fk_order_event_document FOREIGN KEY (document_id) REFERENCES document (id),
  CONSTRAINT ck_order_event_status CHECK (status IN ('PO_RECEIVED','PO_TO_MFR','GOODS_DELIVERED','DEPLOYED','INVOICED','PAID','CLOSED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE invoice (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id      BIGINT UNSIGNED NOT NULL,
  invoice_no    VARCHAR(60)     NOT NULL,
  invoice_date  DATE            NOT NULL,
  due_date      DATE            NOT NULL,
  amount        DECIMAL(16,2)   NOT NULL,
  paid_amount   DECIMAL(16,2)   NOT NULL DEFAULT 0,
  status        VARCHAR(10)     NOT NULL DEFAULT 'OPEN',
  document_id   BIGINT UNSIGNED NULL,
  created_at    DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by    BIGINT UNSIGNED NULL,
  updated_at    DATETIME(3)     NULL,
  updated_by    BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_invoice_no (invoice_no),
  KEY ix_invoice_order (order_id),
  KEY ix_invoice_status_due (status, due_date),
  CONSTRAINT fk_invoice_order      FOREIGN KEY (order_id)    REFERENCES sales_order (id),
  CONSTRAINT fk_invoice_document   FOREIGN KEY (document_id) REFERENCES document (id),
  CONSTRAINT fk_invoice_created_by FOREIGN KEY (created_by)  REFERENCES `user` (id),
  CONSTRAINT fk_invoice_updated_by FOREIGN KEY (updated_by)  REFERENCES `user` (id),
  CONSTRAINT ck_invoice_status CHECK (status IN ('OPEN','PART_PAID','PAID','OVERDUE')),
  CONSTRAINT ck_invoice_amount CHECK (amount > 0),
  CONSTRAINT ck_invoice_dates  CHECK (due_date >= invoice_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE payment (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id    BIGINT UNSIGNED NOT NULL,
  invoice_id  BIGINT UNSIGNED NULL,
  direction   VARCHAR(8)      NOT NULL COMMENT 'RECEIVED from the customer / RELEASED to a partner',
  partner_id  BIGINT UNSIGNED NULL,
  amount      DECIMAL(16,2)   NOT NULL,
  paid_on     DATE            NOT NULL,
  reference   VARCHAR(100)    NULL,
  delay_days  INT             NULL,
  remarks     VARCHAR(1000)   NULL,
  created_at  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by  BIGINT UNSIGNED NULL,
  updated_at  DATETIME(3)     NULL,
  updated_by  BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  KEY ix_payment_order (order_id),
  KEY ix_payment_invoice (invoice_id),
  KEY ix_payment_partner (partner_id),
  CONSTRAINT fk_payment_order      FOREIGN KEY (order_id)   REFERENCES sales_order (id),
  CONSTRAINT fk_payment_invoice    FOREIGN KEY (invoice_id) REFERENCES invoice (id),
  CONSTRAINT fk_payment_partner    FOREIGN KEY (partner_id) REFERENCES partner (id),
  CONSTRAINT fk_payment_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT fk_payment_updated_by FOREIGN KEY (updated_by) REFERENCES `user` (id),
  CONSTRAINT ck_payment_direction CHECK (direction IN ('RECEIVED','RELEASED')),
  CONSTRAINT ck_payment_amount    CHECK (amount > 0),
  CONSTRAINT ck_payment_partner   CHECK (direction <> 'RELEASED' OR partner_id IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE tender (
  id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tender_no             VARCHAR(20)     NOT NULL,
  reference_no          VARCHAR(100)    NULL COMMENT 'Tender id / reference on the portal',
  portal                VARCHAR(150)    NULL,
  authority             VARCHAR(200)    NOT NULL,
  account_id            BIGINT UNSIGNED NULL,
  title                 VARCHAR(250)    NOT NULL,
  product_id            BIGINT UNSIGNED NULL,
  estimated_value       DECIMAL(16,2)   NULL,
  our_role              VARCHAR(10)     NOT NULL,
  bidder_partner_id     BIGINT UNSIGNED NULL,
  pre_bid_on            DATE            NULL,
  submission_on         DATE            NULL,
  opening_on            DATE            NULL,
  status                VARCHAR(14)     NOT NULL DEFAULT 'IDENTIFIED',
  spec_influenced       TINYINT(1)      NOT NULL DEFAULT 0,
  rfp_influenced        TINYINT(1)      NOT NULL DEFAULT 0,
  prebid_queries_filed  TINYINT(1)      NOT NULL DEFAULT 0,
  intelligence_notes    TEXT            NULL,
  readiness_pct         DECIMAL(5,2)    NOT NULL DEFAULT 0,
  result                VARCHAR(20)     NULL,
  l1_price              DECIMAL(16,2)   NULL,
  our_price             DECIMAL(16,2)   NULL,
  winner                VARCHAR(200)    NULL,
  loss_reason_id        BIGINT UNSIGNED NULL,
  opportunity_id        BIGINT UNSIGNED NULL,
  owner_user_id         BIGINT UNSIGNED NOT NULL,
  backup_owner_user_id  BIGINT UNSIGNED NULL,
  is_active             TINYINT(1)      NOT NULL DEFAULT 1,
  created_at            DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by            BIGINT UNSIGNED NULL,
  updated_at            DATETIME(3)     NULL,
  updated_by            BIGINT UNSIGNED NULL,
  row_version           INT UNSIGNED    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY ux_tender_no (tender_no),
  KEY ix_tender_owner_status (owner_user_id, status),
  KEY ix_tender_backup_owner (backup_owner_user_id),
  KEY ix_tender_submission (submission_on),
  KEY ix_tender_account (account_id),
  KEY ix_tender_opportunity (opportunity_id),
  CONSTRAINT fk_tender_account        FOREIGN KEY (account_id)           REFERENCES account (id),
  CONSTRAINT fk_tender_product        FOREIGN KEY (product_id)           REFERENCES product (id),
  CONSTRAINT fk_tender_bidder_partner FOREIGN KEY (bidder_partner_id)    REFERENCES partner (id),
  CONSTRAINT fk_tender_loss_reason    FOREIGN KEY (loss_reason_id)       REFERENCES reason (id),
  CONSTRAINT fk_tender_opportunity    FOREIGN KEY (opportunity_id)       REFERENCES opportunity (id),
  CONSTRAINT fk_tender_owner          FOREIGN KEY (owner_user_id)        REFERENCES `user` (id),
  CONSTRAINT fk_tender_backup_owner   FOREIGN KEY (backup_owner_user_id) REFERENCES `user` (id),
  CONSTRAINT fk_tender_created_by     FOREIGN KEY (created_by)           REFERENCES `user` (id),
  CONSTRAINT fk_tender_updated_by     FOREIGN KEY (updated_by)           REFERENCES `user` (id),
  CONSTRAINT ck_tender_role   CHECK (our_role IN ('OEM','BIDDER','CONSORTIUM')),
  CONSTRAINT ck_tender_status CHECK (status IN ('IDENTIFIED','READINESS','CAPTURED','SUBMITTED','TECH_QUALIFIED','L1_L2','AWARDED','NOT_AWARDED','CANCELLED')),
  CONSTRAINT ck_tender_dates  CHECK ((pre_bid_on IS NULL OR submission_on IS NULL OR pre_bid_on <= submission_on)
                                 AND (submission_on IS NULL OR opening_on IS NULL OR submission_on <= opening_on))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Tender master and captured pipeline (UM 4.4)';

CREATE TABLE tender_checklist_item (
  id            BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  tender_id     BIGINT UNSIGNED   NOT NULL,
  item_text     VARCHAR(500)      NOT NULL,
  is_mandatory  TINYINT(1)        NOT NULL DEFAULT 1,
  is_done       TINYINT(1)        NOT NULL DEFAULT 0,
  done_by       BIGINT UNSIGNED   NULL,
  done_at       DATETIME(3)       NULL,
  document_id   BIGINT UNSIGNED   NULL,
  sort_order    SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  created_at    DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by    BIGINT UNSIGNED   NULL,
  updated_at    DATETIME(3)       NULL,
  updated_by    BIGINT UNSIGNED   NULL,
  PRIMARY KEY (id),
  KEY ix_tender_checklist_item_tender (tender_id),
  CONSTRAINT fk_tender_checklist_item_tender     FOREIGN KEY (tender_id)   REFERENCES tender (id),
  CONSTRAINT fk_tender_checklist_item_done_by    FOREIGN KEY (done_by)     REFERENCES `user` (id),
  CONSTRAINT fk_tender_checklist_item_document   FOREIGN KEY (document_id) REFERENCES document (id),
  CONSTRAINT fk_tender_checklist_item_created_by FOREIGN KEY (created_by)  REFERENCES `user` (id),
  CONSTRAINT fk_tender_checklist_item_updated_by FOREIGN KEY (updated_by)  REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Readiness checklist (BR-TD-02)';

-- -----------------------------------------------------------------------------
-- 9. System & audit (15.10)
-- -----------------------------------------------------------------------------

CREATE TABLE audit_log (
  id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type          VARCHAR(40)     NOT NULL,
  entity_id            VARCHAR(80)     NOT NULL COMMENT 'Record id (or key for settings / templates)',
  action               VARCHAR(30)     NOT NULL,
  changed_fields_json  JSON            NULL COMMENT '{"field": {"from": old, "to": new}}',
  reason               VARCHAR(1000)   NULL,
  user_id              BIGINT UNSIGNED NULL,
  ip_address           VARCHAR(45)     NULL,
  request_id           VARCHAR(64)     NULL,
  occurred_at          DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  KEY ix_audit_log_entity (entity_type, entity_id, occurred_at),
  KEY ix_audit_log_user (user_id, occurred_at),
  KEY ix_audit_log_occurred (occurred_at),
  CONSTRAINT fk_audit_log_user FOREIGN KEY (user_id) REFERENCES `user` (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Append-only data audit (18.2)';

CREATE TABLE record_access_log (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type  VARCHAR(40)     NOT NULL,
  entity_id    BIGINT UNSIGNED NULL COMMENT 'NULL for list exports',
  user_id      BIGINT UNSIGNED NOT NULL,
  access_type  VARCHAR(10)     NOT NULL,
  detail       VARCHAR(500)    NULL,
  ip_address   VARCHAR(45)     NULL,
  request_id   VARCHAR(64)     NULL,
  occurred_at  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  KEY ix_record_access_log_entity (entity_type, entity_id),
  KEY ix_record_access_log_user (user_id, occurred_at),
  KEY ix_record_access_log_occurred (occurred_at),
  CONSTRAINT fk_record_access_log_user FOREIGN KEY (user_id) REFERENCES `user` (id),
  CONSTRAINT ck_record_access_log_type CHECK (access_type IN ('VIEW','EXPORT','DOWNLOAD'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='"Every view is logged" (UM 12)';

CREATE TABLE email_log (
  id             BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  template_code  VARCHAR(60)      NULL,
  to_address     VARCHAR(500)     NOT NULL,
  subject        VARCHAR(255)     NOT NULL,
  entity_type    VARCHAR(40)      NULL,
  entity_id      BIGINT UNSIGNED  NULL,
  status         VARCHAR(8)       NOT NULL DEFAULT 'QUEUED',
  error          VARCHAR(1000)    NULL,
  attempts       TINYINT UNSIGNED NOT NULL DEFAULT 0,
  sent_at        DATETIME(3)      NULL,
  created_at     DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  updated_at     DATETIME(3)      NULL,
  PRIMARY KEY (id),
  KEY ix_email_log_status (status, created_at),
  CONSTRAINT ck_email_log_status CHECK (status IN ('QUEUED','SENT','FAILED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE import_batch (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity          VARCHAR(20)     NOT NULL,
  file_object_id  BIGINT UNSIGNED NOT NULL,
  status          VARCHAR(10)     NOT NULL DEFAULT 'PREVIEW',
  mapping_json    JSON            NULL,
  total_rows      INT UNSIGNED    NOT NULL DEFAULT 0,
  created_count   INT UNSIGNED    NOT NULL DEFAULT 0,
  skipped_count   INT UNSIGNED    NOT NULL DEFAULT 0,
  error_count     INT UNSIGNED    NOT NULL DEFAULT 0,
  committed_by    BIGINT UNSIGNED NULL,
  committed_at    DATETIME(3)     NULL,
  created_at      DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by      BIGINT UNSIGNED NULL,
  updated_at      DATETIME(3)     NULL,
  updated_by      BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  KEY ix_import_batch_status (status),
  CONSTRAINT fk_import_batch_file         FOREIGN KEY (file_object_id) REFERENCES file_object (id),
  CONSTRAINT fk_import_batch_committed_by FOREIGN KEY (committed_by)   REFERENCES `user` (id),
  CONSTRAINT fk_import_batch_created_by   FOREIGN KEY (created_by)     REFERENCES `user` (id),
  CONSTRAINT fk_import_batch_updated_by   FOREIGN KEY (updated_by)     REFERENCES `user` (id),
  CONSTRAINT ck_import_batch_status CHECK (status IN ('PREVIEW','VALIDATED','COMMITTED','FAILED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE import_row (
  id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  batch_id           BIGINT UNSIGNED NOT NULL,
  row_no             INT UNSIGNED    NOT NULL,
  raw_json           JSON            NOT NULL,
  mapped_json        JSON            NULL,
  record_type        VARCHAR(10)     NULL COMMENT 'Trial import: LEAD / PARTNER / ACCOUNT / IGNORE',
  status             VARCHAR(10)     NOT NULL DEFAULT 'PENDING',
  errors_json        JSON            NULL,
  created_entity_id  BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_import_row (batch_id, row_no),
  CONSTRAINT fk_import_row_batch FOREIGN KEY (batch_id) REFERENCES import_batch (id),
  CONSTRAINT ck_import_row_status CHECK (status IN ('PENDING','VALID','INVALID','CREATED','SKIPPED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE job_lock (
  job_name      VARCHAR(60)  NOT NULL,
  locked_until  DATETIME(3)  NULL,
  locked_by     VARCHAR(100) NULL,
  updated_at    DATETIME(3)  NULL,
  PRIMARY KEY (job_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Prevents double runs of scheduled jobs (8.10)';

CREATE TABLE job_run_log (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  job_name         VARCHAR(60)     NOT NULL,
  started_at       DATETIME(3)     NOT NULL,
  finished_at      DATETIME(3)     NULL,
  status           VARCHAR(10)     NOT NULL DEFAULT 'RUNNING',
  processed_count  INT UNSIGNED    NOT NULL DEFAULT 0,
  error            VARCHAR(2000)   NULL,
  PRIMARY KEY (id),
  KEY ix_job_run_log_job (job_name, started_at),
  CONSTRAINT ck_job_run_log_status CHECK (status IN ('RUNNING','SUCCESS','FAILED','SKIPPED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- 10. Phase 2: partner self-service (10.10, 12.19)
-- -----------------------------------------------------------------------------

CREATE TABLE partner_portal_access (
  id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  partner_id      BIGINT UNSIGNED  NOT NULL,
  contact_id      BIGINT UNSIGNED  NULL,
  email           VARCHAR(150)     NOT NULL,
  purpose         VARCHAR(5)       NOT NULL,
  token_hash      CHAR(64)         NOT NULL,
  valid_from      DATETIME(3)      NOT NULL,
  valid_to        DATETIME(3)      NOT NULL,
  otp_hash        CHAR(64)         NULL,
  otp_expires_at  DATETIME(3)      NULL,
  otp_attempts    TINYINT UNSIGNED NOT NULL DEFAULT 0,
  revoked_at      DATETIME(3)      NULL,
  created_at      DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  created_by      BIGINT UNSIGNED  NULL,
  PRIMARY KEY (id),
  UNIQUE KEY ux_partner_portal_access_token (token_hash),
  KEY ix_partner_portal_access_partner (partner_id),
  KEY ix_partner_portal_access_email (email),
  CONSTRAINT fk_partner_portal_access_partner    FOREIGN KEY (partner_id) REFERENCES partner (id),
  CONSTRAINT fk_partner_portal_access_contact    FOREIGN KEY (contact_id) REFERENCES contact (id),
  CONSTRAINT fk_partner_portal_access_created_by FOREIGN KEY (created_by) REFERENCES `user` (id),
  CONSTRAINT ck_partner_portal_access_purpose CHECK (purpose IN ('FORM','DEALS'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE partner_portal_session (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  access_id           BIGINT UNSIGNED NOT NULL,
  session_token_hash  CHAR(64)        NOT NULL,
  expires_at          DATETIME(3)     NOT NULL,
  revoked_at          DATETIME(3)     NULL,
  ip_address          VARCHAR(45)     NULL,
  created_at          DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  UNIQUE KEY ux_partner_portal_session_token (session_token_hash),
  KEY ix_partner_portal_session_access (access_id),
  CONSTRAINT fk_partner_portal_session_access FOREIGN KEY (access_id) REFERENCES partner_portal_access (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE partner_submission (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  partner_id    BIGINT UNSIGNED NOT NULL,
  access_id     BIGINT UNSIGNED NOT NULL,
  section       VARCHAR(20)     NOT NULL,
  payload_json  JSON            NOT NULL,
  status        VARCHAR(20)     NOT NULL DEFAULT 'PENDING',
  reviewed_by   BIGINT UNSIGNED NULL,
  reviewed_at   DATETIME(3)     NULL,
  created_at    DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
  PRIMARY KEY (id),
  KEY ix_partner_submission_partner (partner_id, status),
  CONSTRAINT fk_partner_submission_partner     FOREIGN KEY (partner_id)  REFERENCES partner (id),
  CONSTRAINT fk_partner_submission_access      FOREIGN KEY (access_id)   REFERENCES partner_portal_access (id),
  CONSTRAINT fk_partner_submission_reviewed_by FOREIGN KEY (reviewed_by) REFERENCES `user` (id),
  CONSTRAINT ck_partner_submission_status CHECK (status IN ('PENDING','ACCEPTED','PARTIALLY_ACCEPTED','REJECTED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='Partner profile changes awaiting review (BR-PT-08)';

SET FOREIGN_KEY_CHECKS = 1;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V001', 'Full version 1 schema (79 tables)', 'V001__schema.sql');
