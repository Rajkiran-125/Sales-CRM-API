-- =============================================================================
-- V030  Sales CRM - Partner Master write side                          (2026-10-14)
--
--   sp_partner_duplicates       GET /partners/duplicates: partners with the same name, GST or
--                               website, with their owner, across all partners (BR-PT-02:
--                               "is this partner already engaged, and by whom?").
--   spi_partner_completeness    Profile completeness % from the four editable sections with
--                               the OD-38 default weights: entity 30, type 10, industry 25,
--                               engagement 35 (BR-PT-04).
--   spi_partner_check_people    Owner / backup owner rules, as for accounts (BR-AC-01).
--   spi_partner_edit_check      Visible + owner, backup or their manager (or ALL scope) + rowVersion.
--   sp_partner_create           POST /partners: the minimum fields (BR-PT-01: name, country,
--                               type, owner); PTR-0001 numbers.
--   sp_partner_edit_get         GET /partners/{id}/edit: the editable values with ids, and the
--                               contacts with every field (PATCH /contacts replaces all).
--   sp_partner_save_entity      PATCH /partners/{id} section ENTITY (1); BR-PT-07.
--   sp_partner_save_type        section TYPE (2): types (BR-PT-03), tier, certifications (OD-39).
--   sp_partner_save_industry    section INDUSTRY (3): industries and expertise.
--   sp_partner_save_engagement  section ENGAGEMENT (4): structure, owners, feedback.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V029.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_partner_duplicates: name / GST / website (scheme, www. and trailing / ignored)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_partner_duplicates $$
CREATE PROCEDURE sp_partner_duplicates(
  IN p_name       VARCHAR(250),
  IN p_gst_no     VARCHAR(15),
  IN p_website    VARCHAR(255),
  IN p_exclude_id BIGINT UNSIGNED
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_name VARCHAR(250) DEFAULT NULLIF(LOWER(TRIM(IFNULL(p_name, ''))), '');
  DECLARE v_gst  VARCHAR(15)  DEFAULT NULLIF(UPPER(TRIM(IFNULL(p_gst_no, ''))), '');
  DECLARE v_site VARCHAR(255) DEFAULT
    NULLIF(REGEXP_REPLACE(LOWER(TRIM(IFNULL(p_website, ''))), '^(https?://)?(www\\.)?|/+$', ''), '');

  SELECT p.id, p.partner_no AS partnerNo, COALESCE(p.short_name, p.legal_name) AS name,
         p.city, u.full_name AS ownerName,
         CASE WHEN v_gst IS NOT NULL AND p.gst_no = v_gst THEN 'gstNo'
              WHEN v_site IS NOT NULL
               AND REGEXP_REPLACE(LOWER(TRIM(IFNULL(p.website, ''))), '^(https?://)?(www\\.)?|/+$', '') = v_site
              THEN 'website'
              ELSE 'name' END AS matchedOn
    FROM partner p
    JOIN `user` u ON u.id = p.relationship_owner_user_id
   WHERE p.is_active = 1 AND p.deleted_at IS NULL
     AND (p_exclude_id IS NULL OR p.id <> p_exclude_id)
     AND ((v_name IS NOT NULL AND (LOWER(p.legal_name) = v_name OR LOWER(IFNULL(p.short_name, '')) = v_name))
          OR (v_gst IS NOT NULL AND p.gst_no = v_gst)
          OR (v_site IS NOT NULL
              AND REGEXP_REPLACE(LOWER(TRIM(IFNULL(p.website, ''))), '^(https?://)?(www\\.)?|/+$', '') = v_site))
   ORDER BY p.legal_name
   LIMIT 5;
END $$

-- ---------------------------------------------------------------------------
-- spi_partner_completeness: share of filled items per section x the section weight
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
                 + (p.agreement_status <> 'NONE') + 2) / 14          -- legal name + country always set
         + 10 * ((EXISTS (SELECT 1 FROM partner_type_map m WHERE m.partner_id = p.id))
                 + (p.tier IS NOT NULL)
                 + (EXISTS (SELECT 1 FROM partner_certification c WHERE c.partner_id = p.id))) / 3
         + 25 * ((EXISTS (SELECT 1 FROM partner_industry_map m WHERE m.partner_id = p.id))
                 + (p.top_customers IS NOT NULL) + (p.our_share_pct IS NOT NULL) + (p.sme_count IS NOT NULL)
                 + (p.can_run_poc IS NOT NULL) + (p.certified_engineers IS NOT NULL)
                 + (p.sales_force_size IS NOT NULL) + (p.uses_crm IS NOT NULL)
                 + (p.sales_coverage IS NOT NULL) + (p.influencer_connect IS NOT NULL)
                 + (p.dmu_impact IS NOT NULL)) / 11
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
-- spi_partner_check_people: owner must be active and (unless ALL scope / unchanged) in the
-- actor's tree; backup differs from the owner and is active
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_partner_check_people $$
CREATE PROCEDURE spi_partner_check_people(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_owner_user_id BIGINT UNSIGNED,
  IN p_backup_user_id BIGINT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_owner_user_id AND status = 'ACTIVE') THEN
    CALL spi_raise('VALIDATION_FAILED', 'The relationship owner must be an active user.', 'relationshipOwnerUserId');
  END IF;
  IF p_allow_any = 0 AND NOT EXISTS (SELECT 1 FROM user_hierarchy
       WHERE ancestor_user_id = p_actor_user_id AND descendant_user_id = p_owner_user_id) THEN
    CALL spi_raise('FORBIDDEN', 'The owner must be you or someone in your team.', 'relationshipOwnerUserId');
  END IF;
  IF p_backup_user_id IS NOT NULL THEN
    IF p_backup_user_id = p_owner_user_id THEN
      CALL spi_raise('VALIDATION_FAILED', 'The backup owner must differ from the owner.', 'backupOwnerUserId');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM `user` WHERE id = p_backup_user_id AND status = 'ACTIVE') THEN
      CALL spi_raise('VALIDATION_FAILED', 'The backup owner must be an active user.', 'backupOwnerUserId');
    END IF;
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- spi_partner_edit_check: the actor may edit this partner at this version
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_partner_edit_check $$
CREATE PROCEDURE spi_partner_edit_check(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_id            BIGINT UNSIGNED,
  IN p_row_version   INT UNSIGNED,
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_owner   BIGINT UNSIGNED;
  DECLARE v_backup  BIGINT UNSIGNED;
  DECLARE v_version INT UNSIGNED;

  SELECT relationship_owner_user_id, backup_owner_user_id, row_version
    INTO v_owner, v_backup, v_version
    FROM partner WHERE id = p_id AND is_active = 1 AND deleted_at IS NULL;

  IF v_owner IS NULL THEN
    CALL spi_raise('NOT_FOUND', 'Partner not found.', 'id');
  END IF;
  IF p_allow_any = 0 AND NOT EXISTS (SELECT 1 FROM user_hierarchy
       WHERE ancestor_user_id = p_actor_user_id AND descendant_user_id IN (v_owner, IFNULL(v_backup, 0))) THEN
    CALL spi_raise('FORBIDDEN', 'Only the relationship owner, the backup owner or their manager can edit this partner.', 'id');
  END IF;
  IF v_version <> p_row_version THEN
    CALL spi_raise('CONFLICT', 'Someone else changed this partner. Reload and try again.', 'rowVersion');
  END IF;
END $$

-- ---------------------------------------------------------------------------
-- spi_partner_saved: bump the version, recompute completeness, audit, answer
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_partner_saved $$
CREATE PROCEDURE spi_partner_saved(
  IN p_actor_user_id BIGINT UNSIGNED,
  IN p_request_id    VARCHAR(36),
  IN p_ip            VARCHAR(45),
  IN p_id            BIGINT UNSIGNED,
  IN p_section       VARCHAR(12)
)
  SQL SECURITY DEFINER
BEGIN
  UPDATE partner SET row_version = row_version + 1, updated_at = UTC_TIMESTAMP(3),
                     updated_by = p_actor_user_id
   WHERE id = p_id;
  CALL spi_partner_completeness(p_id);
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('partner', p_id, 'PARTNER_UPDATE', JSON_OBJECT('section', p_section),
          p_actor_user_id, p_ip, p_request_id);
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_create (BR-PT-01)
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
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_no    VARCHAR(30);
  DECLARE v_id    BIGINT UNSIGNED;
  DECLARE v_types INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT COUNT(*) INTO v_types
    FROM JSON_TABLE(p_type_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j
    JOIN partner_type t ON t.id = j.id AND t.is_active = 1;
  IF v_types = 0 OR v_types <> JSON_LENGTH(p_type_ids) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Choose at least one active partner type.', 'typeIds');
  END IF;
  CALL spi_partner_check_people(p_actor_user_id, p_owner_user_id, p_backup_user_id, p_allow_any);

  START TRANSACTION;
  CALL spi_next_number('PTR', 0, v_no);
  INSERT INTO partner (partner_no, legal_name, short_name, country, city, website, gst_no,
                       relationship_owner_user_id, backup_owner_user_id, created_at, created_by)
  VALUES (v_no, p_legal_name, p_short_name, p_country, p_city, p_website, UPPER(p_gst_no),
          p_owner_user_id, p_backup_user_id, UTC_TIMESTAMP(3), p_actor_user_id);
  SET v_id = LAST_INSERT_ID();
  INSERT INTO partner_type_map (partner_id, partner_type_id)
  SELECT v_id, j.id FROM JSON_TABLE(p_type_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j;
  CALL spi_partner_completeness(v_id);
  INSERT INTO audit_log (entity_type, entity_id, action, changed_fields_json, user_id, ip_address, request_id)
  VALUES ('partner', v_id, 'PARTNER_CREATE',
          JSON_OBJECT('legalName', p_legal_name, 'ownerUserId', p_owner_user_id),
          p_actor_user_id, p_ip, p_request_id);
  COMMIT;

  SELECT v_id AS id, v_no AS partnerNo;
END $$

-- ---------------------------------------------------------------------------
-- sp_partner_edit_get: editable values with ids; then type ids, industry ids, certifications
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
         p.financial_status AS financialStatus, p.agreement_status AS agreementStatus,
         p.agreement_valid_till AS agreementValidTill,
         p.tier,
         p.top_customers AS topCustomers, p.our_share_pct AS ourSharePct, p.sme_count AS smeCount,
         p.can_run_poc AS canRunPoc, p.certified_engineers AS certifiedEngineers,
         p.sales_force_size AS salesForceSize, p.uses_crm AS usesCrm,
         p.sales_coverage AS salesCoverage, p.influencer_connect AS influencerConnect,
         p.dmu_impact AS dmuImpact, p.dmu_impact_notes AS dmuImpactNotes,
         p.top_management AS topManagement, p.partner_dmu AS partnerDmu,
         p.relationship_owner_user_id AS relationshipOwnerUserId, u.full_name AS ownerName,
         p.backup_owner_user_id AS backupOwnerUserId, b.full_name AS backupOwnerName,
         p.tech_onboarding_status AS techOnboardingStatus, p.gtm_plan_status AS gtmPlanStatus,
         p.poc_investment_count AS pocInvestmentCount,
         CAST(p.poc_investment_value AS DECIMAL(18,2)) AS pocInvestmentValue,
         p.customer_feedback_rating AS customerFeedbackRating,
         p.customer_feedback_notes AS customerFeedbackNotes, p.publications,
         p.profile_completeness_pct AS completenessPct
    FROM partner p
    JOIN `user` u ON u.id = p.relationship_owner_user_id
    LEFT JOIN `user` b ON b.id = p.backup_owner_user_id
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
END $$

-- ---------------------------------------------------------------------------
-- section 1: entity (BR-PT-07: a signed agreement needs its valid-till date)
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
  IN p_agreement      VARCHAR(15),
  IN p_valid_till     DATE,
  IN p_allow_any      TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_edit_check(p_actor_user_id, p_id, p_row_version, p_allow_any);
  IF p_agreement = 'SIGNED' AND p_valid_till IS NULL THEN
    CALL spi_raise('VALIDATION_FAILED', 'A signed agreement needs its valid-till date.', 'agreementValidTill');
  END IF;

  START TRANSACTION;
  UPDATE partner
     SET legal_name = p_legal_name, short_name = p_short_name, country = p_country,
         address = p_address, city = p_city, website = p_website, email = p_email, phone = p_phone,
         registration_no = p_registration, gst_no = UPPER(p_gst_no), pan_no = UPPER(p_pan_no),
         currency = IFNULL(p_currency, 'INR'), annual_revenue = p_annual_revenue,
         revenue_fy = p_revenue_fy, credit_rating = p_credit_rating, financial_status = p_financial,
         agreement_status = p_agreement, agreement_valid_till = p_valid_till
   WHERE id = p_id;
  CALL spi_partner_saved(p_actor_user_id, p_request_id, p_ip, p_id, 'ENTITY');
  COMMIT;
  SELECT id, row_version AS rowVersion, profile_completeness_pct AS completenessPct FROM partner WHERE id = p_id;
END $$

-- ---------------------------------------------------------------------------
-- section 2: type (BR-PT-03 several types; OD-39 certifications: master list + "other")
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

  START TRANSACTION;
  UPDATE partner SET tier = p_tier WHERE id = p_id;
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
-- section 3: industry & expertise
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
  IN p_influencer    VARCHAR(1000),
  IN p_dmu_impact    VARCHAR(10),
  IN p_dmu_notes     VARCHAR(1000),
  IN p_allow_any     TINYINT(1)
)
  SQL SECURITY DEFINER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  CALL spi_partner_edit_check(p_actor_user_id, p_id, p_row_version, p_allow_any);
  IF (SELECT COUNT(*) FROM JSON_TABLE(p_industry_ids, '$[*]' COLUMNS (id BIGINT UNSIGNED PATH '$')) j
        JOIN industry i ON i.id = j.id) <> JSON_LENGTH(p_industry_ids) THEN
    CALL spi_raise('VALIDATION_FAILED', 'Unknown industry.', 'industryIds');
  END IF;

  START TRANSACTION;
  UPDATE partner
     SET top_customers = p_top_customers, our_share_pct = p_share_pct, sme_count = p_sme_count,
         can_run_poc = p_can_run_poc, certified_engineers = p_cert_eng,
         sales_force_size = p_sales_force, uses_crm = p_uses_crm, sales_coverage = p_coverage,
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
-- section 4: engagement structure (the engagement log and next plan come with V031)
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

  START TRANSACTION;
  UPDATE partner
     SET top_management = p_top_management, partner_dmu = p_partner_dmu,
         relationship_owner_user_id = p_owner_user_id, backup_owner_user_id = p_backup_user_id,
         tech_onboarding_status = p_tech_status, gtm_plan_status = p_gtm_status,
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

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V030', 'Partner Master write side: create, duplicates, per-section edit, completeness', UTC_TIMESTAMP());
