// @ts-check
'use strict';

/**
 * /api/v1/opportunities/{id}/partners | competitors | partner-commercials (14.5, V022).
 * Mounted on /opportunities next to the opportunities module.
 */
const c = require('./dealParties.controller');
const v = require('./dealParties.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'post',
    path: '/:id/partners',
    access: ['opportunity.update'],
    summary: 'Map a partner on the deal with a role (BR-OP-12)',
    schema: v.partnerAdd,
    handler: c.partnerAdd,
  },
  {
    method: 'patch',
    path: '/:id/partners/:rowId',
    access: ['opportunity.update'],
    summary: 'Change a deal partner: role, contact, engagement, primary, notes',
    schema: v.partnerUpdate,
    handler: c.partnerUpdate,
  },
  {
    method: 'delete',
    path: '/:id/partners/:rowId',
    access: ['opportunity.update'],
    summary: 'Unmap a partner (refused when it has commercial versions)',
    schema: v.rowRemove,
    handler: c.partnerRemove,
  },
  {
    method: 'post',
    path: '/:id/competitors',
    access: ['opportunity.update'],
    summary: 'Add a competitor to the deal',
    schema: v.competitorAdd,
    handler: c.competitorAdd,
  },
  {
    method: 'patch',
    path: '/:id/competitors/:rowId',
    access: ['opportunity.update'],
    summary: 'Edit a competitor row: their price, strength, our differentiator',
    schema: v.competitorUpdate,
    handler: c.competitorUpdate,
  },
  {
    method: 'delete',
    path: '/:id/competitors/:rowId',
    access: ['opportunity.update'],
    summary: 'Remove a competitor from the deal',
    schema: v.rowRemove,
    handler: c.competitorRemove,
  },
  {
    method: 'post',
    path: '/:id/partner-commercials',
    access: ['partner_commercial.manage'],
    summary: 'Record a new partner commercial version (BR-OP-13, never overwritten)',
    schema: v.commercialCreate,
    handler: c.commercialCreate,
  },
];
