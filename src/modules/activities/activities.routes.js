// @ts-check
'use strict';

/** /api/v1/activities (12.20, 14.3): create, update, delete. */
const c = require('./activities.controller');
const v = require('./activities.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'post',
    path: '/',
    access: ['activity.create'],
    summary: 'Log a call, meeting, email, visit, demo, note or intel note on a CRM entity',
    schema: v.create,
    handler: c.create,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['activity.update_own'],
    summary: 'Edit an activity (own; ALL-scope users may edit any)',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'delete',
    path: '/:id',
    access: ['activity.update_own'],
    summary: 'Soft-delete an activity (own; ALL-scope users may delete any)',
    schema: v.delete,
    handler: c.del,
  },
];
