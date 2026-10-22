-- =============================================================================
-- V034  Sales CRM - partner quarterly report document type               (2026-10-14)
--
--   document_type QUARTERLY_REPORT: the Partner Quarterly Report PDF (12.11, UM 7.2) is stored
--   as a document of the partner, so listing, download, access logging and visibility follow
--   the documents module (V023). A new report of the same period becomes the next version.
--
-- Re-runnable (INSERT IGNORE). Prerequisite: V001-V033.
-- Run as the existing account that owns unigr8ways_sales_crm.
-- =============================================================================
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

INSERT IGNORE INTO document_type (code, name, sort_order) VALUES
  ('QUARTERLY_REPORT', 'Partner quarterly report', 14);

-- Record this migration
INSERT IGNORE INTO schema_version (version, description, applied_at)
VALUES ('V034', 'Partner quarterly report document type', UTC_TIMESTAMP());
