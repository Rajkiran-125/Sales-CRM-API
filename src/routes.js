// @ts-check
'use strict';

/** Registers every module's route table under /api/v1 (8.3). */
const express = require('express');
const config = require('./config');
const { buildRouter } = require('./shared/routeTable');

const authRoutes = require('./modules/auth/auth.routes');
const userRoutes = require('./modules/users/users.routes');
const {
  roles: roleRoutes,
  permissions: permissionRoutes,
} = require('./modules/roles/roles.routes');
const auditRoutes = require('./modules/audit/audit.routes');
const masterRoutes = require('./modules/masters/masters.routes');
const settingRoutes = require('./modules/settings/settings.routes');
const emailTemplateRoutes = require('./modules/email-templates/emailTemplates.routes');
const dashboardRoutes = require('./modules/dashboard/dashboard.routes');
const activityRoutes = require('./modules/activities/activities.routes');
const weeklyStatusRoutes = require('./modules/weekly-status/weekly-status.routes');
const taskRoutes = require('./modules/tasks/tasks.routes');
const leadRoutes = require('./modules/leads/leads.routes');
const opportunityRoutes = require('./modules/opportunities/opportunities.routes');
const dealPartyRoutes = require('./modules/deal-parties/dealParties.routes');
const contactRoutes = require('./modules/contacts/contacts.routes');
const accountRoutes = require('./modules/accounts/accounts.routes');
const forecastRoutes = require('./modules/forecast/forecast.routes');
const partnerRoutes = require('./modules/partners/partners.routes');
const tenderRoutes = require('./modules/tenders/tenders.routes');
const orderRoutes = require('./modules/orders/orders.routes');
const offerRoutes = require('./modules/offers/offers.routes');
const winLossRoutes = require('./modules/win-loss/winLoss.routes');
const documentRoutes = require('./modules/documents/documents.routes');
const reportRoutes = require('./modules/reports/reports.routes');
const customFieldRoutes = require('./modules/custom-fields/customFields.routes');
const targetRoutes = require('./modules/targets/targets.routes');

/** @type {Array<[string, string, import('./shared/routeTable').RouteDef[]]>} */
const MODULES = [
  ['/auth', 'Authentication', authRoutes],
  ['/users', 'Users', userRoutes],
  ['/roles', 'Roles', roleRoutes],
  ['/permissions', 'Roles', permissionRoutes],
  ['/audit-logs', 'Audit', auditRoutes.auditLogs],
  ['/security-events', 'Audit', auditRoutes.securityEvents],
  ['/record-access-logs', 'Audit', auditRoutes.recordAccessLogs],
  ['/masters', 'Masters', masterRoutes],
  ['/settings', 'Settings', settingRoutes],
  ['/email-templates', 'Email templates', emailTemplateRoutes],
  ['/dashboard', 'Dashboard', dashboardRoutes],
  ['/activities', 'Activities', activityRoutes],
  ['/weekly-status', 'WeeklyStatus', weeklyStatusRoutes],
  ['/tasks', 'My day', taskRoutes],
  ['/leads', 'Leads', leadRoutes],
  ['/opportunities', 'Opportunities', opportunityRoutes],
  ['/opportunities', 'Opportunities', dealPartyRoutes],
  ['/contacts', 'Contacts', contactRoutes],
  ['/accounts', 'Accounts', accountRoutes],
  ['/forecast', 'Forecast', forecastRoutes],
  ['/partners', 'Partners', partnerRoutes.partners],
  ['/partner-performance', 'Partner performance', partnerRoutes.performance],
  ['/tenders', 'Tenders', tenderRoutes],
  ['/orders', 'Orders', orderRoutes],
  ['/offers', 'Offers', offerRoutes],
  ['/win-loss', 'Win / loss', winLossRoutes],
  ['/documents', 'Documents', documentRoutes],
  ['/reports', 'Reports', reportRoutes],
  ['/custom-fields', 'Custom fields', customFieldRoutes],
  // Data import disabled for now (2026-10-21): restore this line and its require to re-enable.
  // ['/imports', 'Data import', require('./modules/imports/imports.routes')],
  ['/targets', 'Targets', targetRoutes],
];

function buildApiRouter() {
  const router = express.Router();
  for (const [path, tag, defs] of MODULES) {
    router.use(path, buildRouter(`${config.apiBasePath}${path}`, tag, defs));
  }
  return router;
}

module.exports = { buildApiRouter };
