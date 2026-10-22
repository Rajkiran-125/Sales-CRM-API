// @ts-check
'use strict';

/** /api/v1/contacts (12.6, V017): write side for account and partner contacts. */
const c = require('./contacts.controller');
const v = require('./contacts.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'post',
    path: '/',
    access: ['contact.manage'],
    summary: 'Create a contact at an account or partner',
    schema: v.create,
    handler: c.create,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['contact.manage'],
    summary: 'Update a contact',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'delete',
    path: '/:id',
    access: ['contact.manage'],
    summary: 'Deactivate a contact (soft-delete)',
    schema: v.deactivate,
    handler: c.deactivate,
  },
];
