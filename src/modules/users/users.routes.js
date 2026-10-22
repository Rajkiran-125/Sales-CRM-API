// @ts-check
'use strict';

/** /api/v1/users (14.2, M02) */
const c = require('./users.controller');
const v = require('./users.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['user.view'],
    summary: 'List users',
    schema: v.list,
    handler: c.list,
  },
  {
    method: 'get',
    path: '/lookup',
    access: 'authenticated',
    summary: 'Find users for owner / manager pickers',
    schema: v.lookup,
    handler: c.lookup,
  },
  {
    method: 'get',
    path: '/:id',
    access: ['user.view'],
    summary: 'Get a user',
    schema: v.byId,
    handler: c.get,
  },
  {
    method: 'post',
    path: '/',
    access: ['user.manage'],
    summary: 'Invite a user (status INVITED)',
    schema: v.create,
    handler: c.create,
    successStatus: 201,
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['user.manage'],
    summary: 'Edit profile, reporting manager and roles',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'post',
    path: '/:id/status',
    access: ['user.manage'],
    summary: 'Activate or deactivate a user, with a reason',
    schema: v.status,
    handler: c.setStatus,
  },
  {
    method: 'post',
    path: '/:id/unlock',
    access: ['user.manage'],
    summary: 'Unlock a locked account',
    schema: v.byId,
    handler: c.unlock,
  },
  {
    method: 'post',
    path: '/:id/password-reset',
    access: ['user.manage'],
    summary: 'Email the user a password reset link',
    schema: v.byId,
    handler: c.passwordReset,
    successStatus: 204,
  },
  {
    method: 'post',
    path: '/:id/invitation',
    access: ['user.manage'],
    summary: 'Resend the invitation link',
    schema: v.byId,
    handler: c.invitation,
    successStatus: 204,
  },
  {
    method: 'post',
    path: '/:id/sessions/revoke',
    access: ['user.manage'],
    summary: 'Sign the user out everywhere',
    schema: v.byId,
    handler: c.revokeSessions,
    successStatus: 204,
  },
];
