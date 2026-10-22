// @ts-check
'use strict';

/** /api/v1/dashboard (12.2, 14.3): every number inside the user's data scope. */
const c = require('./dashboard.controller');
const v = require('./dashboard.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['dashboard.view'],
    summary:
      'All dashboard tiles in one call (period, KPIs, funnel, closures, sources, win / loss, partners, detail)',
    schema: v.get,
    handler: c.get,
  },
  {
    method: 'get',
    path: '/drill/:tile',
    access: ['dashboard.view'],
    summary:
      'Deals behind a tile, paged. Tiles: OPEN, STAGE, SOURCE, NEW, THIS_MONTH, COMMIT, OVERDUE, WON, LOST, LOSS_REASON, PARTNER',
    schema: v.drill,
    handler: c.drill,
  },
];
