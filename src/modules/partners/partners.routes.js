// @ts-check
'use strict';

/**
 * /api/v1/partners (12.7, 14.7) and /api/v1/partner-performance (12.11, 14.8), read side:
 * partners whose relationship owner or backup is in the user's tree (all for ALL scope).
 */
const c = require('./partners.controller');
const v = require('./partners.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
const partners = [
  {
    method: 'get',
    path: '/',
    access: ['partner.view'],
    summary: 'My partners, with this fiscal year scorecard figures',
    schema: v.list,
    handler: c.list,
  },
  // fixed paths before /:id
  {
    method: 'get',
    path: '/duplicates',
    access: ['partner.view', 'partner.create'],
    summary: 'Partners with the same name, GST or website, with their owner (BR-PT-02)',
    schema: v.duplicates,
    handler: c.duplicates,
  },
  {
    method: 'get',
    path: '/export',
    access: ['report.export'],
    summary: 'Export the filtered partner list (xlsx); also needs partner.view; logged',
    schema: v.list,
    handler: c.exportList,
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  },
  {
    method: 'post',
    path: '/',
    access: ['partner.create'],
    summary: 'Create a partner with the minimum fields: name, country, type, owner (BR-PT-01)',
    description:
      'A partner with the same name, GST number or website → 409 DUPLICATE unless confirmDuplicate is true (BR-PT-02).',
    schema: v.create,
    handler: c.create,
  },
  {
    method: 'post',
    path: '/:id/engagements',
    access: ['partner.engagement.manage'],
    summary: 'Log an engagement; a dated next action plans the next one as a task (BR-PT-05)',
    schema: v.engagementCreate,
    handler: c.engagementSave,
  },
  {
    method: 'patch',
    path: '/:id/engagements/:engagementId',
    access: ['partner.engagement.manage'],
    summary: 'Edit an engagement: your own, or as the owner / manager',
    schema: v.engagementUpdate,
    handler: c.engagementSave,
  },
  {
    method: 'post',
    path: '/:id/account-map',
    access: ['partner.update'],
    summary: 'Map an account to the partner for a half-year plan',
    schema: v.accountMapCreate,
    handler: c.accountMapSave,
  },
  {
    method: 'patch',
    path: '/:id/account-map/:rowId',
    access: ['partner.update'],
    summary: 'Change a mapped account: period, status, notes',
    schema: v.accountMapUpdate,
    handler: c.accountMapSave,
  },
  {
    method: 'delete',
    path: '/:id/account-map/:rowId',
    access: ['partner.update'],
    summary: 'Remove a mapped account',
    schema: v.accountMapDelete,
    handler: c.accountMapDelete,
  },
  {
    method: 'post',
    path: '/:id/customer-codes',
    access: ['partner.update'],
    summary: 'Add the code the partner uses at a customer ("partner code at customers")',
    schema: v.customerCodeCreate,
    handler: c.customerCodeSave,
  },
  {
    method: 'patch',
    path: '/:id/customer-codes/:codeId',
    access: ['partner.update'],
    summary: 'Change a partner code at a customer',
    schema: v.customerCodeUpdate,
    handler: c.customerCodeSave,
  },
  {
    method: 'delete',
    path: '/:id/customer-codes/:codeId',
    access: ['partner.update'],
    summary: 'Remove a partner code at a customer',
    schema: v.customerCodeDelete,
    handler: c.customerCodeDelete,
  },
  {
    method: 'post',
    path: '/:id/quarterly-reports',
    access: ['partner_report.generate'],
    summary: 'Generate the Partner Quarterly Report PDF; stored as a document of the partner',
    schema: v.quarterlyReport,
    handler: c.quarterlyReport,
  },
  {
    method: 'get',
    path: '/:id/quarterly-reports',
    access: ['partner_performance.view'],
    summary: 'The stored quarterly reports of the partner (download through /documents)',
    schema: v.byId,
    handler: c.quarterlyReports,
  },
  {
    method: 'get',
    path: '/:id/edit',
    access: ['partner.update'],
    summary: 'The editable Partner Master values with ids',
    schema: v.byId,
    handler: c.editGet,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['partner.update'],
    summary: 'Save one Partner Master section: ENTITY, TYPE, INDUSTRY or ENGAGEMENT',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'get',
    path: '/:id',
    access: ['partner.view'],
    summary:
      'Partner workspace: the five sections, contacts, scorecard, deals, engagements, account map',
    schema: v.byId,
    handler: c.get,
  },
];

/** @type {import('../../shared/routeTable').RouteDef[]} */
const performance = [
  {
    method: 'post',
    path: '/recompute',
    access: ['partner_performance.recompute'],
    summary:
      'Recompute partner performance now (the nightly job): quarter snapshots and current values',
    schema: {},
    handler: c.recompute,
  },
  {
    method: 'get',
    path: '/',
    access: ['partner_performance.view'],
    summary: 'Partner scorecards for a fiscal quarter or year (weighted score, D-50)',
    schema: v.performance,
    handler: c.performance,
  },
  {
    method: 'get',
    path: '/:partnerId',
    access: ['partner_performance.view'],
    summary: "One partner's period detail: loss reasons, deals and engagements",
    schema: v.performanceOne,
    handler: c.performanceOne,
  },
];

module.exports = { partners, performance };
