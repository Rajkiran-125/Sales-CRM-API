-- =============================================================================
-- V006  Sales CRM - masters, settings and email templates (M15)   (2026-10-09)
--
--   Simple masters (code, name, order, active) through one set of procedures:
--     PARTNER_TYPE, INDUSTRY, PRODUCT, PROCUREMENT_TYPE, DOCUMENT_TYPE, CERTIFICATION_TYPE
--     (table names come from a fixed allow-list; values are always bound as ?)
--   Dedicated procedures: solutions, reasons, competitors, procurement steps,
--   stages (name / confidence / SLA / colour only - codes, order and active flag
--   are fixed because the gates depend on them), settings, email templates.
--   Masters are deactivated, never deleted (9.5). Codes cannot change after
--   creation. Every change is audited (18.2).
--
-- Re-runnable. Prerequisite: V001-V005. Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- spi_master_table: allow-list of the simple master types
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_master_table $$
CREATE PROCEDURE spi_master_table(IN p_type VARCHAR(30), OUT p_table VARCHAR(64))
  SQL SECURITY DEFINER
BEGIN
  SET p_table = CASE p_type
                  WHEN 'PARTNER_TYPE'       THEN 'partner_type'
                  WHEN 'INDUSTRY'           THEN 'industry'
                  WHEN 'PRODUCT'            THEN 'product'
                  WHEN 'PROCUREMENT_TYPE'   THEN 'procurement_type'
                  WHEN 'DOCUMENT_TYPE'      THEN 'document_type'
                  WHEN 'CERTIFICATION_TYPE' THEN 'certification_type'
                  ELSE NULL
                END;
  IF p_table IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Unknown master type.', 'type');
  END IF;
END $$

DROP PROCEDURE IF EXISTS sp_master_simple_list $$
CREATE PROCEDURE sp_master_simple_list(IN p_type VARCHAR(30), IN p_include_inactive TINYINT)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_table VARCHAR(64);
  CALL spi_master_table(p_type, v_table);

  SET @crm_sql = CONCAT('SELECT id, code, name, sort_order AS sortOrder, is_active AS isActive, updated_at AS updatedAt',
                        ' FROM ', v_table,
                        ' WHERE (? = 1 OR is_active = 1) ORDER BY sort_order, name');
  SET @crm_p1 = IFNULL(p_include_inactive, 0);
  PREPARE crm_stmt FROM @crm_sql;
  EXECUTE crm_stmt USING @crm_p1;
  DEALLOCATE PREPARE crm_stmt;
END $$

DROP PROCEDURE IF EXISTS sp_master_simple_get $$
CREATE PROCEDURE sp_master_simple_get(IN p_type VARCHAR(30), IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_table VARCHAR(64);
  CALL spi_master_table(p_type, v_table);

  SET @crm_sql = CONCAT('SELECT id, code, name, sort_order AS sortOrder, is_active AS isActive, updated_at AS updatedAt',
                        ' FROM ', v_table, ' WHERE id = ?');
  SET @crm_p1 = p_id;
  PREPARE crm_stmt FROM @crm_sql;
  EXECUTE crm_stmt USING @crm_p1;
  DEALLOCATE PREPARE crm_stmt;
END $$

DROP PROCEDURE IF EXISTS sp_master_simple_create $$
CREATE PROCEDURE sp_master_simple_create(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_type          VARCHAR(30),
  IN p_code          VARCHAR(40),
  IN p_name          VARCHAR(100),
  IN p_sort_order    SMALLINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_table VARCHAR(64);
  DECLARE v_id    BIGINT UNSIGNED;
  DECLARE v_code  VARCHAR(40)  DEFAULT UPPER(TRIM(p_code));
  DECLARE v_name  VARCHAR(100) DEFAULT TRIM(p_name);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_master_table(p_type, v_table);

  START TRANSACTION;
  SET @crm_sql = CONCAT('SELECT COUNT(*) INTO @crm_cnt FROM ', v_table, ' WHERE code = ?');
  SET @crm_p1 = v_code;
  PREPARE crm_stmt FROM @crm_sql;
  EXECUTE crm_stmt USING @crm_p1;
  DEALLOCATE PREPARE crm_stmt;
  IF @crm_cnt > 0 THEN
    CALL spi_raise('DUPLICATE', 'An entry with this code already exists.', 'code');
  END IF;

  SET @crm_sql = CONCAT('INSERT INTO ', v_table,
                        ' (code, name, sort_order, is_active, created_at, created_by) VALUES (?, ?, ?, 1, UTC_TIMESTAMP(3), ?)');
  SET @crm_p1 = v_code, @crm_p2 = v_name, @crm_p3 = IFNULL(p_sort_order, 0), @crm_p4 = p_actor_user_id;
  PREPARE crm_stmt FROM @crm_sql;
  EXECUTE crm_stmt USING @crm_p1, @crm_p2, @crm_p3, @crm_p4;
  DEALLOCATE PREPARE crm_stmt;
  SET v_id = LAST_INSERT_ID();

  CALL spi_audit_write(p_type, v_id, 'CREATE',
                       JSON_OBJECT('code', JSON_OBJECT('from', NULL, 'to', v_code),
                                   'name', JSON_OBJECT('from', NULL, 'to', v_name)),
                       NULL, p_actor_user_id, p_ip, p_request_id);
  COMMIT;
  CALL sp_master_simple_get(p_type, v_id);
END $$

DROP PROCEDURE IF EXISTS sp_master_simple_update $$
CREATE PROCEDURE sp_master_simple_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_type          VARCHAR(30),
  IN p_id            BIGINT UNSIGNED,
  IN p_name          VARCHAR(100),
  IN p_sort_order    SMALLINT UNSIGNED,
  IN p_is_active     TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_table   VARCHAR(64);
  DECLARE v_changes JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_master_table(p_type, v_table);

  START TRANSACTION;
  SET @crm_old_id = NULL, @crm_old_name = NULL, @crm_old_sort = NULL, @crm_old_active = NULL;
  SET @crm_sql = CONCAT('SELECT id, name, sort_order, is_active INTO @crm_old_id, @crm_old_name, @crm_old_sort, @crm_old_active',
                        ' FROM ', v_table, ' WHERE id = ? FOR UPDATE');
  SET @crm_p1 = p_id;
  PREPARE crm_stmt FROM @crm_sql;
  EXECUTE crm_stmt USING @crm_p1;
  DEALLOCATE PREPARE crm_stmt;

  IF @crm_old_id IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Entry not found.', 'id');
  END IF;

  CALL spi_diff(v_changes, 'name',      @crm_old_name,   TRIM(p_name));
  CALL spi_diff(v_changes, 'sortOrder', @crm_old_sort,   IFNULL(p_sort_order, 0));
  CALL spi_diff(v_changes, 'isActive',  @crm_old_active, IFNULL(p_is_active, 1));

  SET @crm_sql = CONCAT('UPDATE ', v_table,
                        ' SET name = ?, sort_order = ?, is_active = ?, updated_at = UTC_TIMESTAMP(3), updated_by = ? WHERE id = ?');
  SET @crm_p1 = TRIM(p_name), @crm_p2 = IFNULL(p_sort_order, 0), @crm_p3 = IFNULL(p_is_active, 1),
      @crm_p4 = p_actor_user_id, @crm_p5 = p_id;
  PREPARE crm_stmt FROM @crm_sql;
  EXECUTE crm_stmt USING @crm_p1, @crm_p2, @crm_p3, @crm_p4, @crm_p5;
  DEALLOCATE PREPARE crm_stmt;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write(p_type, p_id, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
  END IF;
  COMMIT;
  CALL sp_master_simple_get(p_type, p_id);
END $$

-- -----------------------------------------------------------------------------
-- Solutions (per product)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_solution_list $$
CREATE PROCEDURE sp_solution_list(IN p_product_id BIGINT UNSIGNED, IN p_include_inactive TINYINT)
  SQL SECURITY DEFINER
BEGIN
  SELECT s.id, s.product_id AS productId, p.name AS productName, s.name, s.description,
         s.sort_order AS sortOrder, s.is_active AS isActive, s.updated_at AS updatedAt
    FROM solution s JOIN product p ON p.id = s.product_id
   WHERE (p_product_id IS NULL OR s.product_id = p_product_id)
     AND (IFNULL(p_include_inactive, 0) = 1 OR s.is_active = 1)
   ORDER BY p.sort_order, p.name, s.sort_order, s.name;
END $$

DROP PROCEDURE IF EXISTS sp_solution_create $$
CREATE PROCEDURE sp_solution_create(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_product_id    BIGINT UNSIGNED,
  IN p_name          VARCHAR(150),
  IN p_description   VARCHAR(500),
  IN p_sort_order    SMALLINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM product WHERE id = p_product_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'The product does not exist or is inactive.', 'productId');
  END IF;
  IF EXISTS (SELECT 1 FROM solution WHERE product_id = p_product_id AND name = TRIM(p_name)) THEN
    CALL spi_raise('DUPLICATE', 'This product already has a solution with this name.', 'name');
  END IF;

  INSERT INTO solution (product_id, name, description, sort_order, is_active, created_at, created_by)
  VALUES (p_product_id, TRIM(p_name), NULLIF(TRIM(p_description), ''), IFNULL(p_sort_order, 0), 1, UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();

  CALL spi_audit_write('SOLUTION', v_id, 'CREATE',
                       JSON_OBJECT('productId', JSON_OBJECT('from', NULL, 'to', p_product_id),
                                   'name',      JSON_OBJECT('from', NULL, 'to', TRIM(p_name))),
                       NULL, p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT s.id, s.product_id AS productId, p.name AS productName, s.name, s.description,
         s.sort_order AS sortOrder, s.is_active AS isActive, s.updated_at AS updatedAt
    FROM solution s JOIN product p ON p.id = s.product_id WHERE s.id = v_id;
END $$

DROP PROCEDURE IF EXISTS sp_solution_update $$
CREATE PROCEDURE sp_solution_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_name          VARCHAR(150),
  IN p_description   VARCHAR(500),
  IN p_sort_order    SMALLINT UNSIGNED,
  IN p_is_active     TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_found      BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_product_id BIGINT UNSIGNED;
  DECLARE v_name       VARCHAR(150);
  DECLARE v_desc       VARCHAR(500);
  DECLARE v_sort       SMALLINT UNSIGNED;
  DECLARE v_active     TINYINT;
  DECLARE v_changes    JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT id, product_id, name, description, sort_order, is_active
    INTO v_found, v_product_id, v_name, v_desc, v_sort, v_active
    FROM solution WHERE id = p_id FOR UPDATE;
  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Solution not found.', 'id');
  END IF;
  IF EXISTS (SELECT 1 FROM solution WHERE product_id = v_product_id AND name = TRIM(p_name) AND id <> p_id) THEN
    CALL spi_raise('DUPLICATE', 'This product already has a solution with this name.', 'name');
  END IF;

  CALL spi_diff(v_changes, 'name',        v_name,   TRIM(p_name));
  CALL spi_diff(v_changes, 'description', v_desc,   NULLIF(TRIM(p_description), ''));
  CALL spi_diff(v_changes, 'sortOrder',   v_sort,   IFNULL(p_sort_order, 0));
  CALL spi_diff(v_changes, 'isActive',    v_active, IFNULL(p_is_active, 1));

  UPDATE solution
     SET name = TRIM(p_name), description = NULLIF(TRIM(p_description), ''), sort_order = IFNULL(p_sort_order, 0),
         is_active = IFNULL(p_is_active, 1), updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE id = p_id;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write('SOLUTION', p_id, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
  END IF;
  COMMIT;

  SELECT s.id, s.product_id AS productId, p.name AS productName, s.name, s.description,
         s.sort_order AS sortOrder, s.is_active AS isActive, s.updated_at AS updatedAt
    FROM solution s JOIN product p ON p.id = s.product_id WHERE s.id = p_id;
END $$

-- -----------------------------------------------------------------------------
-- Reasons (win / loss / disqualify / dormant / not valid)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_reason_list $$
CREATE PROCEDURE sp_reason_list(IN p_reason_type VARCHAR(12), IN p_include_inactive TINYINT)
  SQL SECURITY DEFINER
BEGIN
  SELECT id, reason_type AS reasonType, code, name, category, competitor_required AS competitorRequired,
         sort_order AS sortOrder, is_active AS isActive, updated_at AS updatedAt
    FROM reason
   WHERE (p_reason_type IS NULL OR reason_type = p_reason_type)
     AND (IFNULL(p_include_inactive, 0) = 1 OR is_active = 1)
   ORDER BY reason_type, sort_order, name;
END $$

DROP PROCEDURE IF EXISTS sp_reason_create $$
CREATE PROCEDURE sp_reason_create(
  IN p_actor_user_id       BIGINT UNSIGNED,
  IN p_request_id          VARCHAR(64),
  IN p_ip                  VARCHAR(45),
  IN p_reason_type         VARCHAR(12),
  IN p_code                VARCHAR(40),
  IN p_name                VARCHAR(150),
  IN p_category            VARCHAR(100),
  IN p_competitor_required TINYINT,
  IN p_sort_order          SMALLINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id   BIGINT UNSIGNED;
  DECLARE v_code VARCHAR(40) DEFAULT UPPER(TRIM(p_code));
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_reason_type NOT IN ('WIN', 'LOSS', 'DISQUALIFY', 'DORMANT', 'NOT_VALID') THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown reason type.', 'reasonType');
  END IF;

  START TRANSACTION;
  IF EXISTS (SELECT 1 FROM reason WHERE reason_type = p_reason_type AND code = v_code) THEN
    CALL spi_raise('DUPLICATE', 'A reason with this code already exists for this type.', 'code');
  END IF;

  INSERT INTO reason (reason_type, code, name, category, competitor_required, sort_order, is_active, created_at, created_by)
  VALUES (p_reason_type, v_code, TRIM(p_name), NULLIF(TRIM(p_category), ''),
          IF(p_reason_type = 'LOSS', IFNULL(p_competitor_required, 0), 0), IFNULL(p_sort_order, 0), 1,
          UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();

  CALL spi_audit_write('REASON', v_id, 'CREATE',
                       JSON_OBJECT('reasonType', JSON_OBJECT('from', NULL, 'to', p_reason_type),
                                   'code',       JSON_OBJECT('from', NULL, 'to', v_code),
                                   'name',       JSON_OBJECT('from', NULL, 'to', TRIM(p_name))),
                       NULL, p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT id, reason_type AS reasonType, code, name, category, competitor_required AS competitorRequired,
         sort_order AS sortOrder, is_active AS isActive, updated_at AS updatedAt
    FROM reason WHERE id = v_id;
END $$

DROP PROCEDURE IF EXISTS sp_reason_update $$
CREATE PROCEDURE sp_reason_update(
  IN p_actor_user_id       BIGINT UNSIGNED,
  IN p_request_id          VARCHAR(64),
  IN p_ip                  VARCHAR(45),
  IN p_id                  BIGINT UNSIGNED,
  IN p_name                VARCHAR(150),
  IN p_category            VARCHAR(100),
  IN p_competitor_required TINYINT,
  IN p_sort_order          SMALLINT UNSIGNED,
  IN p_is_active           TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_found    BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_type     VARCHAR(12);
  DECLARE v_name     VARCHAR(150);
  DECLARE v_category VARCHAR(100);
  DECLARE v_comp     TINYINT;
  DECLARE v_sort     SMALLINT UNSIGNED;
  DECLARE v_active   TINYINT;
  DECLARE v_new_comp TINYINT;
  DECLARE v_changes  JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT id, reason_type, name, category, competitor_required, sort_order, is_active
    INTO v_found, v_type, v_name, v_category, v_comp, v_sort, v_active
    FROM reason WHERE id = p_id FOR UPDATE;
  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Reason not found.', 'id');
  END IF;

  SET v_new_comp = IF(v_type = 'LOSS', IFNULL(p_competitor_required, 0), 0);
  CALL spi_diff(v_changes, 'name',               v_name,     TRIM(p_name));
  CALL spi_diff(v_changes, 'category',           v_category, NULLIF(TRIM(p_category), ''));
  CALL spi_diff(v_changes, 'competitorRequired', v_comp,     v_new_comp);
  CALL spi_diff(v_changes, 'sortOrder',          v_sort,     IFNULL(p_sort_order, 0));
  CALL spi_diff(v_changes, 'isActive',           v_active,   IFNULL(p_is_active, 1));

  UPDATE reason
     SET name = TRIM(p_name), category = NULLIF(TRIM(p_category), ''), competitor_required = v_new_comp,
         sort_order = IFNULL(p_sort_order, 0), is_active = IFNULL(p_is_active, 1),
         updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE id = p_id;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write('REASON', p_id, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
  END IF;
  COMMIT;

  SELECT id, reason_type AS reasonType, code, name, category, competitor_required AS competitorRequired,
         sort_order AS sortOrder, is_active AS isActive, updated_at AS updatedAt
    FROM reason WHERE id = p_id;
END $$

-- -----------------------------------------------------------------------------
-- Competitors
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_competitor_list $$
CREATE PROCEDURE sp_competitor_list(IN p_include_inactive TINYINT)
  SQL SECURITY DEFINER
BEGIN
  SELECT id, name, products, strengths, weaknesses, is_active AS isActive, updated_at AS updatedAt
    FROM competitor
   WHERE IFNULL(p_include_inactive, 0) = 1 OR is_active = 1
   ORDER BY name;
END $$

DROP PROCEDURE IF EXISTS sp_competitor_create $$
CREATE PROCEDURE sp_competitor_create(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_name          VARCHAR(150),
  IN p_products      VARCHAR(500),
  IN p_strengths     TEXT,
  IN p_weaknesses    TEXT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  IF EXISTS (SELECT 1 FROM competitor WHERE name = TRIM(p_name)) THEN
    CALL spi_raise('DUPLICATE', 'A competitor with this name already exists.', 'name');
  END IF;

  INSERT INTO competitor (name, products, strengths, weaknesses, is_active, created_at, created_by)
  VALUES (TRIM(p_name), NULLIF(TRIM(p_products), ''), NULLIF(TRIM(p_strengths), ''), NULLIF(TRIM(p_weaknesses), ''),
          1, UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();

  CALL spi_audit_write('COMPETITOR', v_id, 'CREATE', JSON_OBJECT('name', JSON_OBJECT('from', NULL, 'to', TRIM(p_name))),
                       NULL, p_actor_user_id, p_ip, p_request_id);
  COMMIT;
  SELECT id, name, products, strengths, weaknesses, is_active AS isActive, updated_at AS updatedAt
    FROM competitor WHERE id = v_id;
END $$

DROP PROCEDURE IF EXISTS sp_competitor_update $$
CREATE PROCEDURE sp_competitor_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_name          VARCHAR(150),
  IN p_products      VARCHAR(500),
  IN p_strengths     TEXT,
  IN p_weaknesses    TEXT,
  IN p_is_active     TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_found      BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_name       VARCHAR(150);
  DECLARE v_products   VARCHAR(500);
  DECLARE v_strengths  TEXT;
  DECLARE v_weaknesses TEXT;
  DECLARE v_active     TINYINT;
  DECLARE v_changes    JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT id, name, products, strengths, weaknesses, is_active
    INTO v_found, v_name, v_products, v_strengths, v_weaknesses, v_active
    FROM competitor WHERE id = p_id FOR UPDATE;
  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Competitor not found.', 'id');
  END IF;
  IF EXISTS (SELECT 1 FROM competitor WHERE name = TRIM(p_name) AND id <> p_id) THEN
    CALL spi_raise('DUPLICATE', 'A competitor with this name already exists.', 'name');
  END IF;

  CALL spi_diff(v_changes, 'name',       v_name,       TRIM(p_name));
  CALL spi_diff(v_changes, 'products',   v_products,   NULLIF(TRIM(p_products), ''));
  CALL spi_diff(v_changes, 'strengths',  v_strengths,  NULLIF(TRIM(p_strengths), ''));
  CALL spi_diff(v_changes, 'weaknesses', v_weaknesses, NULLIF(TRIM(p_weaknesses), ''));
  CALL spi_diff(v_changes, 'isActive',   v_active,     IFNULL(p_is_active, 1));

  UPDATE competitor
     SET name = TRIM(p_name), products = NULLIF(TRIM(p_products), ''), strengths = NULLIF(TRIM(p_strengths), ''),
         weaknesses = NULLIF(TRIM(p_weaknesses), ''), is_active = IFNULL(p_is_active, 1),
         updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE id = p_id;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write('COMPETITOR', p_id, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
  END IF;
  COMMIT;
  SELECT id, name, products, strengths, weaknesses, is_active AS isActive, updated_at AS updatedAt
    FROM competitor WHERE id = p_id;
END $$

-- -----------------------------------------------------------------------------
-- Procurement steps (per procurement type)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_procurement_step_list $$
CREATE PROCEDURE sp_procurement_step_list(IN p_procurement_type_id BIGINT UNSIGNED, IN p_include_inactive TINYINT)
  SQL SECURITY DEFINER
BEGIN
  SELECT s.id, s.procurement_type_id AS procurementTypeId, t.name AS procurementTypeName,
         s.sequence_no AS sequenceNo, s.name, s.hint_confidence_pct AS hintConfidencePct,
         s.is_active AS isActive, s.updated_at AS updatedAt
    FROM procurement_step s JOIN procurement_type t ON t.id = s.procurement_type_id
   WHERE (p_procurement_type_id IS NULL OR s.procurement_type_id = p_procurement_type_id)
     AND (IFNULL(p_include_inactive, 0) = 1 OR s.is_active = 1)
   ORDER BY t.sort_order, t.name, s.sequence_no;
END $$

DROP PROCEDURE IF EXISTS sp_procurement_step_create $$
CREATE PROCEDURE sp_procurement_step_create(
  IN p_actor_user_id       BIGINT UNSIGNED,
  IN p_request_id          VARCHAR(64),
  IN p_ip                  VARCHAR(45),
  IN p_procurement_type_id BIGINT UNSIGNED,
  IN p_sequence_no         SMALLINT UNSIGNED,
  IN p_name                VARCHAR(150),
  IN p_hint_pct            DECIMAL(5,2)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM procurement_type WHERE id = p_procurement_type_id) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown procurement type.', 'procurementTypeId');
  END IF;
  IF EXISTS (SELECT 1 FROM procurement_step WHERE procurement_type_id = p_procurement_type_id AND sequence_no = p_sequence_no) THEN
    CALL spi_raise('DUPLICATE', 'This procurement type already has a step with this number.', 'sequenceNo');
  END IF;

  INSERT INTO procurement_step (procurement_type_id, sequence_no, name, hint_confidence_pct, is_active, created_at, created_by)
  VALUES (p_procurement_type_id, p_sequence_no, TRIM(p_name), p_hint_pct, 1, UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();

  CALL spi_audit_write('PROCUREMENT_STEP', v_id, 'CREATE',
                       JSON_OBJECT('procurementTypeId', JSON_OBJECT('from', NULL, 'to', p_procurement_type_id),
                                   'sequenceNo',        JSON_OBJECT('from', NULL, 'to', p_sequence_no),
                                   'name',              JSON_OBJECT('from', NULL, 'to', TRIM(p_name))),
                       NULL, p_actor_user_id, p_ip, p_request_id);
  COMMIT;
  CALL sp_procurement_step_list(p_procurement_type_id, 1);
END $$

DROP PROCEDURE IF EXISTS sp_procurement_step_update $$
CREATE PROCEDURE sp_procurement_step_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_sequence_no   SMALLINT UNSIGNED,
  IN p_name          VARCHAR(150),
  IN p_hint_pct      DECIMAL(5,2),
  IN p_is_active     TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_found   BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_type_id BIGINT UNSIGNED;
  DECLARE v_seq     SMALLINT UNSIGNED;
  DECLARE v_name    VARCHAR(150);
  DECLARE v_hint    DECIMAL(5,2);
  DECLARE v_active  TINYINT;
  DECLARE v_changes JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT id, procurement_type_id, sequence_no, name, hint_confidence_pct, is_active
    INTO v_found, v_type_id, v_seq, v_name, v_hint, v_active
    FROM procurement_step WHERE id = p_id FOR UPDATE;
  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Procurement step not found.', 'id');
  END IF;
  IF EXISTS (SELECT 1 FROM procurement_step
              WHERE procurement_type_id = v_type_id AND sequence_no = p_sequence_no AND id <> p_id) THEN
    CALL spi_raise('DUPLICATE', 'This procurement type already has a step with this number.', 'sequenceNo');
  END IF;

  CALL spi_diff(v_changes, 'sequenceNo',        v_seq,    p_sequence_no);
  CALL spi_diff(v_changes, 'name',              v_name,   TRIM(p_name));
  CALL spi_diff(v_changes, 'hintConfidencePct', v_hint,   p_hint_pct);
  CALL spi_diff(v_changes, 'isActive',          v_active, IFNULL(p_is_active, 1));

  UPDATE procurement_step
     SET sequence_no = p_sequence_no, name = TRIM(p_name), hint_confidence_pct = p_hint_pct,
         is_active = IFNULL(p_is_active, 1), updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE id = p_id;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write('PROCUREMENT_STEP', p_id, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
  END IF;
  COMMIT;
  CALL sp_procurement_step_list(v_type_id, 1);
END $$

-- -----------------------------------------------------------------------------
-- Stages (OD-03, OD-47): codes, order and active flag are fixed
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_stage_list $$
CREATE PROCEDURE sp_stage_list(IN p_entity VARCHAR(10))
  SQL SECURITY DEFINER
BEGIN
  SELECT id, entity, code, name, sequence_no AS sequenceNo, default_confidence_pct AS defaultConfidencePct,
         is_open AS isOpen, is_won AS isWon, is_lost AS isLost, sla_days AS slaDays,
         colour_token AS colourToken, updated_at AS updatedAt
    FROM stage
   WHERE p_entity IS NULL OR entity = p_entity
   ORDER BY FIELD(entity, 'LEAD', 'OPP', 'TENDER', 'ORDER'), sequence_no;
END $$

DROP PROCEDURE IF EXISTS sp_stage_update $$
CREATE PROCEDURE sp_stage_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_name          VARCHAR(100),
  IN p_confidence    DECIMAL(5,2),
  IN p_sla_days      SMALLINT UNSIGNED,
  IN p_colour_token  VARCHAR(40)
)
  SQL SECURITY DEFINER
  COMMENT 'Edit a stage; a new default confidence re-weights the open deals in that stage (BR-OP-06)'
BEGIN
  DECLARE v_found      BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_entity     VARCHAR(10);
  DECLARE v_code       VARCHAR(30);
  DECLARE v_name       VARCHAR(100);
  DECLARE v_confidence DECIMAL(5,2);
  DECLARE v_sla        SMALLINT UNSIGNED;
  DECLARE v_colour     VARCHAR(40);
  DECLARE v_is_open    TINYINT;
  DECLARE v_changes    JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT id, entity, code, name, default_confidence_pct, sla_days, colour_token, is_open
    INTO v_found, v_entity, v_code, v_name, v_confidence, v_sla, v_colour, v_is_open
    FROM stage WHERE id = p_id FOR UPDATE;
  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Stage not found.', 'id');
  END IF;

  IF v_entity <> 'OPP' AND p_confidence IS NOT NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Only opportunity stages have a confidence %.', 'defaultConfidencePct');
  END IF;
  IF v_entity = 'OPP' AND v_code IN ('WON', 'LOST', 'DORMANT') AND NOT (p_confidence <=> v_confidence) THEN
    CALL spi_raise('BUSINESS_RULE_VIOLATION', 'The confidence of Won, Lost and Dormant is fixed (100 % only at PO).', 'defaultConfidencePct');
  END IF;
  IF v_entity = 'OPP' AND v_is_open = 1 AND (p_confidence IS NULL OR p_confidence < 0 OR p_confidence >= 100) THEN
    CALL spi_raise('VALIDATION_FAILED', 'An open stage needs a confidence from 0 to 99.99 %.', 'defaultConfidencePct');
  END IF;

  CALL spi_diff(v_changes, 'name',                 v_name,       TRIM(p_name));
  CALL spi_diff(v_changes, 'defaultConfidencePct', v_confidence, p_confidence);
  CALL spi_diff(v_changes, 'slaDays',              v_sla,        p_sla_days);
  CALL spi_diff(v_changes, 'colourToken',          v_colour,     NULLIF(TRIM(p_colour_token), ''));

  UPDATE stage
     SET name = TRIM(p_name), default_confidence_pct = p_confidence, sla_days = p_sla_days,
         colour_token = NULLIF(TRIM(p_colour_token), ''), updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE id = p_id;

  IF v_entity = 'OPP' AND v_is_open = 1 AND NOT (p_confidence <=> v_confidence) THEN
    UPDATE opportunity
       SET weighted_value = ROUND(expected_value * fx_rate * p_confidence / 100, 2)
     WHERE stage_code = v_code AND confidence_override_pct IS NULL;
  END IF;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write('STAGE', p_id, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
  END IF;
  COMMIT;
  CALL sp_stage_list(v_entity);
END $$

-- -----------------------------------------------------------------------------
-- Settings (16.1: thresholds live here, never in code)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_setting_list $$
CREATE PROCEDURE sp_setting_list(IN p_module VARCHAR(40))
  SQL SECURITY DEFINER
BEGIN
  SELECT s.setting_key AS `key`, s.setting_value AS value, s.value_type AS valueType,
         s.min_value AS `minValue`, s.max_value AS `maxValue`, s.allowed_values AS allowedValues,
         s.module, s.description, s.is_editable AS isEditable,
         s.updated_at AS updatedAt, u.full_name AS updatedByName
    FROM setting s
    LEFT JOIN `user` u ON u.id = s.updated_by
   WHERE p_module IS NULL OR s.module = p_module
   ORDER BY s.module, s.setting_key;
END $$

DROP PROCEDURE IF EXISTS sp_setting_values $$
CREATE PROCEDURE sp_setting_values(IN p_keys JSON)
  SQL SECURITY DEFINER
  COMMENT 'Values of specific keys (used by the API for runtime policy, e.g. idle timeout)'
BEGIN
  SELECT s.setting_key AS `key`, s.setting_value AS value, s.value_type AS valueType
    FROM setting s
    JOIN JSON_TABLE(p_keys, '$[*]' COLUMNS (k VARCHAR(80) PATH '$')) jt ON jt.k = s.setting_key;
END $$

DROP PROCEDURE IF EXISTS sp_setting_update $$
CREATE PROCEDURE sp_setting_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_items         JSON
)
  SQL SECURITY DEFINER
  COMMENT 'Atomic batch update: [{"key": "...", "value": "..."}]'
BEGIN
  DECLARE v_n        INT DEFAULT 0;
  DECLARE i          INT DEFAULT 0;
  DECLARE j          INT DEFAULT 0;
  DECLARE v_key      VARCHAR(80);
  DECLARE v_value    VARCHAR(1000);
  DECLARE v_old      VARCHAR(1000);
  DECLARE v_type     VARCHAR(10);
  DECLARE v_min      DECIMAL(16,2);
  DECLARE v_max      DECIMAL(16,2);
  DECLARE v_allowed  VARCHAR(500);
  DECLARE v_editable TINYINT;
  DECLARE v_found    TINYINT;
  DECLARE v_item     VARCHAR(100);
  DECLARE v_changed  JSON DEFAULT JSON_ARRAY();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_items IS NULL OR JSON_TYPE(p_items) <> 'ARRAY' OR JSON_LENGTH(p_items) = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Send at least one setting.', 'items');
  END IF;
  SET v_n = JSON_LENGTH(p_items);

  START TRANSACTION;
  WHILE i < v_n DO
    SET v_key   = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', i, '].key')));
    SET v_value = TRIM(JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', i, '].value'))));
    SET v_found = 0;

    SELECT 1, setting_value, value_type, min_value, max_value, allowed_values, is_editable
      INTO v_found, v_old, v_type, v_min, v_max, v_allowed, v_editable
      FROM setting WHERE setting_key = v_key FOR UPDATE;

    IF v_found = 0 THEN
      CALL spi_raise('VALIDATION_FAILED', CONCAT('Unknown setting ', IFNULL(v_key, '')), 'key');
    END IF;
    IF v_editable = 0 THEN
      CALL spi_raise('BUSINESS_RULE_VIOLATION', CONCAT('Setting ', v_key, ' cannot be edited.'), v_key);
    END IF;
    IF v_value IS NULL OR v_value = '' THEN
      CALL spi_raise('VALIDATION_FAILED', 'A value is required.', v_key);
    END IF;

    CASE v_type
      WHEN 'INT' THEN
        IF NOT REGEXP_LIKE(v_value, '^-?[0-9]{1,12}$') THEN
          CALL spi_raise('VALIDATION_FAILED', 'Enter a whole number.', v_key);
        END IF;
      WHEN 'DECIMAL' THEN
        IF NOT REGEXP_LIKE(v_value, '^-?[0-9]{1,14}(\\.[0-9]{1,2})?$') THEN
          CALL spi_raise('VALIDATION_FAILED', 'Enter a number with at most 2 decimals.', v_key);
        END IF;
      WHEN 'BOOL' THEN
        IF v_value NOT IN ('true', 'false') THEN
          CALL spi_raise('VALIDATION_FAILED', 'Enter true or false.', v_key);
        END IF;
      WHEN 'TIME' THEN
        IF NOT REGEXP_LIKE(v_value, '^([01][0-9]|2[0-3]):[0-5][0-9]$') THEN
          CALL spi_raise('VALIDATION_FAILED', 'Enter a time as HH:MM (24 h).', v_key);
        END IF;
      WHEN 'DAY' THEN
        SET v_value = UPPER(v_value);
        IF FIND_IN_SET(v_value, v_allowed) = 0 THEN
          CALL spi_raise('VALIDATION_FAILED', 'Choose a day of the week.', v_key);
        END IF;
      WHEN 'LIST' THEN
        SET v_value = LOWER(REPLACE(v_value, ' ', ''));
        SET j = 1;
        WHILE j <= 1 + CHAR_LENGTH(v_value) - CHAR_LENGTH(REPLACE(v_value, ',', '')) DO
          SET v_item = SUBSTRING_INDEX(SUBSTRING_INDEX(v_value, ',', j), ',', -1);
          IF v_item = '' OR (v_allowed IS NOT NULL AND FIND_IN_SET(v_item, v_allowed) = 0) THEN
            CALL spi_raise('VALIDATION_FAILED', CONCAT('Value not allowed: ', v_item), v_key);
          END IF;
          SET j = j + 1;
        END WHILE;
      ELSE
        BEGIN END;
    END CASE;

    IF v_type IN ('INT', 'DECIMAL') AND
       ((v_min IS NOT NULL AND CAST(v_value AS DECIMAL(16,2)) < v_min) OR
        (v_max IS NOT NULL AND CAST(v_value AS DECIMAL(16,2)) > v_max)) THEN
      CALL spi_raise('VALIDATION_FAILED',
                     CONCAT('Enter a value from ', TRIM(TRAILING '.00' FROM v_min), ' to ', TRIM(TRAILING '.00' FROM v_max), '.'),
                     v_key);
    END IF;

    IF NOT (CAST(v_old AS BINARY) <=> CAST(v_value AS BINARY)) THEN
      UPDATE setting
         SET setting_value = v_value, updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
       WHERE setting_key = v_key;
      CALL spi_audit_write('SETTING', v_key, 'UPDATE',
                           JSON_OBJECT('value', JSON_OBJECT('from', v_old, 'to', v_value)),
                           NULL, p_actor_user_id, p_ip, p_request_id);
      SET v_changed = JSON_ARRAY_APPEND(v_changed, '$', v_key);
    END IF;

    SET i = i + 1;
  END WHILE;

  IF JSON_LENGTH(v_changed) > 0 THEN
    CALL spi_security_event('SETTINGS_CHANGED', p_actor_user_id, NULL, p_ip, NULL, p_request_id,
                            JSON_OBJECT('keys', v_changed));
  END IF;
  COMMIT;
  CALL sp_setting_list(NULL);
END $$

-- -----------------------------------------------------------------------------
-- Email templates (subject/body with {{placeholders}}; HTML sanitised by the API)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_email_template_list $$
CREATE PROCEDURE sp_email_template_list()
  SQL SECURITY DEFINER
BEGIN
  SELECT t.code, t.name, t.subject, t.placeholders, t.is_active AS isActive,
         t.updated_at AS updatedAt, u.full_name AS updatedByName
    FROM email_template t
    LEFT JOIN `user` u ON u.id = t.updated_by
   ORDER BY t.name;
END $$

DROP PROCEDURE IF EXISTS sp_email_template_get $$
CREATE PROCEDURE sp_email_template_get(IN p_code VARCHAR(60))
  SQL SECURITY DEFINER
BEGIN
  SELECT t.code, t.name, t.subject, t.body_html AS bodyHtml, t.placeholders, t.is_active AS isActive,
         t.row_version AS rowVersion, t.updated_at AS updatedAt, u.full_name AS updatedByName
    FROM email_template t
    LEFT JOIN `user` u ON u.id = t.updated_by
   WHERE t.code = p_code;
END $$

-- Internal: every {{token}} in p_text must be one of the template's placeholders
DROP PROCEDURE IF EXISTS spi_check_placeholders $$
CREATE PROCEDURE spi_check_placeholders(IN p_text MEDIUMTEXT, IN p_allowed JSON, IN p_field VARCHAR(60))
  SQL SECURITY DEFINER
BEGIN
  DECLARE i       INT DEFAULT 1;
  DECLARE v_token VARCHAR(200);
  DECLARE v_name  VARCHAR(200);

  token_loop: LOOP
    SET v_token = REGEXP_SUBSTR(p_text, '\\{\\{[^}]{0,190}\\}\\}', 1, i);
    IF v_token IS NULL THEN
      LEAVE token_loop;
    END IF;
    SET v_name = TRIM(SUBSTRING(v_token, 3, CHAR_LENGTH(v_token) - 4));
    IF NOT REGEXP_LIKE(v_name, '^[A-Za-z][A-Za-z0-9]*$', 'c')
       OR NOT JSON_CONTAINS(p_allowed, JSON_QUOTE(v_name)) THEN
      CALL spi_raise('VALIDATION_FAILED', CONCAT('Unknown placeholder ', LEFT(v_token, 60)), p_field);
    END IF;
    SET i = i + 1;
  END LOOP;
END $$

DROP PROCEDURE IF EXISTS sp_email_template_update $$
CREATE PROCEDURE sp_email_template_update(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(64),
  IN p_ip            VARCHAR(45),
  IN p_code          VARCHAR(60),
  IN p_row_version   INT UNSIGNED,
  IN p_subject       VARCHAR(255),
  IN p_body_html     MEDIUMTEXT,
  IN p_is_active     TINYINT
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_found        BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_subject      VARCHAR(255);
  DECLARE v_body         MEDIUMTEXT;
  DECLARE v_active       TINYINT;
  DECLARE v_row_version  INT UNSIGNED;
  DECLARE v_placeholders JSON;
  DECLARE v_changes      JSON DEFAULT JSON_OBJECT();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
  SELECT id, subject, body_html, is_active, row_version, placeholders
    INTO v_found, v_subject, v_body, v_active, v_row_version, v_placeholders
    FROM email_template WHERE code = p_code FOR UPDATE;
  IF v_found IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Email template not found.', 'code');
  END IF;
  IF v_row_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'This template was changed by someone else. Reload and try again.', 'rowVersion');
  END IF;
  IF IFNULL(p_is_active, 1) = 0 AND p_code IN ('USER_INVITATION', 'PASSWORD_RESET', 'PASSWORD_RESET_CONFIRMATION',
                                               'PASSWORD_CHANGED', 'ACCOUNT_LOCKED') THEN
    CALL spi_raise('BUSINESS_RULE_VIOLATION', 'Sign-in emails cannot be switched off.', 'isActive');
  END IF;
  IF TRIM(IFNULL(p_subject, '')) = '' THEN
    CALL spi_raise('VALIDATION_FAILED', 'A subject is required.', 'subject');
  END IF;
  IF TRIM(IFNULL(p_body_html, '')) = '' THEN
    CALL spi_raise('VALIDATION_FAILED', 'A body is required.', 'bodyHtml');
  END IF;

  CALL spi_check_placeholders(p_subject, v_placeholders, 'subject');
  CALL spi_check_placeholders(p_body_html, v_placeholders, 'bodyHtml');

  CALL spi_diff(v_changes, 'subject',  v_subject, TRIM(p_subject));
  CALL spi_diff(v_changes, 'bodyHtml', v_body,    p_body_html);
  CALL spi_diff(v_changes, 'isActive', v_active,  IFNULL(p_is_active, 1));

  UPDATE email_template
     SET subject = TRIM(p_subject), body_html = p_body_html, is_active = IFNULL(p_is_active, 1),
         row_version = row_version + 1, updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
   WHERE code = p_code;

  IF JSON_LENGTH(v_changes) > 0 THEN
    CALL spi_audit_write('EMAIL_TEMPLATE', p_code, 'UPDATE', v_changes, NULL, p_actor_user_id, p_ip, p_request_id);
  END IF;
  COMMIT;
  CALL sp_email_template_get(p_code);
END $$

DELIMITER ;

INSERT INTO schema_version (version, description, script_name)
VALUES ('V006', 'Masters, settings and email template procedures', 'V006__sp_masters.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
