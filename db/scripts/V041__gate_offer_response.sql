-- =============================================================================
-- V041  Sales CRM - Proposal gate: an offer response counts without a remark   (2026-10-15)
--
--   spi_opp_gate_missing   Re-issue of V026. Leaving PROPOSAL checked customer_response
--                          (the optional remark), so an offer marked Accepted / Rejected
--                          with no remark did not meet the gate. It now checks
--                          customer_responded_at, which sp_offer_respond always sets.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V040.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- spi_opp_gate_missing: what is missing to leave p_from_stage (16.3). The caller
-- reads and drops tmp_gate_missing.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_opp_gate_missing $$
CREATE PROCEDURE spi_opp_gate_missing(IN p_opp_id BIGINT UNSIGNED, IN p_from_stage VARCHAR(20))
  SQL SECURITY DEFINER
BEGIN
  DECLARE v_valid     VARCHAR(10);
  DECLARE v_problem   TEXT;
  DECLARE v_solution  BIGINT UNSIGNED;
  DECLARE v_cw_value  DECIMAL(16,2);
  DECLARE v_cw_ok     TINYINT;
  DECLARE v_proc      BIGINT UNSIGNED;
  DECLARE v_presales  BIGINT UNSIGNED;
  DECLARE v_tech      TEXT;
  DECLARE v_no_comp   TINYINT;
  DECLARE v_final     DECIMAL(16,2);
  DECLARE v_terms     VARCHAR(500);
  DECLARE v_tbm       TINYINT;

  DROP TEMPORARY TABLE IF EXISTS tmp_gate_missing;
  CREATE TEMPORARY TABLE tmp_gate_missing (seq INT NOT NULL AUTO_INCREMENT PRIMARY KEY, item VARCHAR(200) NOT NULL);

  SELECT validation_status, problem_statement, solution_id, commercial_window_value, commercial_window_accepted,
         procurement_type_id, presales_owner_user_id, technical_requirement, no_competition, final_value,
         payment_terms, partner_tbm
    INTO v_valid, v_problem, v_solution, v_cw_value, v_cw_ok, v_proc, v_presales, v_tech, v_no_comp, v_final,
         v_terms, v_tbm
    FROM opportunity WHERE id = p_opp_id;

  CASE p_from_stage
    WHEN 'QUALIFIED' THEN
      IF IFNULL(v_valid, '') <> 'VALID' THEN INSERT INTO tmp_gate_missing (item) VALUES ('The deal is validated (VALID)'); END IF;
      IF NULLIF(TRIM(IFNULL(v_problem, '')), '') IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Problem statement'); END IF;
      IF v_solution IS NULL OR NOT EXISTS (SELECT 1 FROM opportunity_product WHERE opportunity_id = p_opp_id) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Product and solution');
      END IF;
      IF v_cw_value IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Commercial window value'); END IF;
      IF NOT EXISTS (SELECT 1 FROM opportunity_dmu WHERE opportunity_id = p_opp_id AND dmu_role = 'TECH_BUYER') THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('DMU: a technical buyer');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM opportunity_dmu WHERE opportunity_id = p_opp_id AND dmu_role = 'COMM_BUYER') THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('DMU: a commercial buyer');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM opportunity_dmu WHERE opportunity_id = p_opp_id
                      AND dmu_role IN ('INFLUENCER_INT', 'INFLUENCER_EXT')) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('DMU: an influencer');
      END IF;
      IF v_proc IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Procurement process'); END IF;
    WHEN 'TECH_ENGAGEMENT' THEN
      IF v_presales IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Pre-sales owner'); END IF;
      IF NULLIF(TRIM(IFNULL(v_tech, '')), '') IS NULL THEN INSERT INTO tmp_gate_missing (item) VALUES ('Technical requirement'); END IF;
      IF v_no_comp = 0 AND NOT EXISTS (SELECT 1 FROM opportunity_competitor WHERE opportunity_id = p_opp_id) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Competition: a competitor, or "no competition"');
      END IF;
      IF v_cw_ok = 0 THEN INSERT INTO tmp_gate_missing (item) VALUES ('Commercial window accepted by the customer'); END IF;
    WHEN 'POC' THEN
      IF NOT EXISTS (SELECT 1 FROM opportunity_poc
                      WHERE opportunity_id = p_opp_id
                        AND ((skipped = 1 AND NULLIF(TRIM(IFNULL(skip_reason, '')), '') IS NOT NULL)
                             OR (skipped = 0 AND NULLIF(TRIM(IFNULL(success_criteria, '')), '') IS NOT NULL
                                 AND NULLIF(TRIM(IFNULL(exit_criteria, '')), '') IS NOT NULL
                                 AND customer_lead_contact_id IS NOT NULL))) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('POC: success and exit criteria and the customer lead, or POC skipped with a reason');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM offer WHERE opportunity_id = p_opp_id AND sent_at IS NOT NULL) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('An offer sent to the customer');
      END IF;
    WHEN 'PROPOSAL' THEN
      IF NOT EXISTS (SELECT 1 FROM offer WHERE opportunity_id = p_opp_id AND customer_responded_at IS NOT NULL)
         AND NOT EXISTS (SELECT 1 FROM activity WHERE opportunity_id = p_opp_id AND activity_type = 'NEGOTIATION' AND is_active = 1) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('The customer response on an offer, or a negotiation activity');
      END IF;
    WHEN 'NEGOTIATION' THEN
      IF NOT EXISTS (SELECT 1 FROM activity WHERE opportunity_id = p_opp_id AND activity_type = 'NEGOTIATION'
                      AND is_active = 1 AND NULLIF(TRIM(IFNULL(notes, '')), '') IS NOT NULL) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Negotiation notes (a negotiation activity with notes)');
      END IF;
      -- an accepted offer carries the agreed value and terms (D-42)
      IF v_final IS NULL AND NOT EXISTS (SELECT 1 FROM offer WHERE opportunity_id = p_opp_id AND status = 'ACCEPTED') THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Final value (or an accepted offer)');
      END IF;
      IF NULLIF(TRIM(IFNULL(v_terms, '')), '') IS NULL AND NOT EXISTS (
           SELECT 1 FROM offer WHERE opportunity_id = p_opp_id AND status = 'ACCEPTED'
              AND NULLIF(TRIM(IFNULL(payment_terms, '')), '') IS NOT NULL) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Payment terms');
      END IF;
      IF EXISTS (SELECT 1 FROM opportunity_partner WHERE opportunity_id = p_opp_id AND commercial_confirmed = 0) THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('Partner commercial confirmed for every partner on the deal');
      END IF;
      IF v_tbm = 1 THEN INSERT INTO tmp_gate_missing (item) VALUES ('Partner "to be mapped" cleared'); END IF;
    WHEN 'COMMERCIAL_CLOSED' THEN
      IF NOT EXISTS (SELECT 1 FROM document d JOIN document_type dt ON dt.id = d.document_type_id
                      WHERE d.opportunity_id = p_opp_id AND d.is_active = 1 AND dt.code = 'CONTRACT') THEN
        INSERT INTO tmp_gate_missing (item) VALUES ('A contract or LoI document');
      END IF;
    ELSE
      BEGIN END;
  END CASE;
END $$

DELIMITER ;

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V041', 'Proposal gate: a recorded offer response counts even without a remark', UTC_TIMESTAMP());
