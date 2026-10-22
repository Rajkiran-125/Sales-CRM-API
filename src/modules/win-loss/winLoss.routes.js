// @ts-check
'use strict';

/** /api/v1/win-loss (12.12, 14.10), read side: the visible deals closed in a fiscal period. */
const c = require('./winLoss.controller');
const v = require('./winLoss.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/export',
    access: ['winloss.view'],
    summary: 'Export the closed deals of the filters (xlsx); logged',
    schema: v.export,
    handler: c.exportDeals,
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  },
  {
    method: 'get',
    path: '/summary',
    access: ['winloss.view'],
    summary: 'Win rate, monthly trend, loss reasons, competitors who beat us, win reasons, lessons',
    schema: v.summary,
    handler: c.summary,
  },
  {
    method: 'get',
    path: '/deals',
    access: ['winloss.view'],
    summary: 'The closed deals of the period with their reasons and competitor',
    schema: v.deals,
    handler: c.deals,
  },
];
