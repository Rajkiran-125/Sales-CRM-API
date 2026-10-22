-- =============================================================================
-- V043  Sales CRM - DMU: the influencer is optional   (2026-10-21)
--
--   A DMU is complete with a technical buyer and a commercial buyer. An internal or
--   external influencer can still be recorded but is no longer required.
--
--   spi_lead_qualification_pct  Re-issue of V012: fact 4 drops the influencer.
--   sp_lead_get                 Re-issue of V012: the DMU fact (label and check) likewise.
--   spi_opp_gate_missing        Re-issue of V041: leaving QUALIFIED no longer needs an influencer.
--   Then recalculates qualification_pct for every lead.
--
-- Re-runnable (DROP + CREATE). Prerequisite: V001-V042.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- internal helper: recalculate qualification_pct for a lead
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_lead_qualification_pct $$
CREATE PROCEDURE spi_lead_qualification_pct(IN p_lead_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Recalculate qualification_pct for a lead (6 facts × 16.67)'
BEGIN
  DECLARE v_done  TINYINT DEFAULT 0;
  DECLARE v_pct   DECIMAL(5,2) DEFAULT 0;

  SELECT (
    (NULLIF(TRIM(COALESCE(l.problem_statement, '')), '') IS NOT NULL)
    + (l.product_id IS NOT NULL AND l.solution_id IS NOT NULL)
    + (l.commercial_window_value IS NOT NULL
       AND l.budget_known IS NOT NULL
       AND (l.budget_known <> 'YES'
            OR l.budget_min IS NOT NULL
            OR l.budget_max IS NOT NULL))
    + (EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_lead_id AND d.dmu_role = 'TECH_BUYER')
       AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_lead_id AND d.dmu_role = 'COMM_BUYER'))
    + (l.procurement_type_id IS NOT NULL AND l.procurement_steps_known = 1)
    + (l.expected_close_date IS NOT NULL)
  ) INTO v_done FROM sales_lead l WHERE l.id = p_lead_id;

  SET v_pct = ROUND(COALESCE(v_done, 0) * 100.0 / 6, 2);
  UPDATE sales_lead SET qualification_pct = v_pct WHERE id = p_lead_id;
END $$

-- ---------------------------------------------------------------------------
-- sp_lead_get: re-issue from V012; DMU fact = tech + commercial buyer
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_lead_get $$
CREATE PROCEDURE sp_lead_get(IN p_user_id BIGINT UNSIGNED, IN p_id BIGINT UNSIGNED)
  SQL SECURITY DEFINER
  COMMENT 'Lead page with the qualification facts (12.4) + row_version for optimistic lock'
BEGIN
  DECLARE v_visible TINYINT DEFAULT 0;

  CALL spi_visible_leads(p_user_id);
  SELECT COUNT(*) INTO v_visible FROM tmp_vis_lead WHERE id = p_id;
  DROP TEMPORARY TABLE IF EXISTS tmp_vis_lead;
  IF v_visible = 0 THEN
    CALL spi_raise('NOT_FOUND', 'Lead not found.', 'id');
  END IF;

  SELECT l.id, l.lead_no AS leadNo, l.stage_code AS stageCode, s.name AS stageName,
         l.stage_entered_at AS stageEnteredAt, l.source, l.partner_id AS partnerId,
         p.short_name AS partnerName, l.partner_contact_text AS partnerContact,
         l.account_id AS accountId, COALESCE(a.name, l.account_name_text) AS accountName,
         (l.account_id IS NULL) AS isNewAccount, i.id AS industryId, i.name AS industryName,
         l.contact_name AS contactName, l.contact_designation AS contactDesignation,
         l.contact_email AS contactEmail, l.contact_phone AS contactPhone, l.city,
         l.locations_count AS locationsCount, l.need_text AS needText,
         CAST(l.rough_value AS DECIMAL(18,2)) AS roughValue, l.rough_timing AS roughTiming,
         u.full_name AS ownerName, u.id AS ownerUserId,
         b.full_name AS backupOwnerName, b.id AS backupOwnerUserId,
         l.next_action AS nextAction, l.next_action_due_on AS nextActionDueOn,
         l.problem_statement AS problemStatement,
         pr.name AS productName, pr.id AS productId,
         so.name AS solutionName, so.id AS solutionId,
         CAST(l.commercial_window_value AS DECIMAL(18,2)) AS commercialWindowValue,
         l.budget_known AS budgetKnown, CAST(l.budget_min AS DECIMAL(18,2)) AS budgetMin,
         CAST(l.budget_max AS DECIMAL(18,2)) AS budgetMax,
         pt.id AS procurementTypeId, pt.name AS procurementTypeName,
         l.procurement_steps_known AS procurementStepsKnown,
         l.expected_close_date AS expectedCloseDate,
         l.qualification_pct AS qualificationPct, r.name AS disqualifyReason,
         l.disqualify_note AS disqualifyNote, l.disqualified_at AS disqualifiedAt,
         l.opportunity_id AS opportunityId, o.opportunity_no AS opportunityNo,
         l.converted_at AS convertedAt, l.last_activity_at AS lastActivityAt,
         l.created_at AS createdAt, cb.full_name AS createdByName,
         l.row_version AS rowVersion
    FROM sales_lead l
    LEFT JOIN stage s ON s.entity = 'LEAD' AND s.code = l.stage_code
    LEFT JOIN partner p ON p.id = l.partner_id
    LEFT JOIN account a ON a.id = l.account_id
    LEFT JOIN industry i ON i.id = l.industry_id
    LEFT JOIN product pr ON pr.id = l.product_id
    LEFT JOIN solution so ON so.id = l.solution_id
    LEFT JOIN procurement_type pt ON pt.id = l.procurement_type_id
    LEFT JOIN reason r ON r.id = l.disqualify_reason_id
    LEFT JOIN opportunity o ON o.id = l.opportunity_id
    LEFT JOIN `user` b ON b.id = l.backup_owner_user_id
    LEFT JOIN `user` cb ON cb.id = l.created_by
    JOIN `user` u ON u.id = l.owner_user_id
   WHERE l.id = p_id;

  -- the six qualification facts (BR-LD-05); conversion needs 6 / 6 (BR-LD-06)
  SELECT 1 AS seq, 'PROBLEM' AS code, 'Problem statement' AS label,
         (NULLIF(TRIM(l.problem_statement), '') IS NOT NULL) AS done
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 2, 'SOLUTION', 'Solution mapped (product + solution)',
         (l.product_id IS NOT NULL AND l.solution_id IS NOT NULL)
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 3, 'COMMERCIAL', 'Commercial window (value + budget)',
         (l.commercial_window_value IS NOT NULL AND l.budget_known IS NOT NULL
          AND (l.budget_known <> 'YES' OR l.budget_min IS NOT NULL OR l.budget_max IS NOT NULL))
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 4, 'DMU', 'DMU: tech buyer, commercial buyer',
         (EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_id AND d.dmu_role = 'TECH_BUYER')
          AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = p_id AND d.dmu_role = 'COMM_BUYER'))
  UNION ALL
  SELECT 5, 'PROCUREMENT', 'Procurement process known',
         (l.procurement_type_id IS NOT NULL AND l.procurement_steps_known = 1)
    FROM sales_lead l WHERE l.id = p_id
  UNION ALL
  SELECT 6, 'CLOSE_DATE', 'Expected closure date', (l.expected_close_date IS NOT NULL)
    FROM sales_lead l WHERE l.id = p_id
  ORDER BY seq;

  SELECT pr.id, pr.name FROM lead_product lp JOIN product pr ON pr.id = lp.product_id
   WHERE lp.lead_id = p_id ORDER BY pr.sort_order, pr.name;

  SELECT d.id, d.name, d.designation, d.dmu_role AS dmuRole, d.influence_level AS influenceLevel,
         d.stand, d.notes
    FROM lead_dmu d WHERE d.lead_id = p_id
   ORDER BY FIELD(d.dmu_role, 'TECH_BUYER', 'COMM_BUYER', 'INFLUENCER_INT', 'INFLUENCER_EXT'), d.id;

  SELECT c.id, c.name FROM lead_competitor lc JOIN competitor c ON c.id = lc.competitor_id
   WHERE lc.lead_id = p_id ORDER BY c.name;

  SELECT ac.id, ac.activity_type AS activityType, ac.activity_at AS activityAt, ac.subject,
         ac.notes, ac.outcome, ac.people_met AS peopleMet, ac.next_action AS nextAction,
         ac.next_action_on AS nextActionOn, u.full_name AS byName
    FROM activity ac JOIN `user` u ON u.id = ac.by_user_id
   WHERE ac.is_active = 1 AND (ac.lead_id = p_id OR (ac.entity_type = 'LEAD' AND ac.entity_id = p_id))
   ORDER BY ac.activity_at DESC, ac.id DESC
   LIMIT 100;

  SELECT tk.id, tk.task_type AS taskType, tk.title, tk.due_at AS dueAt, tk.status,
         u.full_name AS ownerName
    FROM task tk JOIN `user` u ON u.id = tk.owner_user_id
   WHERE tk.entity_type = 'LEAD' AND tk.entity_id = p_id
   ORDER BY tk.status = 'OPEN' DESC, tk.due_at;

  SELECT sh.id, fs.name AS fromStage, ts.name AS toStage, u.full_name AS changedByName,
         sh.changed_at AS changedAt, sh.reason, sh.days_in_previous AS daysInPrevious
    FROM stage_history sh
    LEFT JOIN stage fs ON fs.entity = 'LEAD' AND fs.code = sh.from_stage
    LEFT JOIN stage ts ON ts.entity = 'LEAD' AND ts.code = sh.to_stage
    LEFT JOIN `user` u ON u.id = sh.changed_by
   WHERE sh.entity_type = 'LEAD' AND sh.entity_id = p_id
   ORDER BY sh.changed_at DESC, sh.id DESC;
END $$

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

-- existing leads: re-score fact 4 under the new rule
UPDATE sales_lead l
   SET l.qualification_pct = ROUND((
         (NULLIF(TRIM(COALESCE(l.problem_statement, '')), '') IS NOT NULL)
         + (l.product_id IS NOT NULL AND l.solution_id IS NOT NULL)
         + (l.commercial_window_value IS NOT NULL
            AND l.budget_known IS NOT NULL
            AND (l.budget_known <> 'YES' OR l.budget_min IS NOT NULL OR l.budget_max IS NOT NULL))
         + (EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = l.id AND d.dmu_role = 'TECH_BUYER')
            AND EXISTS (SELECT 1 FROM lead_dmu d WHERE d.lead_id = l.id AND d.dmu_role = 'COMM_BUYER'))
         + (l.procurement_type_id IS NOT NULL AND l.procurement_steps_known = 1)
         + (l.expected_close_date IS NOT NULL)
       ) * 100.0 / 6, 2);

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V043', 'DMU: technical + commercial buyer are enough; influencer optional', UTC_TIMESTAMP());
