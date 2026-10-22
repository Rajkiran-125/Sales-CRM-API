// @ts-check
'use strict';

/** /api/v1/tenders (12.8, 14.8): list, page, create / edit, status track, checklist, export. */
const c = require('./tenders.controller');
const v = require('./tenders.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['tender.view'],
    summary: 'Tenders by status with the submission countdown; counts per status in meta',
    schema: v.list,
    handler: c.list,
  },
  // fixed paths before /:id
  {
    method: 'get',
    path: '/export',
    access: ['tender.view'],
    summary: 'Export the filtered tender list (xlsx); logged',
    schema: v.list,
    handler: c.exportList,
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  },
  {
    method: 'post',
    path: '/',
    access: ['tender.create'],
    summary: 'Create a tender (UM 4.4 fields) with the default readiness checklist (OD-40)',
    schema: v.create,
    handler: c.create,
  },
  {
    method: 'get',
    path: '/:id',
    access: ['tender.view'],
    summary: 'Tender page: dates, readiness checklist, market intelligence, result, linked deal',
    schema: v.byId,
    handler: c.get,
  },
  {
    method: 'get',
    path: '/:id/edit',
    access: ['tender.update'],
    summary: 'The editable tender values with ids and the version',
    schema: v.byId,
    handler: c.editGet,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['tender.update'],
    summary: 'Edit a tender: owner, backup owner or their manager (BR-TD-04 dates)',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'post',
    path: '/:id/status-transitions',
    access: ['tender.update'],
    summary:
      'Move along the track; NOT_AWARDED needs the loss reason, AWARDED the linked deal (BR-TD-01)',
    schema: v.transition,
    handler: c.transition,
  },
  {
    method: 'post',
    path: '/:id/checklist',
    access: ['tender.update'],
    summary: 'Add a readiness checklist item; readiness % is recomputed (BR-TD-02)',
    schema: v.checklistCreate,
    handler: c.checklistSave,
  },
  {
    method: 'patch',
    path: '/:id/checklist/:itemId',
    access: ['tender.update'],
    summary: 'Tick, untick or edit a checklist item, with its document',
    schema: v.checklistUpdate,
    handler: c.checklistSave,
  },
  {
    method: 'delete',
    path: '/:id/checklist/:itemId',
    access: ['tender.update'],
    summary: 'Remove a checklist item',
    schema: v.checklistDelete,
    handler: c.checklistDelete,
  },
];
