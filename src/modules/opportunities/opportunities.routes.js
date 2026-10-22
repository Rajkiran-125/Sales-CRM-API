// @ts-check
'use strict';

/** /api/v1/opportunities (12.5, 14.5): read + write (V008, V013). */
const c = require('./opportunities.controller');
const v = require('./opportunities.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['opportunity.view'],
    summary:
      'Deals by view (open / won / lost / dormant / all), with the counts per view in meta.counts',
    schema: v.list,
    handler: c.list,
  },
  {
    method: 'get',
    path: '/export',
    access: ['opportunity.export'],
    summary: 'Export the filtered list (xlsx); logged',
    schema: v.list,
    handler: c.exportList,
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  },
  {
    method: 'get',
    path: '/kanban',
    access: ['opportunity.view'],
    summary: 'Open deals by stage: column totals and up to 50 cards per column',
    schema: v.kanban,
    handler: c.kanban,
  },
  {
    method: 'get',
    path: '/:id',
    access: ['opportunity.view'],
    summary:
      'Deal workspace: header, DMU, partners, competition, POC, offers, partner commercial, activities, status, history',
    schema: v.byId,
    handler: c.get,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['opportunity.update'],
    summary: 'Update opportunity core fields (title, value, close date, owners, products, etc.)',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'post',
    path: '/:id/move-stage',
    access: ['opportunity.move_stage'],
    summary:
      'Move one stage forward with the gate met (16.3); other moves and gate overrides need opportunity.stage_override and a reason',
    schema: v.moveStage,
    handler: c.moveStage,
  },
  {
    method: 'get',
    path: '/:id/gate',
    access: ['opportunity.view'],
    summary: 'The next stage and the gate items still missing (16.3)',
    schema: v.byId,
    handler: c.gate,
  },
  {
    method: 'get',
    path: '/:id/poc',
    access: ['opportunity.view'],
    summary: 'The POC details of the deal with ids, for editing (12.5.4)',
    schema: v.byId,
    handler: c.pocGet,
  },
  {
    method: 'put',
    path: '/:id/poc',
    access: ['opportunity.update'],
    summary: 'Save the POC details of the deal, or mark the POC skipped with a reason (12.5.4)',
    schema: v.poc,
    handler: c.poc,
  },
  {
    method: 'post',
    path: '/:id/validate',
    access: ['opportunity.validate'],
    summary: 'Mark opportunity VALID or NOT_VALID (BR-OP-06)',
    schema: v.validate,
    handler: c.validate,
  },
  {
    method: 'post',
    path: '/:id/close',
    access: ['opportunity.close'],
    summary: 'Close opportunity as WON (with PO), LOST (with reasons) or DORMANT (BR-OP-05)',
    schema: v.close,
    handler: c.close,
  },
  {
    method: 'post',
    path: '/:id/dmu',
    access: ['opportunity.update'],
    summary: 'Add or update a contact in the deal DMU (idempotent on contact + role)',
    schema: v.dmuUpsert,
    handler: c.dmuUpsert,
  },
  {
    method: 'delete',
    path: '/:id/dmu/:dmuId',
    access: ['opportunity.update'],
    summary: 'Remove a DMU entry from a deal',
    schema: v.dmuRemove,
    handler: c.dmuRemove,
  },
];
