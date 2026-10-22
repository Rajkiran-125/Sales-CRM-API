// @ts-check
'use strict';

/** /api/v1/roles and /api/v1/permissions (14.2, M02) */
const c = require('./roles.controller');
const v = require('./roles.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
const roles = [
  {
    method: 'get',
    path: '/',
    access: ['role.manage', 'user.manage'],
    summary: 'List roles',
    schema: v.list,
    handler: c.list,
  },
  {
    method: 'get',
    path: '/:id',
    access: ['role.manage'],
    summary: 'Get a role with its permission codes and module scopes',
    schema: v.byId,
    handler: c.get,
  },
  {
    method: 'post',
    path: '/',
    access: ['role.manage'],
    summary: 'Create a role',
    schema: v.create,
    handler: c.create,
    successStatus: 201,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['role.manage'],
    summary: 'Edit a role, its data scope and permissions',
    schema: v.update,
    handler: c.update,
  },
];

/** @type {import('../../shared/routeTable').RouteDef[]} */
const permissions = [
  {
    method: 'get',
    path: '/',
    access: ['role.manage'],
    summary: 'Permission catalogue grouped by module',
    handler: c.permissions,
  },
];

module.exports = { roles, permissions };
