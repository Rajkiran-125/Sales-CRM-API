// @ts-check
'use strict';

/** /api/v1/weekly-status (12.21): upsert and delete. */
const c = require('./weekly-status.controller');
const v = require('./weekly-status.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'post',
    path: '/',
    access: ['forecast.submit_own'],
    summary: 'Submit or update the weekly status for a deal (upsert by opportunity + week)',
    schema: v.upsert,
    handler: c.upsert,
  },
  {
    method: 'delete',
    path: '/:id',
    access: ['forecast.submit_own'],
    summary: 'Delete a weekly status entry (own; ALL-scope users may delete any)',
    schema: v.delete,
    handler: c.del,
  },
];
