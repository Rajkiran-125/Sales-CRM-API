-- =============================================================================
-- V042  Sales CRM - Partner onboarding: missing fields and rules        (2026-10-19)
--
--   Review of the Partner Master against UM 7.1 / tech doc 12.7, 14.7, BR-PT-01..07:
--
--   columns                     partner.employee_count (employee strength, section 1),
--                               partner.parent_partner_id (partner hierarchy: the partner one
--                               level up, e.g. the distributor of a reseller, section 2),
--                               partner.regions (JSON array of region codes, section 3).
--                               Added only when missing, so the script stays re-runnable.
--   spi_partner_completeness    Re-issue of V030: + employee strength, regions.
--   sp_partner_save_type        Re-issue of V030: + parent partner (no loop, active partner).
--   data                        financial / tech onboarding / GTM plan statuses become codes
--                               (the UI now picks them from a list); unknown old text is kept.
--   spi_partner_check_doc       A linked document must be an active document of this partner
--                               with the expected type (AGREEMENT, GTM_PLAN).
--   sp_partner_create           Re-issue of V030: + email, phone, currency; a partner with the
--                               same name / GST / website is refused (DUPLICATE, 409) unless
--                               the user confirms (BR-PT-02, 14.7 "409 duplicate unless confirmed").
--   sp_partner_edit_get         Re-issue of V030: + linked document ids / titles, customer codes.
--   sp_partner_save_entity      Re-issue of V030: address required (UM 7.1 [*]); a signed
--                               agreement needs its valid-till date AND its document (BR-PT-07).
--   sp_partner_save_industry    Re-issue of V030: at least one industry (UM 7.1 [*]).
--   sp_partner_save_engagement  Re-issue of V030: + GTM plan document.
--   sp_partner_get              Re-issue of V009: + linked documents; customer codes with ids.
--   sp_partner_customer_code_save / _delete
--                               "Partner code at customers" (UM 7.1): one code per customer.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V041.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

-- ---------------------------------------------------------------------------
-- data: free-text statuses that match a list value become its code
-- ---------------------------------------------------------------------------
UPDATE partner SET financial_status = UPPER(TRIM(financial_status))
 WHERE UPPER(TRIM(financial_status)) IN ('STRONG', 'STABLE', 'WEAK');
UPDATE partner SET tech_onboarding_status = REPLACE(UPPER(TRIM(tech_onboarding_status)), ' ', '_')
 WHERE REPLACE(UPPER(TRIM(tech_onboarding_status)), ' ', '_') IN ('NOT_STARTED', 'IN_PROGRESS', 'TRAINED');
UPDATE partner SET gtm_plan_status = REPLACE(UPPER(TRIM(gtm_plan_status)), ' ', '_')
 WHERE REPLACE(UPPER(TRIM(gtm_plan_status)), ' ', '_') IN ('NOT_STARTED', 'IN_DISCUSSION', 'AGREED');

DELIMITER $$

-- ---------------------------------------------------------------------------
-- columns: employee strength, parent partner (hierarchy), regions; each only when missing
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS tmp_v042_partner_columns $$
CREATE PROCEDURE tmp_v042_partner_columns()
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE()
                   AND table_name = 'partner' AND column_name = 'employee_count') THEN
    ALTER TABLE partner ADD COLUMN employee_count INT UNSIGNED NULL COMMENT 'Employee strength'
      AFTER financial_status;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE()
                   AND table_name = 'partner' AND column_name = 'parent_partner_id') THEN
    ALTER TABLE partner
      ADD COLUMN parent_partner_id BIGINT UNSIGNED NULL COMMENT 'Hierarchy: the partner one level up'
        AFTER tier,
      ADD KEY ix_partner_parent (parent_partner_id),
      ADD CONSTRAINT fk_partner_parent FOREIGN KEY (parent_partner_id) REFERENCES partner (id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE()
                   AND table_name = 'partner' AND column_name = 'regions') THEN
    ALTER TABLE partner ADD COLUMN regions JSON NULL COMMENT 'Region codes the partner covers'
      AFTER sales_coverage;
  END IF;
END $$
CALL tmp_v042_partner_columns() $$
DROP PROCEDURE tmp_v042_partner_columns $$

-- ---------------------------------------------------------------------------
-- spi_partner_completeness: share of filled items per section x the section weight (V030 +
-- employee strength in section 1, regions in section 3)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_partner_completeness $$
CREATE PROCEDURE spi_partner_completeness(IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  -- shortcut: OD-38 default weights in code; move to settings if the partner managers tune them
  UPDATE partner p
     SET p.profile_completeness_pct = ROUND(
           30 * ((p.address IS NOT NULL) + (p.city IS NOT NULL) + (p.website IS NOT NULL)
                 + (p.email IS NOT NULL) + (p.phone IS NOT NULL) + (p.registration_no IS NOT NULL)
                 + (p.gst_no IS NOT NULL) + (p.pan_no IS NOT NULL) + (p.annual_revenue IS NOT NULL)
                 + (p.credit_rating IS NOT NULL) + (p.financial_status IS NOT NULL)
                 + (p.employee_count IS NOT NULL)
                 + (p.agreement_status <> 'NONE') + 2) / 15          -- legal name + country always set
         + 10 * ((EXISTS (SELECT 1 FROM partner_type_map m WHERE m.partner_id = p.id))
                 + (p.tier IS NOT NULL)
                 + (EXISTS (SELECT 1 FROM partner_certification c WHERE c.partner_id = p.id))) / 3
         + 25 * ((EXISTS (SELECT 1 FROM partner_industry_map m WHERE m.partner_id = p.id))
                 + (p.top_customers IS NOT NULL) + (p.our_share_pct IS NOT NULL) + (p.sme_count IS NOT NULL)
                 + (p.can_run_poc IS NOT NULL) + (p.certified_engineers IS NOT NULL)
                 + (p.sales_force_size IS NOT NULL) + (p.uses_crm IS NOT NULL)
                 + (p.sales_coverage IS NOT NULL) + (p.influencer_connect IS NOT NULL)
                 + (p.dmu_impact IS NOT NULL) + (IFNULL(JSON_LENGTH(p.regions), 0) > 0)) / 12
         + 35 * ((p.top_management IS NOT NULL) + (p.partner_dmu IS NOT NULL) + 1  -- owner always set
                 + (p.backup_owner_user_id IS NOT NULL) + (p.tech_onboarding_status IS NOT NULL)
                 + (p.gtm_plan_status IS NOT NULL) + (p.poc_investment_count IS NOT NULL)
                 + (p.last_engagement_on IS NOT NULL) + (p.next_engagement_on IS NOT NULL)
                 + (p.next_engagement_plan IS NOT NULL)
                 + (EXISTS (SELECT 1 FROM contact c WHERE c.partner_id = p.id AND c.is_active = 1))) / 11,
         2)
   WHERE p.id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- spi_partner_check_doc: p_doc_id (when set) is an active p_type document of the partner
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_partner_check_doc $$
CREATE PROCEDURE spi_partner_check_doc(
  IN p_partner_id BIGINT UNSIGNED,
  IN p_doc_id     BIGINT UNSIGNED,
  IN p_type_code  VARCHAR(30),
  IN p_field      VARCHAR(64)
)
  SQL SECURITY DEFINER
BEGIN
  IF p_doc_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM document d JOIN document_type dt ON dt.id = d.document_type_id
        WHERE d.id = p_doc_id AND d.entity_type = 'PARTNER' AND d.entity_id = p_partner_id
          AND d.is_active = 1 AND d.deleted_at IS NULL AND dt.code = p_type_code) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Upload the document to this partner first.', p_field);
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_create (BR-PT-01, BR-PT-02)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_create $$
CREATE PROCEDURE sp_partner_create(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_legal_name     VARCHAR(250),
  IN p_short_name     VARCHAR(150),
  IN p_country        VARCHAR(80),
  IN p_type_ids       JSON,            -- array of partner_type ids, at least one
  IN p_owner_user_id  BIGINT UNSIGNED,
  IN p_backup_user_id BIGINT UNSIGNED,
  IN p_city           VARCHAR(100),
  IN p_website        VARCHAR(255),
  IN p_gst_no         VARCHAR(15),
  IN p_email          VARCHAR(150),
  IN p_phone          VARCHAR(20),
  IN p_currency       CHAR(3),
  IN p_confirm_dup    TINYINT(1),      -- 1 = the user saw the matches and creates anyway
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_no    VARCHAR(30);
  DECLARE v_id    BIGINT UNSIGNED;
  DECLARE v_types INT;
  DECLARE v_name  VARCHAR(250) DEFAULT LOWER(TRIM(p_legal_name));
  DECLARE v_short VARCHAR(150) DEFAULT NULLIF(LOWER(TRIM(IFNULL(p_short_name, ''))), '');
  DECLARE v_gst   VARCHAR(15)  DEFAULT NULLIF(UPPER(TRIM(IFNULL(p_gst_no, ''))), '');
  DECLARE v_site  VARCHAR(255) DEFAULT
    NULLIF(REGEXP_REPLACE(LOWER(TRIM(IFNULL(p_website, ''))), '^(https?://)?(www\\.)?|/+$', ''), '');
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT COUNT(*) INTO v_types
    FROM JSON_TABLE(p_type_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j
    JOIN partner_type t ON t.id = j.id AND t.is_active = 1;
  IF v_types = 0 OR v_types <> JSON_LENGTH(p_type_ids) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose at least one active partner type.', 'typeIds');
  END IF;
  CALL spi_partner_check_people(p_actor_user_id, p_owner_user_id, p_backup_user_id, p_allow_any);
  -- same matching as sp_partner_duplicates (V030)
  IF IFNULL(p_confirm_dup, 0) = 0 AND EXISTS (
       SELECT 1 FROM partner p
        WHERE p.is_active = 1 AND p.deleted_at IS NULL
          AND (LOWER(p.legal_name) IN (v_name, IFNULL(v_short, v_name))
               OR LOWER(IFNULL(p.short_name, '')) IN (v_name, IFNULL(v_short, v_name))
               OR (v_gst IS NOT NULL AND p.gst_no = v_gst)
               OR (v_site IS NOT NULL
                   AND REGEXP_REPLACE(LOWER(TRIM(IFNULL(p.website, ''))), '^(https?://)?(www\\.)?|/+$', '') = v_site))) THEN
    CALL spi_raise('DUPLICATE', 'A partner with the same name, GST number or website is already in the CRM. Check it, or confirm to create a new one.', 'confirmDuplicate');
  END IF;

  START TRANSACTION;
  CALL spi_next_number('PTR', 0, v_no);
  INSERT INTO partner (partner_no, legal_name, short_name, country, city, website, gst_no, email, phone,
                       currency, relationship_owner_user_id, backup_owner_user_id, created_at, created_by)
  VALUES (v_no, p_legal_name, p_short_name, p_country, p_city, p_website, UPPER(p_gst_no), p_email, p_phone,
          IFNULL(p_currency, 'INR'), p_owner_user_id, p_backup_user_id, UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();
  INSERT INTO partner_type_map (partner_id, partner_type_id)
  SELECT v_id, j.id FROM JSON_TABLE(p_type_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j;
  CALL spi_partner_completeness(v_id);
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('partner', v_id, 'PARTNER_CREATE',
          JSON_OBJECT('legalName', p_legal_name, 'ownerUserId', p_owner_user_id,
                      'duplicateConfirmed', IFNULL(p_confirm_dup, 0) = 1),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id, v_no AS partnerNo;
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_edit_get: editable values with ids; then type ids, industry ids, certifications,
-- contacts, customer codes
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_edit_get $$
CREATE PROCEDURE sp_partner_edit_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;

  CALL spi_visible_partners(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_ptr WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Partner not found.', 'id');
  END IF;

  SELECT p.id, p.row_version AS rowVersion,
         p.legal_name AS legalName, p.short_name AS shortName, p.country, p.address, p.city,
         p.website, p.email, p.phone, p.registration_no AS registrationNo, p.gst_no AS gstNo,
         p.pan_no AS panNo, p.currency, CAST(p.annual_revenue AS DECIMAL(18,2)) AS annualRevenue,
         p.revenue_fy AS revenueFy, p.credit_rating AS creditRating,
         p.financial_status AS financialStatus, p.employee_count AS employeeCount,
         p.agreement_status AS agreementStatus,
         p.agreement_valid_till AS agreementValidTill,
         ad.id AS agreementDocumentId, ad.title AS agreementDocumentTitle,
         p.tier, p.parent_partner_id AS parentPartnerId,
         COALESCE(pp.short_name, pp.legal_name) AS parentPartnerName,
         p.top_customers AS topCustomers, p.our_share_pct AS ourSharePct, p.sme_count AS smeCount,
         p.can_run_poc AS canRunPoc, p.certified_engineers AS certifiedEngineers,
         p.sales_force_size AS salesForceSize, p.uses_crm AS usesCrm,
         p.sales_coverage AS salesCoverage, p.regions, p.influencer_connect AS influencerConnect,
         p.dmu_impact AS dmuImpact, p.dmu_impact_notes AS dmuImpactNotes,
         p.top_management AS topManagement, p.partner_dmu AS partnerDmu,
         p.relationship_owner_user_id AS relationshipOwnerUserId, u.full_name AS ownerName,
         p.backup_owner_user_id AS backupOwnerUserId, b.full_name AS backupOwnerName,
         p.tech_onboarding_status AS techOnboardingStatus, p.gtm_plan_status AS gtmPlanStatus,
         gd.id AS gtmDocumentId, gd.title AS gtmDocumentTitle,
         p.poc_investment_count AS pocInvestmentCount,
         CAST(p.poc_investment_value AS DECIMAL(18,2)) AS pocInvestmentValue,
         p.customer_feedback_rating AS customerFeedbackRating,
         p.customer_feedback_notes AS customerFeedbackNotes, p.publications,
         p.profile_completeness_pct AS completenessPct
    FROM partner p
    JOIN `user` u ON u.id = p.relationship_owner_user_id
    LEFT JOIN `user` b ON b.id = p.backup_owner_user_id
    LEFT JOIN partner pp ON pp.id = p.parent_partner_id
    LEFT JOIN document ad ON ad.id = p.agreement_document_id AND ad.is_active = 1 AND ad.deleted_at IS NULL
    LEFT JOIN document gd ON gd.id = p.gtm_document_id AND gd.is_active = 1 AND gd.deleted_at IS NULL
   WHERE p.id = p_id;

  SELECT partner_type_id AS id FROM partner_type_map WHERE partner_id = p_id ORDER BY partner_type_id;
  SELECT industry_id AS id FROM partner_industry_map WHERE partner_id = p_id ORDER BY industry_id;
  SELECT certification_type_id AS certificationTypeId, other_name AS otherName
    FROM partner_certification WHERE partner_id = p_id ORDER BY id;
  -- every editable contact field: PATCH /contacts/{id} replaces them all
  SELECT c.id, c.name, c.designation, c.department, c.email, c.phone, c.seniority,
         c.influence_level AS influenceLevel, c.stand, c.intel_notes AS intelNotes,
         c.spoc_type AS spocType
    FROM contact c WHERE c.partner_id = p_id AND c.is_active = 1 ORDER BY c.name;
  SELECT cc.id, cc.account_id AS accountId, a.name AS accountName, cc.customer_name AS customerName, cc.code
    FROM partner_customer_code cc LEFT JOIN account a ON a.id = cc.account_id
   WHERE cc.partner_id = p_id ORDER BY COALESCE(a.name, cc.customer_name);
END $$

-- ---------------------------------------------------------------------------
-- section 1: entity. Address required (UM 7.1); BR-PT-07: a signed agreement needs its
-- valid-till date and its document
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_save_entity $$
CREATE PROCEDURE sp_partner_save_entity(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_id             BIGINT UNSIGNED,
  IN p_row_version    INT UNSIGNED,
  IN p_legal_name     VARCHAR(250),
  IN p_short_name     VARCHAR(150),
  IN p_country        VARCHAR(80),
  IN p_address        VARCHAR(500),
  IN p_city           VARCHAR(100),
  IN p_website        VARCHAR(255),
  IN p_email          VARCHAR(150),
  IN p_phone          VARCHAR(20),
  IN p_registration   VARCHAR(50),
  IN p_gst_no         VARCHAR(15),
  IN p_pan_no         VARCHAR(10),
  IN p_currency       CHAR(3),
  IN p_annual_revenue DECIMAL(16,2),
  IN p_revenue_fy     VARCHAR(10),
  IN p_credit_rating  VARCHAR(40),
  IN p_financial      VARCHAR(20),
  IN p_employee_count INT UNSIGNED,
  IN p_agreement      VARCHAR(15),
  IN p_valid_till     DATE,
  IN p_agreement_doc  BIGINT UNSIGNED,
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_edit_check(p_actor_user_id, p_id, p_row_version, p_allow_any);
  IF NULLIF(TRIM(IFNULL(p_address, '')), '') IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Enter the address.', 'address');
  END IF;
  IF p_agreement = 'SIGNED' AND p_valid_till IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'A signed agreement needs its valid-till date.', 'agreementValidTill');
  END IF;
  IF p_agreement = 'SIGNED' AND p_agreement_doc IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'A signed agreement needs its document.', 'agreementDocumentId');
  END IF;
  CALL spi_partner_check_doc(p_id, p_agreement_doc, 'AGREEMENT', 'agreementDocumentId');

  START TRANSACTION;
  UPDATE partner
     SET legal_name = p_legal_name, short_name = p_short_name, country = p_country,
         address = p_address, city = p_city, website = p_website, email = p_email, phone = p_phone,
         registration_no = p_registration, gst_no = UPPER(p_gst_no), pan_no = UPPER(p_pan_no),
         currency = IFNULL(p_currency, 'INR'), annual_revenue = p_annual_revenue,
         revenue_fy = p_revenue_fy, credit_rating = p_credit_rating, financial_status = p_financial,
         employee_count = p_employee_count,
         agreement_status = p_agreement, agreement_valid_till = p_valid_till,
         agreement_document_id = p_agreement_doc
   WHERE id = p_id;
  CALL spi_partner_saved(p_actor_user_id, p_request_id, p_ip, p_id, 'ENTITY');
  COMMIT;
  SELECT id, row_version AS rowVersion, profile_completeness_pct AS completenessPct FROM partner WHERE id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- section 2: type (BR-PT-03 several types; OD-39 certifications: master list + "other");
-- + the parent partner (hierarchy): an active partner, not this one, and no loop
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_save_type $$
CREATE PROCEDURE sp_partner_save_type(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_row_version   INT UNSIGNED,
  IN p_type_ids      JSON,             -- at least one
  IN p_tier          VARCHAR(15),
  IN p_parent_id     BIGINT UNSIGNED,  -- the partner one level up, or NULL
  IN p_cert_type_ids JSON,             -- certification_type ids
  IN p_cert_others   JSON,             -- free-text names
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_types INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_edit_check(p_actor_user_id, p_id, p_row_version, p_allow_any);
  SELECT COUNT(*) INTO v_types
    FROM JSON_TABLE(p_type_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j
    JOIN partner_type t ON t.id = j.id AND t.is_active = 1;
  IF v_types = 0 OR v_types <> JSON_LENGTH(p_type_ids) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose at least one active partner type.', 'typeIds');
  END IF;
  IF (SELECT COUNT(*) FROM JSON_TABLE(p_cert_type_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j
        JOIN certification_type c ON c.id = j.id) <> JSON_LENGTH(p_cert_type_ids) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown certification.', 'certificationTypeIds');
  END IF;
  IF p_parent_id IS NOT NULL THEN
    IF p_parent_id = p_id THEN
      CALL spi_raise('VALIDATION_FAILED', 'A partner cannot be its own parent.', 'parentPartnerId');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM partner WHERE id = p_parent_id AND is_active = 1 AND deleted_at IS NULL) THEN
      CALL spi_raise('VALIDATION_FAILED', 'Choose an active partner.', 'parentPartnerId');
    END IF;
    -- the chosen parent must not sit below this partner already
    IF EXISTS (WITH RECURSIVE up (id, parent_id) AS (
                 SELECT id, parent_partner_id FROM partner WHERE id = p_parent_id
                 UNION ALL
                 SELECT p.id, p.parent_partner_id FROM partner p JOIN up ON p.id = up.parent_id)
               SELECT 1 FROM up WHERE id = p_id) THEN
      CALL spi_raise('VALIDATION_FAILED', 'That partner is already below this one in the hierarchy.', 'parentPartnerId');
    END IF;
  END IF;

  START TRANSACTION;
  UPDATE partner SET tier = p_tier, parent_partner_id = p_parent_id WHERE id = p_id;
  DELETE FROM partner_type_map WHERE partner_id = p_id;
  INSERT INTO partner_type_map (partner_id, partner_type_id)
  SELECT p_id, j.id FROM JSON_TABLE(p_type_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j;
  DELETE FROM partner_certification WHERE partner_id = p_id;
  INSERT INTO partner_certification (partner_id, certification_type_id, created_by)
  SELECT p_id, j.id, p_actor_user_id
    FROM JSON_TABLE(p_cert_type_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j;
  INSERT INTO partner_certification (partner_id, other_name, created_by)
  SELECT p_id, TRIM(j.name), p_actor_user_id
    FROM JSON_TABLE(p_cert_others, '$[*]' COLUMNS (name VARCHAR(150) PATH '$')) j
   WHERE TRIM(IFNULL(j.name, '')) <> '';
  CALL spi_partner_saved(p_actor_user_id, p_request_id, p_ip, p_id, 'TYPE');
  COMMIT;
  SELECT id, row_version AS rowVersion, profile_completeness_pct AS completenessPct FROM partner WHERE id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- section 3: industry & expertise; at least one industry (UM 7.1); + regions
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_save_industry $$
CREATE PROCEDURE sp_partner_save_industry(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_row_version   INT UNSIGNED,
  IN p_industry_ids  JSON,
  IN p_top_customers VARCHAR(1000),
  IN p_share_pct     DECIMAL(5,2),
  IN p_sme_count     INT UNSIGNED,
  IN p_can_run_poc   TINYINT(1),
  IN p_cert_eng      INT UNSIGNED,
  IN p_sales_force   INT UNSIGNED,
  IN p_uses_crm      TINYINT(1),
  IN p_coverage      VARCHAR(255),
  IN p_regions       JSON,             -- region codes; empty = none
  IN p_influencer    VARCHAR(1000),
  IN p_dmu_impact    VARCHAR(10),
  IN p_dmu_notes     VARCHAR(1000),
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_edit_check(p_actor_user_id, p_id, p_row_version, p_allow_any);
  IF IFNULL(JSON_LENGTH(p_industry_ids), 0) = 0 THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose at least one industry.', 'industryIds');
  END IF;
  IF (SELECT COUNT(*) FROM JSON_TABLE(p_industry_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j
        JOIN industry i ON i.id = j.id) <> JSON_LENGTH(p_industry_ids) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown industry.', 'industryIds');
  END IF;

  START TRANSACTION;
  UPDATE partner
     SET top_customers = p_top_customers, our_share_pct = p_share_pct, sme_count = p_sme_count,
         can_run_poc = p_can_run_poc, certified_engineers = p_cert_eng,
         sales_force_size = p_sales_force, uses_crm = p_uses_crm, sales_coverage = p_coverage,
         regions = IF(IFNULL(JSON_LENGTH(p_regions), 0) = 0, NULL, p_regions),
         influencer_connect = p_influencer, dmu_impact = p_dmu_impact, dmu_impact_notes = p_dmu_notes
   WHERE id = p_id;
  DELETE FROM partner_industry_map WHERE partner_id = p_id;
  INSERT INTO partner_industry_map (partner_id, industry_id)
  SELECT p_id, j.id FROM JSON_TABLE(p_industry_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j;
  CALL spi_partner_saved(p_actor_user_id, p_request_id, p_ip, p_id, 'INDUSTRY');
  COMMIT;
  SELECT id, row_version AS rowVersion, profile_completeness_pct AS completenessPct FROM partner WHERE id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- section 4: engagement structure, + the GTM plan document
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_save_engagement $$
CREATE PROCEDURE sp_partner_save_engagement(
  IN p_actor_user_id  BIGINT UNSIGNED,
  IN p_request_id     VARCHAR(36),
  IN p_ip             VARCHAR(45),
  IN p_id             BIGINT UNSIGNED,
  IN p_row_version    INT UNSIGNED,
  IN p_top_management VARCHAR(1000),
  IN p_partner_dmu    VARCHAR(1000),
  IN p_owner_user_id  BIGINT UNSIGNED,
  IN p_backup_user_id BIGINT UNSIGNED,
  IN p_tech_status    VARCHAR(30),
  IN p_gtm_status     VARCHAR(30),
  IN p_gtm_doc        BIGINT UNSIGNED,
  IN p_poc_count      INT UNSIGNED,
  IN p_poc_value      DECIMAL(16,2),
  IN p_feedback       TINYINT UNSIGNED,
  IN p_feedback_notes VARCHAR(1000),
  IN p_publications   TEXT,
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_owner BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_edit_check(p_actor_user_id, p_id, p_row_version, p_allow_any);
  SELECT relationship_owner_user_id INTO v_owner FROM partner WHERE id = p_id;
  SET p_owner_user_id = IFNULL(p_owner_user_id, v_owner);
  -- keeping the current owner is always allowed, even outside the actor's tree
  CALL spi_partner_check_people(p_actor_user_id, p_owner_user_id, p_backup_user_id,
                                IF(p_owner_user_id = v_owner, 1, p_allow_any));
  CALL spi_partner_check_doc(p_id, p_gtm_doc, 'GTM_PLAN', 'gtmDocumentId');

  START TRANSACTION;
  UPDATE partner
     SET top_management = p_top_management, partner_dmu = p_partner_dmu,
         relationship_owner_user_id = p_owner_user_id, backup_owner_user_id = p_backup_user_id,
         tech_onboarding_status = p_tech_status, gtm_plan_status = p_gtm_status,
         gtm_document_id = p_gtm_doc,
         poc_investment_count = p_poc_count, poc_investment_value = p_poc_value,
         customer_feedback_rating = p_feedback, customer_feedback_notes = p_feedback_notes,
         publications = p_publications
   WHERE id = p_id;
  IF p_owner_user_id <> v_owner THEN
    INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
    VALUES ('partner', p_id, 'PARTNER_OWNER_CHANGE',
            JSON_OBJECT('relationshipOwnerUserId', JSON_OBJECT('from', v_owner, 'to', p_owner_user_id)),
            p_actor_user_id, p_ip, p_request_id);
  END IF;
  CALL spi_partner_saved(p_actor_user_id, p_request_id, p_ip, p_id, 'ENGAGEMENT');
  COMMIT;
  SELECT id, row_version AS rowVersion, profile_completeness_pct AS completenessPct FROM partner WHERE id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_customer_code_save: p_id NULL = new; a known account or a customer name
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_customer_code_save $$
CREATE PROCEDURE sp_partner_customer_code_save(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_id            BIGINT UNSIGNED,
  IN p_account_id    BIGINT UNSIGNED,
  IN p_customer_name VARCHAR(200),
  IN p_code          VARCHAR(60),
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_id   BIGINT UNSIGNED;
  DECLARE v_name VARCHAR(200) DEFAULT NULLIF(TRIM(IFNULL(p_customer_name, '')), '');
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_owner_check(p_actor_user_id, p_partner_id, p_allow_any);
  IF p_account_id IS NULL AND v_name IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose the account or type the customer name.', 'accountId');
  END IF;
  IF p_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM account WHERE id = p_account_id AND is_active = 1) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose an active account.', 'accountId');
  END IF;
  IF p_account_id IS NOT NULL THEN
    SET v_name = NULL;
  END IF;
  IF p_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM partner_customer_code WHERE id = p_id AND partner_id = p_partner_id) THEN
    CALL spi_raise('NOT_FOUND', 'Customer code not found.', 'codeId');
  END IF;
  IF EXISTS (SELECT 1 FROM partner_customer_code
              WHERE partner_id = p_partner_id AND (p_id IS NULL OR id <> p_id)
                AND ((p_account_id IS NOT NULL AND account_id = p_account_id)
                     OR (v_name IS NOT NULL AND LOWER(customer_name) = LOWER(v_name)))) THEN
    CALL spi_raise('VALIDATION_FAILED', 'This customer already has a code for this partner.', 'accountId');
  END IF;

  START TRANSACTION;
  IF p_id IS NULL THEN
    INSERT INTO partner_customer_code (partner_id, account_id, customer_name, code, created_by)
    VALUES (p_partner_id, p_account_id, v_name, TRIM(p_code), p_actor_user_id);
    SET v_id = LAST_INSERT_ID();
  ELSE
    UPDATE partner_customer_code
       SET account_id = p_account_id, customer_name = v_name, code = TRIM(p_code),
           updated_at = UTC_TIMESTAMP(3), updated_by = p_actor_user_id
     WHERE id = p_id;
    SET v_id = p_id;
  END IF;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('partner', p_partner_id, IF(p_id IS NULL, 'PARTNER_CUSTOMER_CODE_ADD', 'PARTNER_CUSTOMER_CODE_UPDATE'),
          JSON_OBJECT('codeId', v_id, 'accountId', p_account_id, 'customerName', v_name, 'code', TRIM(p_code)),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id;
END $$

DROP PROCEDURE IF EXISTS sp_partner_customer_code_delete $$
CREATE PROCEDURE sp_partner_customer_code_delete(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_partner_id    BIGINT UNSIGNED,
  IN p_id            BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_code VARCHAR(60);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_owner_check(p_actor_user_id, p_partner_id, p_allow_any);
  SELECT code INTO v_code FROM partner_customer_code WHERE id = p_id AND partner_id = p_partner_id;
  IF v_code IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Customer code not found.', 'codeId');
  END IF;

  START TRANSACTION;
  DELETE FROM partner_customer_code WHERE id = p_id;
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('partner', p_partner_id, 'PARTNER_CUSTOMER_CODE_REMOVE', JSON_OBJECT('codeId', p_id, 'code', v_code),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;
END $$

-- -----------------------------------------------------------------------------
-- sp_partner_get: the partner workspace (UM 7.1). Re-issue of V009 with the linked
-- agreement / GTM documents and the customer codes with ids. Result sets:
--   partner, types, industries, certifications, customerCodes, contacts,
--   scorecard (this fiscal year), deals (visible ones), engagements, accountMap, activities
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_get $$
CREATE PROCEDURE sp_partner_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Partner workspace, read side (12.7)'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;
  DECLARE v_all     TINYINT;
  DECLARE v_fy      SMALLINT;
  DECLARE v_q       TINYINT;
  DECLARE v_from    DATE;
  DECLARE v_to      DATE;
  DECLARE v_today   DATE;

  CALL spi_visible_partners(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_ptr WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_ptr;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Partner not found.', 'id');
  END IF;

  SELECT p.id, p.partner_no AS partnerNo, COALESCE(p.short_name, p.legal_name) AS name, p.legal_name AS legalName,
         p.short_name AS shortName, p.country, p.address, p.city, p.website, p.email, p.phone,
         p.registration_no AS registrationNo, p.gst_no AS gstNo, p.pan_no AS panNo, p.currency,
         CAST(p.annual_revenue AS DECIMAL(18,2)) AS annualRevenue, p.revenue_fy AS revenueFy,
         p.credit_rating AS creditRating, p.financial_status AS financialStatus,
         p.employee_count AS employeeCount,
         p.agreement_status AS agreementStatus, p.agreement_valid_till AS agreementValidTill,
         ad.id AS agreementDocumentId, ad.title AS agreementDocumentTitle, af.original_name AS agreementFileName,
         p.tier, p.parent_partner_id AS parentPartnerId,
         COALESCE(pp.short_name, pp.legal_name) AS parentPartnerName,
         p.top_customers AS topCustomers, p.our_share_pct AS ourSharePct, p.sme_count AS smeCount,
         p.can_run_poc AS canRunPoc, p.certified_engineers AS certifiedEngineers,
         p.sales_force_size AS salesForceSize, p.uses_crm AS usesCrm, p.sales_coverage AS salesCoverage,
         p.regions,
         p.influencer_connect AS influencerConnect, p.dmu_impact AS dmuImpact, p.dmu_impact_notes AS dmuImpactNotes,
         p.top_management AS topManagement, p.partner_dmu AS partnerDmu,
         u.full_name AS ownerName, b.full_name AS backupOwnerName,
         p.tech_onboarding_status AS techOnboardingStatus, p.gtm_plan_status AS gtmPlanStatus,
         gd.id AS gtmDocumentId, gd.title AS gtmDocumentTitle, gf.original_name AS gtmFileName,
         p.poc_investment_count AS pocInvestmentCount, CAST(p.poc_investment_value AS DECIMAL(18,2)) AS pocInvestmentValue,
         p.last_engagement_on AS lastEngagementOn, p.next_engagement_on AS nextEngagementOn,
         p.next_engagement_plan AS nextEngagementPlan, p.customer_feedback_rating AS customerFeedbackRating,
         p.customer_feedback_notes AS customerFeedbackNotes, p.publications,
         p.profile_completeness_pct AS completenessPct, p.created_at AS createdAt
    FROM partner p
    JOIN `user` u ON u.id = p.relationship_owner_user_id
    LEFT JOIN `user` b ON b.id = p.backup_owner_user_id
    LEFT JOIN partner pp ON pp.id = p.parent_partner_id
    LEFT JOIN document ad ON ad.id = p.agreement_document_id AND ad.is_active = 1 AND ad.deleted_at IS NULL
    LEFT JOIN file_object af ON af.id = ad.file_object_id
    LEFT JOIN document gd ON gd.id = p.gtm_document_id AND gd.is_active = 1 AND gd.deleted_at IS NULL
    LEFT JOIN file_object gf ON gf.id = gd.file_object_id
   WHERE p.id = p_id;

  SELECT t.code, t.name FROM partner_type_map m JOIN partner_type t ON t.id = m.partner_type_id
   WHERE m.partner_id = p_id ORDER BY t.sort_order;
  SELECT i.code, i.name FROM partner_industry_map m JOIN industry i ON i.id = m.industry_id
   WHERE m.partner_id = p_id ORDER BY i.sort_order;
  SELECT COALESCE(ct.name, pc.other_name) AS name FROM partner_certification pc
    LEFT JOIN certification_type ct ON ct.id = pc.certification_type_id WHERE pc.partner_id = p_id ORDER BY name;
  SELECT cc.id, cc.account_id AS accountId, COALESCE(a.name, cc.customer_name) AS customer, cc.code
    FROM partner_customer_code cc LEFT JOIN account a ON a.id = cc.account_id WHERE cc.partner_id = p_id ORDER BY customer;
  SELECT c.id, c.name, c.designation, c.email, c.phone, c.spoc_type AS spocType
    FROM contact c WHERE c.partner_id = p_id AND c.is_active = 1
   ORDER BY FIELD(IFNULL(c.spoc_type, 'ZZZ'), 'TOP_MGMT', 'DMU', 'COMMERCIAL', 'TECH', 'FINANCE', 'LEGAL', 'ZZZ'), c.name;

  -- scorecard for the current fiscal year
  CALL spi_dashboard_period(NULL, NULL, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_dashboard_period(v_fy, NULL, v_fy, v_q, v_from, v_to, v_today);
  CALL spi_partner_scorecards(v_from, v_to);
  SELECT v_fy AS fiscalYear, v_from AS fromDate, v_to AS toDate,
         c.sourced_count AS sourcedCount, CAST(c.sourced_value AS DECIMAL(18,2)) AS sourcedValue,
         c.influenced_count AS influencedCount, CAST(c.influenced_value AS DECIMAL(18,2)) AS influencedValue,
         c.active_deals AS activeDeals, CAST(c.pipeline AS DECIMAL(18,2)) AS pipeline,
         c.closed_deals AS closedDeals, c.won_deals AS wonDeals, c.lost_deals AS lostDeals, c.win_pct AS winPct,
         CAST(c.revenue AS DECIMAL(18,2)) AS revenue, CAST(c.avg_deal_size AS DECIMAL(18,2)) AS avgDealSize,
         c.lead_to_deal_days AS leadToDealDays, c.order_to_book_days AS orderToBookDays,
         c.gm_pct AS gmPct, c.np_pct AS npPct, c.on_time_payment_pct AS onTimePaymentPct,
         c.avg_payment_delay_days AS avgPaymentDelayDays, c.repeat_business AS repeatBusiness,
         c.new_logos AS newLogos, c.strategic_accounts AS strategicAccounts,
         c.competition_replacement AS competitionReplacement, c.product_mix AS productMix,
         c.tender_pipeline_count AS tenderPipelineCount, CAST(c.tender_pipeline_value AS DECIMAL(18,2)) AS tenderPipelineValue,
         c.tender_readiness_pct AS tenderReadinessPct, c.gtm_activities AS gtmActivities,
         c.cec_engagements AS cecEngagements, c.update_discipline_pct AS updateDisciplinePct,
         c.score, c.rating, c.tier_recommendation AS tierRecommendation
    FROM tmp_card c WHERE c.partner_id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_card;
  DROP TEMPORARY TABLE IF EXISTS tmp_pd;

  -- the partner's deals the user may see
  CALL spi_dashboard_scope(p_user_id, NULL, NULL, NULL, NULL, NULL, v_all);
  SELECT o.id, o.opportunity_no AS opportunityNo, o.title, a.name AS accountName,
         GROUP_CONCAT(op.partner_role ORDER BY op.partner_role SEPARATOR ', ') AS roles,
         o.stage_code AS stageCode, s.name AS stageName, s.is_open AS isOpen, u.full_name AS ownerName,
         CAST(o.expected_value * o.fx_rate AS DECIMAL(18,2)) AS value,
         CAST(COALESCE(o.po_value, o.final_value, o.expected_value) * o.fx_rate AS DECIMAL(18,2)) AS closedValue,
         o.expected_close_date AS expectedCloseDate, o.closed_at AS closedAt
    FROM opportunity_partner op
    JOIN tmp_dash_opp t ON t.id = op.opportunity_id
    JOIN opportunity o ON o.id = op.opportunity_id
    JOIN account a ON a.id = o.account_id
    JOIN `user` u ON u.id = o.owner_user_id
    LEFT JOIN stage s ON s.entity = 'OPP' AND s.code = o.stage_code
   WHERE op.partner_id = p_id
   GROUP BY o.id, o.opportunity_no, o.title, a.name, o.stage_code, s.name, s.is_open, s.sequence_no, u.full_name,
            o.expected_value, o.fx_rate, o.po_value, o.final_value, o.expected_close_date, o.closed_at
   ORDER BY s.is_open DESC, s.sequence_no DESC, o.expected_close_date;
  DROP TEMPORARY TABLE IF EXISTS tmp_dash_opp;

  SELECT pe.id, pe.engagement_type AS engagementType, pe.engagement_on AS engagementOn, pe.with_whom AS withWhom,
         u.full_name AS byName, pe.notes, pe.outcome, pe.next_action AS nextAction, pe.next_action_on AS nextActionOn,
         a.name AS accountName
    FROM partner_engagement pe
    JOIN `user` u ON u.id = pe.by_user_id
    LEFT JOIN account a ON a.id = pe.account_id
   WHERE pe.partner_id = p_id
   ORDER BY pe.engagement_on DESC, pe.id DESC;

  SELECT m.id, a.id AS accountId, a.name AS accountName, m.plan_period AS planPeriod, m.status, m.notes
    FROM partner_account_map m JOIN account a ON a.id = m.account_id
   WHERE m.partner_id = p_id
   ORDER BY m.plan_period DESC, FIELD(m.status, 'OPPORTUNITY', 'ENGAGED', 'PLANNED', 'DROPPED'), a.name;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject, ac.notes,
         ac.outcome, ac.people_met AS peopleMet, u.full_name AS byName
    FROM activity ac JOIN `user` u ON u.id = ac.by_user_id
   WHERE ac.is_active = 1 AND (ac.partner_id = p_id OR (ac.entity_type = 'PARTNER' AND ac.entity_id = p_id))
   ORDER BY ac.activity_at DESC
   LIMIT 50;

  -- hierarchy: the partners one level below this one
  SELECT c.id, c.partner_no AS partnerNo, COALESCE(c.short_name, c.legal_name) AS name, c.city
    FROM partner c
   WHERE c.parent_partner_id = p_id AND c.is_active = 1 AND c.deleted_at IS NULL
   ORDER BY name;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V042', 'Partner onboarding: currency, email/phone, duplicate confirm, agreement & GTM documents, customer codes, required address/industry, employee strength, parent partner, regions', UTC_TIMESTAMP());
