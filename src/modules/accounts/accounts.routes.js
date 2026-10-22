// @ts-check
'use strict';

/** /api/v1/accounts (12.6, 14.6): accounts visible under 10.8 rule 4; create / edit (V020). */
const c = require('./accounts.controller');
const v = require('./accounts.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['account.view'],
    summary: 'Accounts with open pipeline and won value from the visible deals',
    schema: v.list,
    handler: c.list,
  },
  {
    method: 'get',
    path: '/:id/360',
    access: ['account.view'],
    summary: 'Account 360: KPIs, contacts, deals, orders, partners involved, activities',
    schema: v.byId,
    handler: c.get360,
  },
  {
    method: 'post',
    path: '/',
    access: ['account.create'],
    summary: 'Create an account (duplicate warning by name / GST / website, BR-AC-02)',
    schema: v.create,
    handler: c.create,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['account.update'],
    summary: 'Edit an account: owner, backup owner or their manager (BR-AC-01)',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'get',
    path: '/export',
    access: ['report.export'],
    summary: 'Export the filtered account list (xlsx); also needs account.view; logged',
    schema: v.list,
    handler: c.exportList,
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  },
  {
    method: 'post',
    path: '/:id/merge',
    access: ['account.merge'],
    summary: 'Merge a duplicate into the surviving account: its records move, it is retired',
    schema: v.merge,
    handler: c.merge,
  },
];
