// @ts-check
'use strict';

/** /api/v1/leads (12.4, 14.4): read inside the user's data scope; create/update/disqualify/convert (V011, V012). */
const c = require('./leads.controller');
const v = require('./leads.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['lead.view'],
    summary: 'Leads, with the count per stage in meta.stageCounts',
    schema: v.list,
    handler: c.list,
  },
  {
    method: 'get',
    path: '/export',
    access: ['lead.export'],
    summary: 'Export the filtered list (xlsx); logged',
    schema: v.list,
    handler: c.exportList,
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  },
  {
    method: 'post',
    path: '/',
    access: ['lead.create'],
    summary: 'Create a lead (stage NEW) with its follow-up task',
    schema: v.create,
    handler: c.create,
    successStatus: 201,
  },
  {
    method: 'get',
    path: '/:id',
    access: ['lead.view'],
    summary:
      'Lead page: facts, the six qualification facts, DMU, products, competitors, activities',
    schema: v.byId,
    handler: c.get,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['lead.update'],
    summary: 'Update a lead; advances stage NEW→QUALIFYING when a qualification field is set',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'post',
    path: '/:id/disqualify',
    access: ['lead.disqualify'],
    summary: 'Disqualify a lead with a reason (BR-LD-07)',
    schema: v.disqualify,
    handler: c.disqualify,
  },
  {
    method: 'post',
    path: '/:id/dmu',
    access: ['lead.update'],
    summary: 'Add a person to the lead DMU (qualification fact 4)',
    schema: v.dmuAdd,
    handler: c.dmuAdd,
    successStatus: 201,
  },
  {
    method: 'patch',
    path: '/:id/dmu/:dmuId',
    access: ['lead.update'],
    summary: 'Edit a person in the lead DMU',
    schema: v.dmuUpdate,
    handler: c.dmuUpdate,
  },
  {
    method: 'delete',
    path: '/:id/dmu/:dmuId',
    access: ['lead.update'],
    summary: 'Remove a person from the lead DMU',
    schema: v.dmuRemove,
    handler: c.dmuRemove,
  },
  {
    method: 'post',
    path: '/:id/convert',
    access: ['lead.convert'],
    summary: 'Convert a fully-qualified lead to an opportunity in stage QUALIFIED (BR-LD-06)',
    schema: v.convert,
    handler: c.convert,
  },
];
