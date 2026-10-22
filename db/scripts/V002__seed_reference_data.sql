-- =============================================================================
-- V002  Sales CRM - reference / seed data                         (2026-10-09)
--
-- Loads: permission catalogue (11.2), the seven system roles of UM 3 with the
-- proposed role-permission matrix (11.3, OD-01/OD-02/OD-31 defaults), stages and
-- confidence (UM 4.2-4.4, 6.6, OD-03, OD-47), masters seeded from the User Manual
-- (OD-44), business settings with the UM 10 defaults, and the Phase 0 email
-- templates.
--
-- Idempotent: uses INSERT IGNORE, so re-running never overwrites values the CRM
-- Admin has edited since. NO user is created here: the first CRM Admin is
-- created with the API command `npm run bootstrap:admin` (11.5); no default
-- password ships with the system.
--
-- Prerequisite: V001. Run as the existing account that owns unigr8ways_sales_crm.
-- Verify:
--   SELECT r.code, COUNT(*) FROM role r JOIN role_permission rp ON rp.role_id = r.id GROUP BY r.code;
--   SELECT entity, COUNT(*) FROM stage GROUP BY entity;       -- LEAD 5, OPP 10, TENDER 9, ORDER 7
-- =============================================================================

-- Works only inside unigr8ways_sales_crm: stops with "Unknown database" if the
-- schema is missing. Creates no database, account or grant.
USE unigr8ways_sales_crm;

SET NAMES utf8mb4;

-- -----------------------------------------------------------------------------
-- Permission catalogue (11.2). Admins assign these to roles; they cannot create codes.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO permission (code, module, action, description, is_sensitive, sort_order) VALUES
  ('dashboard.view',                'DASHBOARD_REPORTS',   'view',              'View the management dashboard',                              0, 101),
  ('report.view',                   'DASHBOARD_REPORTS',   'view',              'View reports',                                               0, 102),
  ('report.export',                 'DASHBOARD_REPORTS',   'export',            'Export reports and lists to Excel',                          1, 103),
  ('task.view_own',                 'TASKS',               'view_own',          'View own tasks (My day)',                                    0, 201),
  ('task.create',                   'TASKS',               'create',            'Create tasks',                                               0, 202),
  ('task.update',                   'TASKS',               'update',            'Complete, cancel or reschedule own tasks',                   0, 203),
  ('lead.view',                     'LEADS',               'view',              'View leads',                                                 0, 301),
  ('lead.create',                   'LEADS',               'create',            'Create leads',                                               0, 302),
  ('lead.update',                   'LEADS',               'update',            'Update leads',                                               0, 303),
  ('lead.qualify',                  'LEADS',               'qualify',           'Record qualification facts and the DMU',                     0, 304),
  ('lead.convert',                  'LEADS',               'convert',           'Convert a qualified lead to an opportunity',                 0, 305),
  ('lead.disqualify',               'LEADS',               'disqualify',        'Disqualify a lead',                                          0, 306),
  ('lead.export',                   'LEADS',               'export',            'Export leads',                                               1, 307),
  ('opportunity.view',              'OPPORTUNITIES',       'view',              'View opportunities',                                         0, 401),
  ('opportunity.update',            'OPPORTUNITIES',       'update',            'Update opportunities, DMU, partners, competition and POC',   0, 402),
  ('opportunity.move_stage',        'OPPORTUNITIES',       'move_stage',        'Move an opportunity to the next stage',                      0, 403),
  ('opportunity.close',             'OPPORTUNITIES',       'close',             'Close an opportunity as won, lost or dormant',               0, 404),
  ('opportunity.validate',          'OPPORTUNITIES',       'validate',          'Validate deals (Qualified gate)',                            1, 405),
  ('opportunity.stage_override',    'OPPORTUNITIES',       'stage_override',    'Backward stage moves and gate overrides, with a reason',     1, 406),
  ('opportunity.assign',            'OPPORTUNITIES',       'assign',            'Assign and change owners',                                   1, 407),
  ('opportunity.export',            'OPPORTUNITIES',       'export',            'Export opportunities',                                       1, 408),
  ('offer.create',                  'OFFERS',              'create',            'Create offer versions',                                      0, 501),
  ('offer.submit',                  'OFFERS',              'submit',            'Submit offers for approval',                                 0, 502),
  ('offer.approve',                 'OFFERS',              'approve',           'Approve offers above the approval limit',                    1, 503),
  ('offer.send',                    'OFFERS',              'send',              'Send offers to the customer',                                0, 504),
  ('partner_commercial.view',       'OFFERS',              'view',              'View partner commercials',                                   1, 505),
  ('partner_commercial.manage',     'OFFERS',              'manage',            'Record partner commercial versions',                         1, 506),
  ('account.view',                  'ACCOUNTS',            'view',              'View accounts and contacts',                                 0, 601),
  ('account.create',                'ACCOUNTS',            'create',            'Create accounts',                                            0, 602),
  ('account.update',                'ACCOUNTS',            'update',            'Update accounts',                                            0, 603),
  ('account.merge',                 'ACCOUNTS',            'merge',             'Merge duplicate accounts',                                   1, 604),
  ('contact.manage',                'ACCOUNTS',            'manage',            'Create and update contacts',                                 0, 605),
  ('partner.view',                  'PARTNERS',            'view',              'View partners',                                              0, 701),
  ('partner.create',                'PARTNERS',            'create',            'Create partners',                                            0, 702),
  ('partner.update',                'PARTNERS',            'update',            'Update partner sections and account mapping',                0, 703),
  ('partner.engagement.manage',     'PARTNERS',            'engagement.manage', 'Log partner engagements and plans',                          0, 704),
  ('partner.send_form',             'PARTNERS',            'send_form',         'Send the partner self-service form (phase 2)',               0, 705),
  ('partner.review_submission',     'PARTNERS',            'review_submission', 'Review partner self-service submissions (phase 2)',          0, 706),
  ('partner_performance.view',      'PARTNER_PERFORMANCE', 'view',              'View partner scorecards',                                    0, 801),
  ('partner_performance.recompute', 'PARTNER_PERFORMANCE', 'recompute',         'Recompute partner performance',                              1, 802),
  ('partner_report.generate',       'PARTNER_PERFORMANCE', 'generate',          'Generate the partner quarterly report',                      0, 803),
  ('tender.view',                   'TENDERS',             'view',              'View tenders',                                               0, 901),
  ('tender.create',                 'TENDERS',             'create',            'Create tenders',                                             0, 902),
  ('tender.update',                 'TENDERS',             'update',            'Update tenders, checklist and status',                       0, 903),
  ('order.view',                    'ORDERS',              'view',              'View orders',                                                0, 1001),
  ('order.update',                  'ORDERS',              'update',            'Record order events',                                        0, 1002),
  ('order.finance',                 'ORDERS',              'finance',           'Invoices, payments, partner release, revenue / GM / NP',     1, 1003),
  ('forecast.view',                 'FORECAST',            'view',              'View weekly status and monthly closure',                     0, 1101),
  ('forecast.submit_own',           'FORECAST',            'submit_own',        'Submit weekly status and monthly commit for own deals',      0, 1102),
  ('forecast.view_team',            'FORECAST',            'view_team',         'View the team forecast and hierarchy funnel',                0, 1103),
  ('forecast.nudge',                'FORECAST',            'nudge',             'Nudge team members about pending updates',                   0, 1104),
  ('winloss.view',                  'WIN_LOSS',            'view',              'View win / loss analysis',                                   0, 1201),
  ('document.view',                 'DOCUMENTS',           'view',              'View and download documents of visible records',             0, 1301),
  ('document.upload',               'DOCUMENTS',           'upload',            'Upload documents',                                           0, 1302),
  ('document.delete',               'DOCUMENTS',           'delete',            'Delete own uploads (admins: any)',                           0, 1303),
  ('activity.view',                 'ACTIVITIES',          'view',              'View activities and notes',                                  0, 1401),
  ('activity.create',               'ACTIVITIES',          'create',            'Log activities and notes',                                   0, 1402),
  ('activity.update_own',           'ACTIVITIES',          'update_own',        'Edit own activities',                                        0, 1403),
  ('master.manage',                 'MASTERS',             'manage',            'Manage master lists',                                        1, 1501),
  ('custom_field.manage',           'MASTERS',             'manage',            'Manage custom fields',                                       1, 1502),
  ('target.manage',                 'MASTERS',             'manage',            'Set targets',                                                1, 1503),
  ('setting.manage',                'MASTERS',             'manage',            'Change business settings',                                   1, 1504),
  ('email_template.manage',         'MASTERS',             'manage',            'Edit email templates',                                       1, 1505),
  ('import.run',                    'IMPORT',              'run',               'Run data imports',                                           1, 1601),
  ('user.view',                     'ADMINISTRATION',      'view',              'View users',                                                 1, 1701),
  ('user.manage',                   'ADMINISTRATION',      'manage',            'Invite, edit, activate and deactivate users',                1, 1702),
  ('user.reassign_records',         'ADMINISTRATION',      'reassign_records',  'Bulk-reassign records of a user',                            1, 1703),
  ('role.manage',                   'ADMINISTRATION',      'manage',            'Manage roles and the permission matrix',                     1, 1704),
  ('audit.view',                    'ADMINISTRATION',      'view',              'View the security and data audit logs',                      1, 1705);

-- -----------------------------------------------------------------------------
-- System roles (UM 3). They cannot be deleted or deactivated.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO role (code, name, description, data_scope, is_system) VALUES
  ('SALES_EXEC',  'Sales Executive', 'Creates and updates leads, deals, activities and weekly status; proposes qualification.',            'OWN_AND_TEAM',      1),
  ('PRESALES',    'Pre-sales',       'Solution mapping, technical engagement, POC and competition notes on deals they own as pre-sales.',  'ASSIGNED_AND_TEAM', 1),
  ('PARTNER_MGR', 'Partner Manager', 'Partner master, engagement plan, GTM plan and quarterly review for the partners they own.',          'PARTNER_OWNED',     1),
  ('SALES_HEAD',  'Sales Head',      'Validates deals, approves offers above the limit, assigns owners and sets targets.',                 'ALL',               1),
  ('MANAGEMENT',  'Management',      'Director / MD: everything read-only plus comments; dashboards and monthly review.',                  'ALL',               1),
  ('FINANCE',     'Finance',         'Records invoices, payments, partner payment releases and revenue / GM / NP.',                        'MODULE_LIMITED',    1),
  ('CRM_ADMIN',   'CRM Admin',       'Masters, custom fields, user-role mapping and imports.',                                             'ALL',               1);

INSERT IGNORE INTO role_module_scope (role_id, module)
SELECT id, 'ORDERS' FROM role WHERE code = 'FINANCE';

-- Role-permission matrix (11.3 proposal; to be confirmed by the sales head, OD-01)
INSERT IGNORE INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r JOIN permission p
 WHERE r.code = 'SALES_EXEC' AND p.code IN (
   'dashboard.view','report.view','report.export',
   'task.view_own','task.create','task.update',
   'lead.view','lead.create','lead.update','lead.qualify','lead.convert','lead.disqualify','lead.export',
   'opportunity.view','opportunity.update','opportunity.move_stage','opportunity.close','opportunity.export',
   'offer.create','offer.submit','offer.send','partner_commercial.view','partner_commercial.manage',
   'account.view','account.create','account.update','contact.manage',
   'partner.view','partner_performance.view',
   'tender.view','tender.create','tender.update',
   'order.view','order.update',
   'forecast.view','forecast.submit_own','forecast.view_team','forecast.nudge',
   'winloss.view',
   'document.view','document.upload','document.delete',
   'activity.view','activity.create','activity.update_own');

INSERT IGNORE INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r JOIN permission p
 WHERE r.code = 'PRESALES' AND p.code IN (
   'dashboard.view','report.view',
   'task.view_own','task.create','task.update',
   'opportunity.view','opportunity.update','opportunity.move_stage',
   'account.view',
   'tender.view',
   'forecast.view','forecast.submit_own',
   'winloss.view',
   'document.view','document.upload','document.delete',
   'activity.view','activity.create','activity.update_own');

INSERT IGNORE INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r JOIN permission p
 WHERE r.code = 'PARTNER_MGR' AND p.code IN (
   'dashboard.view','report.view','report.export',
   'task.view_own','task.create','task.update',
   'lead.view','lead.create','lead.update','lead.qualify','lead.convert','lead.disqualify','lead.export',
   'opportunity.view',
   'partner_commercial.view','partner_commercial.manage',
   'account.view',
   'partner.view','partner.create','partner.update','partner.engagement.manage','partner.send_form','partner.review_submission',
   'partner_performance.view','partner_report.generate',
   'tender.view',
   'order.view',
   'forecast.view','forecast.submit_own',
   'winloss.view',
   'document.view','document.upload','document.delete',
   'activity.view','activity.create','activity.update_own');

INSERT IGNORE INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r JOIN permission p
 WHERE r.code = 'SALES_HEAD' AND p.code IN (
   'dashboard.view','report.view','report.export',
   'task.view_own','task.create','task.update',
   'lead.view','lead.create','lead.update','lead.qualify','lead.convert','lead.disqualify','lead.export',
   'opportunity.view','opportunity.update','opportunity.move_stage','opportunity.close','opportunity.validate',
   'opportunity.stage_override','opportunity.assign','opportunity.export',
   'offer.create','offer.submit','offer.approve','offer.send','partner_commercial.view','partner_commercial.manage',
   'account.view','account.create','account.update','contact.manage',
   'partner.view','partner.create','partner.update','partner.engagement.manage',
   'partner_performance.view','partner_report.generate',
   'tender.view','tender.create','tender.update',
   'order.view','order.update',
   'forecast.view','forecast.submit_own','forecast.view_team','forecast.nudge',
   'winloss.view',
   'document.view','document.upload','document.delete',
   'activity.view','activity.create','activity.update_own',
   'target.manage');

-- Management: *.view + export + notes (10.9); validates deals per OD-02 default
INSERT IGNORE INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r JOIN permission p
 WHERE r.code = 'MANAGEMENT' AND p.code IN (
   'dashboard.view','report.view','report.export',
   'task.view_own','task.create','task.update',
   'lead.view',
   'opportunity.view','opportunity.validate',
   'partner_commercial.view',
   'account.view',
   'partner.view','partner_performance.view',
   'tender.view',
   'order.view',
   'forecast.view','forecast.view_team',
   'winloss.view',
   'document.view',
   'activity.view','activity.create');

-- Finance: orders + read-only deal header and account (OD-11 default, MODULE_LIMITED scope)
INSERT IGNORE INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r JOIN permission p
 WHERE r.code = 'FINANCE' AND p.code IN (
   'dashboard.view','report.view','report.export',
   'task.view_own','task.create','task.update',
   'opportunity.view',
   'partner_commercial.view',
   'account.view',
   'order.view','order.update','order.finance',
   'document.view','document.upload','document.delete',
   'activity.view','activity.create','activity.update_own');

INSERT IGNORE INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r JOIN permission p
 WHERE r.code = 'CRM_ADMIN' AND p.code IN (
   'dashboard.view','report.view','report.export',
   'task.view_own','task.create','task.update',
   'lead.view','lead.create','lead.update','lead.qualify','lead.convert','lead.disqualify','lead.export',
   'opportunity.view','opportunity.update','opportunity.move_stage','opportunity.close','opportunity.assign','opportunity.export',
   'partner_commercial.view','partner_commercial.manage',
   'account.view','account.create','account.update','account.merge','contact.manage',
   'partner.view','partner.create','partner.update','partner.engagement.manage',
   'partner_performance.view','partner_performance.recompute','partner_report.generate',
   'tender.view','tender.create','tender.update',
   'order.view','order.update',
   'winloss.view',
   'document.view','document.upload','document.delete',
   'activity.view','activity.create','activity.update_own',
   'master.manage','custom_field.manage','target.manage','setting.manage','email_template.manage',
   'import.run',
   'user.view','user.manage','user.reassign_records','role.manage','audit.view');

-- -----------------------------------------------------------------------------
-- Stages (codes fixed by the application; names, confidence, SLA editable)
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO stage (entity, code, name, sequence_no, default_confidence_pct, is_open, is_won, is_lost, sla_days, colour_token) VALUES
  ('LEAD',   'NEW',               'New',                   1, NULL,   1, 0, 0, NULL, 'neutral'),
  ('LEAD',   'CONTACTED',         'Contacted',             2, NULL,   1, 0, 0, NULL, 'info'),
  ('LEAD',   'QUALIFYING',        'Qualifying',            3, NULL,   1, 0, 0, NULL, 'warning'),
  ('LEAD',   'CONVERTED',         'Converted',             4, NULL,   0, 1, 0, NULL, 'success'),
  ('LEAD',   'DISQUALIFIED',      'Disqualified',          5, NULL,   0, 0, 1, NULL, 'danger'),
  ('OPP',    'QUALIFIED',         'Qualified',             1, 20.00,  1, 0, 0, 30,   'info'),
  ('OPP',    'TECH_ENGAGEMENT',   'Technical engagement',  2, 30.00,  1, 0, 0, 30,   'info'),
  ('OPP',    'POC',               'POC',                   3, 40.00,  1, 0, 0, 45,   'info'),
  ('OPP',    'PROPOSAL',          'Proposal',              4, 50.00,  1, 0, 0, 30,   'warning'),
  ('OPP',    'NEGOTIATION',       'Negotiation',           5, 70.00,  1, 0, 0, 30,   'warning'),
  ('OPP',    'COMMERCIAL_CLOSED', 'Commercial closed',     6, 85.00,  1, 0, 0, 15,   'warning'),
  ('OPP',    'CONTRACT_SIGNED',   'Contract signed',       7, 90.00,  1, 0, 0, 30,   'success'),
  ('OPP',    'WON',               'PO received / Won',     8, 100.00, 0, 1, 0, NULL, 'success'),
  ('OPP',    'LOST',              'Lost',                  9, 0.00,   0, 0, 1, NULL, 'danger'),
  ('OPP',    'DORMANT',           'Dormant',              10, NULL,   0, 0, 0, NULL, 'neutral'),
  ('TENDER', 'IDENTIFIED',        'Identified',            1, NULL,   1, 0, 0, NULL, 'neutral'),
  ('TENDER', 'READINESS',         'Readiness',             2, NULL,   1, 0, 0, NULL, 'info'),
  ('TENDER', 'CAPTURED',          'Captured',              3, NULL,   1, 0, 0, NULL, 'info'),
  ('TENDER', 'SUBMITTED',         'Bid submitted',         4, NULL,   1, 0, 0, NULL, 'warning'),
  ('TENDER', 'TECH_QUALIFIED',    'Technical qualified',   5, NULL,   1, 0, 0, NULL, 'warning'),
  ('TENDER', 'L1_L2',             'L1 / L2',               6, NULL,   1, 0, 0, NULL, 'warning'),
  ('TENDER', 'AWARDED',           'Awarded',               7, NULL,   0, 1, 0, NULL, 'success'),
  ('TENDER', 'NOT_AWARDED',       'Not awarded',           8, NULL,   0, 0, 1, NULL, 'danger'),
  ('TENDER', 'CANCELLED',         'Cancelled',             9, NULL,   0, 0, 0, NULL, 'neutral'),
  ('ORDER',  'PO_RECEIVED',       'PO received',           1, NULL,   1, 0, 0, NULL, 'info'),
  ('ORDER',  'PO_TO_MFR',         'PO to manufacturer',    2, NULL,   1, 0, 0, NULL, 'info'),
  ('ORDER',  'GOODS_DELIVERED',   'Goods delivered',       3, NULL,   1, 0, 0, NULL, 'info'),
  ('ORDER',  'DEPLOYED',          'Deployment',            4, NULL,   1, 0, 0, NULL, 'warning'),
  ('ORDER',  'INVOICED',          'Invoice raised',        5, NULL,   1, 0, 0, NULL, 'warning'),
  ('ORDER',  'PAID',              'Payment received',      6, NULL,   1, 0, 0, NULL, 'success'),
  ('ORDER',  'CLOSED',            'Closed',                7, NULL,   0, 1, 0, NULL, 'success');

-- -----------------------------------------------------------------------------
-- Masters seeded from the User Manual (final lists: OD-44)
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO partner_type (code, name, sort_order) VALUES
  ('MSP', 'MSP', 1), ('TELCO', 'Telco', 2), ('RESELLER', 'Reseller', 3), ('VAD', 'VAD', 4),
  ('SI', 'SI', 5), ('CONSULTANT', 'Consultant', 6), ('GOVT_PSU', 'Govt/PSU partner', 7);

INSERT IGNORE INTO industry (code, name, sort_order) VALUES
  ('BFSI', 'BFSI', 1), ('GOVT', 'Govt', 2), ('RETAIL', 'Retail', 3),
  ('EDUCATION', 'Education', 4), ('HEALTHCARE', 'Healthcare', 5), ('ISP', 'ISP', 6);

INSERT IGNORE INTO product (code, name, sort_order) VALUES
  ('SDWAN', 'SD-WAN', 1), ('FIREWALL', 'Firewall', 2), ('WIFI', 'Wi-Fi', 3), ('ENDPOINT', 'Endpoint', 4);

INSERT IGNORE INTO solution (product_id, name, sort_order)
SELECT id, 'Hub-and-spoke + SIM', 1 FROM product WHERE code = 'SDWAN';

INSERT IGNORE INTO reason (reason_type, code, name, competitor_required, sort_order) VALUES
  ('WIN',        'PRICE',               'Price',                      0, 1),
  ('WIN',        'RELATIONSHIP',        'Relationship',               0, 2),
  ('WIN',        'PRODUCT_FIT',         'Product fit',                0, 3),
  ('WIN',        'PARTNER',             'Partner',                    0, 4),
  ('WIN',        'POC',                 'POC',                        0, 5),
  ('WIN',        'SPEED',               'Speed',                      0, 6),
  ('WIN',        'REFERENCE',           'Reference',                  0, 7),
  ('LOSS',       'PRICE',               'Price',                      1, 1),
  ('LOSS',       'COMPETITOR',          'Competitor',                 1, 2),
  ('LOSS',       'NO_BUDGET',           'No budget',                  0, 3),
  ('LOSS',       'REQUIREMENT_CHANGED', 'Requirement changed',        1, 4),
  ('LOSS',       'NO_DECISION',         'No decision',                0, 5),
  ('LOSS',       'PARTNER_FAILED',      'Partner failed',             1, 6),
  ('LOSS',       'TIMELINE',            'Timeline',                   1, 7),
  ('LOSS',       'OTHER',               'Other',                      1, 8),
  ('DISQUALIFY', 'NO_NEED',             'No real need',               0, 1),
  ('DISQUALIFY', 'NO_BUDGET',           'No budget',                  0, 2),
  ('DISQUALIFY', 'WRONG_FIT',           'Wrong fit',                  0, 3),
  ('DORMANT',    'NO_ACTIVITY',         'No activity for 60 days',    0, 1),
  ('DORMANT',    'CUSTOMER_PAUSED',     'Customer paused',            0, 2),
  ('NOT_VALID',  'BUDGET_MISMATCH',     'Budget far below our value', 0, 1);

INSERT IGNORE INTO competitor (name) VALUES ('Fortinet'), ('Cisco');

INSERT IGNORE INTO procurement_type (code, name, sort_order) VALUES
  ('DIRECT_PO', 'Direct PO', 1), ('RFP', 'RFP', 2), ('TENDER', 'Tender', 3), ('RATE_CONTRACT', 'Rate contract', 4);

-- Buying steps named in UM 2 ("RFP, technical evaluation, commercial bid, L1, PO")
INSERT IGNORE INTO procurement_step (procurement_type_id, sequence_no, name)
SELECT pt.id, s.seq, s.name
  FROM procurement_type pt
  JOIN (SELECT 1 AS seq, 'RFP' AS name UNION ALL SELECT 2, 'Technical evaluation'
        UNION ALL SELECT 3, 'Commercial bid' UNION ALL SELECT 4, 'L1' UNION ALL SELECT 5, 'PO') s
 WHERE pt.code IN ('RFP', 'TENDER');

INSERT IGNORE INTO document_type (code, name, sort_order) VALUES
  ('PROPOSAL', 'Proposal', 1), ('BOQ', 'BoQ', 2), ('DATASHEET', 'Datasheet', 3),
  ('COMPLIANCE', 'Compliance', 4), ('NDA', 'NDA', 5), ('CONTRACT', 'Contract / LoI', 6),
  ('PURCHASE_ORDER', 'Purchase order', 7), ('PRICE_LETTER', 'Partner price letter', 8),
  ('AGREEMENT', 'Partner agreement', 9), ('GTM_PLAN', 'GTM plan', 10), ('POC_PLAN', 'POC plan', 11),
  ('POC_READOUT', 'POC readout', 12), ('INVOICE', 'Invoice', 13), ('OTHER', 'Other', 99);

INSERT IGNORE INTO certification_type (code, name, sort_order) VALUES
  ('ISO_27001', 'ISO 27001', 1), ('ISO_9001', 'ISO 9001', 2), ('CMMI', 'CMMi', 3);

-- -----------------------------------------------------------------------------
-- Business settings (UM 10 recommended defaults; editable by the CRM Admin)
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO setting (setting_key, setting_value, value_type, min_value, max_value, allowed_values, module, description) VALUES
  ('auth.lockout.threshold',        '5',        'INT',     3,    20,          NULL, 'AUTH',        'Consecutive failed logins before the account is locked (OD-06)'),
  ('auth.lockout.minutes',          '15',       'INT',     1,    1440,        NULL, 'AUTH',        'Minutes an account stays locked before it unlocks automatically (OD-06)'),
  ('auth.password.history_count',   '5',        'INT',     0,    24,          NULL, 'AUTH',        'Number of previous passwords that cannot be reused (OD-08)'),
  ('auth.reset_token.minutes',      '30',       'INT',     5,    1440,        NULL, 'AUTH',        'Validity of a password reset link, in minutes (10.6)'),
  ('auth.invite_token.hours',       '72',       'INT',     1,    720,         NULL, 'AUTH',        'Validity of an invitation link, in hours (10.5)'),
  ('auth.idle_timeout.minutes',     '30',       'INT',     5,    480,         NULL, 'AUTH',        'Minutes without activity before the UI signs the user out (OD-07)'),
  ('offer.approval.discount_pct',   '15',       'DECIMAL', 0,    100,         NULL, 'OFFERS',      'Offers with a discount above this % need sales head approval (OD-49)'),
  ('offer.approval.value_limit',    '10000000', 'DECIMAL', 0,    99999999999, NULL, 'OFFERS',      'Offers above this value (INR) need sales head approval (OD-49)'),
  ('offer.expiry_warning_days',     '3',        'INT',     1,    30,          NULL, 'OFFERS',      'Days before a sent offer expires when the owner gets a task'),
  ('deal.stale_days',               '60',       'INT',     7,    365,         NULL, 'OPPORTUNITIES','Days without activity and status before a deal is flagged stale (OD-50)'),
  ('deal.lost_detail_min_length',   '20',       'INT',     0,    500,         NULL, 'OPPORTUNITIES','Minimum length of the loss detail when closing a deal as lost (16.3)'),
  ('weekly_status.due_day',         'FRIDAY',   'DAY',     NULL, NULL,        'MONDAY,TUESDAY,WEDNESDAY,THURSDAY,FRIDAY,SATURDAY,SUNDAY', 'FORECAST', 'Day the weekly status is due (OD-16)'),
  ('weekly_status.due_time',        '18:00',    'TIME',    NULL, NULL,        NULL, 'FORECAST',    'Time (IST) the weekly status is due (OD-16)'),
  ('report.monday.time',            '09:00',    'TIME',    NULL, NULL,        NULL, 'FORECAST',    'Time (IST) the Monday weekly status report is emailed (OD-16)'),
  ('monthly_commit.due_day',        '5',        'INT',     1,    28,          NULL, 'FORECAST',    'Day of the month by which the monthly closure commit is due (OD-16)'),
  ('invoice.due_warning_days',      '3',        'INT',     1,    30,          NULL, 'ORDERS',      'Days before an invoice due date when finance gets a task'),
  ('fiscal_year.start_month',       '4',        'INT',     1,    12,          NULL, 'GENERAL',     'First month of the fiscal year (OD-56)'),
  ('currency.default',              'INR',      'TEXT',    NULL, NULL,        NULL, 'GENERAL',     'Default currency for values (OD-51)'),
  ('file.max_size_mb',              '10',       'INT',     1,    50,          NULL, 'DOCUMENTS',   'Maximum size of one uploaded file, in MB (17.9)'),
  ('file.max_files_per_request',    '10',       'INT',     1,    20,          NULL, 'DOCUMENTS',   'Maximum number of files in one upload (17.9)'),
  ('file.allowed_extensions',       'pdf,doc,docx,xls,xlsx,ppt,pptx,png,jpg,jpeg,zip', 'LIST', NULL, NULL, 'pdf,doc,docx,xls,xlsx,ppt,pptx,png,jpg,jpeg,zip,csv,txt', 'DOCUMENTS', 'Allowed upload file types (17.9)');

-- -----------------------------------------------------------------------------
-- Email templates used by Phase 0 (authentication)
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO email_template (code, name, subject, body_html, placeholders) VALUES
  ('USER_INVITATION', 'User invitation', 'You are invited to {{appName}}',
   '<p>Hello {{fullName}},</p><p>An account has been created for you in {{appName}}. Use the button below to set your password. The link can be used once and expires in {{expiresIn}}.</p><p><a href="{{link}}" style="display:inline-block;padding:10px 20px;border-radius:999px;background:#0f766e;color:#ffffff;text-decoration:none">Set your password</a></p><p>If the button does not work, copy this address into your browser:<br>{{link}}</p><p>If you were not expecting this email, you can ignore it.</p>',
   JSON_ARRAY('appName','fullName','link','expiresIn')),
  ('PASSWORD_RESET', 'Password reset link', 'Reset your {{appName}} password',
   '<p>Hello {{fullName}},</p><p>We received a request to reset your {{appName}} password. Use the button below to choose a new one. The link can be used once and expires in {{expiresIn}}.</p><p><a href="{{link}}" style="display:inline-block;padding:10px 20px;border-radius:999px;background:#0f766e;color:#ffffff;text-decoration:none">Reset password</a></p><p>If the button does not work, copy this address into your browser:<br>{{link}}</p><p>If you did not ask for this, ignore this email. Your password stays unchanged.</p>',
   JSON_ARRAY('appName','fullName','link','expiresIn')),
  ('PASSWORD_RESET_CONFIRMATION', 'Password reset confirmation', 'Your {{appName}} password was reset',
   '<p>Hello {{fullName}},</p><p>Your {{appName}} password was reset and all your sessions were signed out.</p><p>If you did not do this, contact your CRM administrator immediately.</p>',
   JSON_ARRAY('appName','fullName')),
  ('PASSWORD_CHANGED', 'Password changed notice', 'Your {{appName}} password was changed',
   '<p>Hello {{fullName}},</p><p>Your {{appName}} password was changed. Your other sessions were signed out.</p><p>If you did not do this, contact your CRM administrator immediately.</p>',
   JSON_ARRAY('appName','fullName')),
  ('ACCOUNT_LOCKED', 'Account locked notice', 'Your {{appName}} account is temporarily locked',
   '<p>Hello {{fullName}},</p><p>Your {{appName}} account was locked after {{attempts}} unsuccessful sign-in attempts. It unlocks automatically at {{lockedUntil}} (IST), or your CRM administrator can unlock it now.</p><p>If these attempts were not made by you, tell your CRM administrator.</p>',
   JSON_ARRAY('appName','fullName','attempts','lockedUntil'));

INSERT INTO schema_version (version, description, script_name)
VALUES ('V002', 'Reference / seed data', 'V002__seed_reference_data.sql')
ON DUPLICATE KEY UPDATE applied_at = UTC_TIMESTAMP(3), applied_by = CURRENT_USER();
