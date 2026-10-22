// @ts-check
'use strict';

/** /api/v1/custom-fields (12.15): definitions (CRM Admin) and the values of a record. */
const c = require('./customFields.controller');
const v = require('./customFields.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: 'authenticated',
    summary: 'Custom field definitions of an entity (forms render them)',
    schema: v.list,
    handler: c.list,
  },
  {
    method: 'post',
    path: '/',
    access: ['custom_field.manage'],
    summary: 'Add a custom field: entity, key and type are fixed after creation',
    schema: v.create,
    handler: c.create,
  },
  // fixed path before /:id
  {
    method: 'get',
    path: '/values',
    // any record view permission; the procedure checks that the record is visible
    access: [
      'partner.view',
      'account.view',
      'lead.view',
      'opportunity.view',
      'tender.view',
      'contact.manage',
    ],
    summary: 'The custom field values of a visible record',
    schema: v.valuesGet,
    handler: c.values,
  },
  {
    method: 'put',
    path: '/values',
    // any update permission here; the controller checks the one of the entity sent
    access: [
      'partner.update',
      'account.update',
      'contact.manage',
      'lead.update',
      'opportunity.update',
      'tender.update',
    ],
    summary: 'Save custom field values of a record (the entity update permission applies)',
    description:
      'Mandatory fields of the section sent (or of the entity) must be filled (BR-PT-06).',
    schema: v.valuesSave,
    handler: c.saveValues,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['custom_field.manage'],
    summary: 'Change a custom field: label, section, options, mandatory, order, help, active',
    schema: v.update,
    handler: c.update,
  },
];
