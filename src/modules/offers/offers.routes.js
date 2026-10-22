// @ts-check
'use strict';

/** /api/v1/offers (14.5): offer lifecycle write side (V018). */
const c = require('./offers.controller');
const v = require('./offers.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'post',
    path: '/',
    access: ['offer.create'],
    summary: 'Create a DRAFT offer version on an opportunity',
    schema: v.create,
    handler: c.create,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['offer.create'],
    summary: 'Edit the figures of a DRAFT offer (approval need recomputed)',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'post',
    path: '/:id/submit',
    access: ['offer.submit'],
    summary: 'Submit a DRAFT offer: → PENDING_APPROVAL (if approval required) or APPROVED',
    schema: v.submit,
    handler: c.submit,
  },
  {
    method: 'post',
    path: '/:id/approve',
    access: ['offer.approve'],
    summary: 'Approve or reject a PENDING_APPROVAL offer',
    schema: v.approve,
    handler: c.approve,
  },
  {
    method: 'post',
    path: '/:id/send',
    access: ['offer.send'],
    summary: 'Send an APPROVED offer to the customer; schedules expiry task',
    schema: v.send,
    handler: c.send,
  },
  {
    method: 'post',
    path: '/:id/respond',
    access: ['offer.send'],
    summary: 'Record customer response on a SENT offer (ACCEPTED or REJECTED)',
    schema: v.respond,
    handler: c.respond,
  },
  {
    method: 'post',
    path: '/:id/revise',
    access: ['offer.create'],
    summary: 'Revise an offer: supersede current and create a new DRAFT',
    schema: v.revise,
    handler: c.revise,
  },
];
