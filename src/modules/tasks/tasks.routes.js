// @ts-check
'use strict';

/** /api/v1/tasks (12.3, 14.3): my-day read, create, update. */
const c = require('./tasks.controller');
const v = require('./tasks.validation');
const { z } = require('../../shared/schemas');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/my-day',
    access: ['task.view_own'],
    summary:
      'My day: counters, open tasks, own deals needing attention, validations and offer approvals',
    schema: { query: z.strictObject({}) },
    handler: c.myDay,
  },
  {
    method: 'post',
    path: '/',
    access: ['task.create'],
    summary: 'Create a manual task',
    schema: v.create,
    handler: c.create,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['task.update'],
    summary: 'Complete, cancel, reschedule or edit a task (own; ALL-scope users may edit any)',
    schema: v.update,
    handler: c.update,
  },
];
