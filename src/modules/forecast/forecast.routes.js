// @ts-check
'use strict';

/** /api/v1/forecast (12.10, 14.8): weekly, monthly closure (with commits), hierarchy, nudges. */
const c = require('./forecast.controller');
const v = require('./forecast.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'put',
    path: '/monthly',
    access: ['forecast.submit_own'],
    summary:
      'Save monthly closure commits (committed / best case / next month) of own or team deals',
    schema: v.monthlySave,
    handler: c.monthlySave,
  },
  {
    method: 'post',
    path: '/nudges',
    access: ['forecast.nudge'],
    summary: 'Give every team member with weekly status pending this week one task',
    schema: v.nudge,
    handler: c.nudge,
  },
  {
    method: 'get',
    path: '/weekly',
    access: ['forecast.view'],
    summary: 'Weekly status of the open deals for a week (team=true needs forecast.view_team)',
    schema: v.weekly,
    handler: c.weekly,
  },
  {
    method: 'get',
    path: '/monthly',
    access: ['forecast.view'],
    summary: 'Monthly closure: committed, best case, next month and achieved',
    schema: v.monthly,
    handler: c.monthly,
  },
  {
    method: 'get',
    path: '/hierarchy',
    access: ['forecast.view_team'],
    summary: 'Hierarchy funnel: each person with their team roll-up',
    schema: v.hierarchy,
    handler: c.hierarchy,
  },
];
