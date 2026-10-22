// @ts-check
'use strict';

/** /api/v1/reports (19.1): the catalogue, the REVENUE_GM / PRODUCT_MIX screens, Excel exports. */
const c = require('./reports.controller');
const v = require('./reports.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['report.view'],
    summary: 'The reports catalogue (19.1): the reports this user may open, with their screen',
    schema: {},
    handler: c.catalogue,
  },
  {
    method: 'get',
    path: '/:code/export',
    access: ['report.export'],
    summary:
      "A report as Excel with its screen's figures and scope; also needs the report's view permission",
    schema: v.export,
    handler: c.exportReport,
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  },
  {
    method: 'get',
    path: '/:code',
    access: ['report.view'],
    summary: 'REVENUE_GM (by product, partner, industry or month) or PRODUCT_MIX',
    schema: v.byCode,
    handler: c.get,
  },
];
