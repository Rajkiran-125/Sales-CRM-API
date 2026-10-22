// @ts-check
'use strict';

/** /api/v1/auth (14.2) */
const c = require('./auth.controller');
const v = require('./auth.validation');
const { limiters } = require('../../middleware/rateLimit');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'post',
    path: '/login',
    access: 'public',
    before: [limiters.login],
    summary: 'Sign in with email and password',
    schema: v.login,
    handler: c.login,
    description:
      'Returns an access token; sets the HttpOnly refresh cookie. Failures always answer 401 INVALID_CREDENTIALS.',
  },
  {
    method: 'post',
    path: '/refresh',
    access: 'public',
    summary: 'Rotate the refresh cookie and get a new access token',
    handler: c.refresh,
  },
  {
    method: 'post',
    path: '/logout',
    access: 'authenticated',
    allowDuringPasswordChange: true,
    summary: 'Sign out of this session',
    handler: c.logout,
    successStatus: 204,
  },
  {
    method: 'post',
    path: '/logout-all',
    access: 'authenticated',
    allowDuringPasswordChange: true,
    summary: 'Sign out of every session',
    handler: c.logoutAll,
    successStatus: 204,
  },
  {
    method: 'get',
    path: '/me',
    access: 'authenticated',
    allowDuringPasswordChange: true,
    summary: 'Current user: profile, roles, permissions, data scope, session policy',
    handler: c.me,
  },
  {
    method: 'post',
    path: '/password/change',
    access: 'authenticated',
    allowDuringPasswordChange: true,
    summary: 'Change own password (other sessions are signed out)',
    schema: v.changePassword,
    handler: c.changePassword,
    successStatus: 204,
  },
  {
    method: 'post',
    path: '/password/forgot',
    access: 'public',
    before: [limiters.forgotByIp, limiters.forgotByEmail],
    summary: 'Request a password reset link (always 202)',
    schema: v.forgotPassword,
    handler: c.forgotPassword,
    successStatus: 202,
  },
  {
    method: 'post',
    path: '/password/reset/check',
    access: 'public',
    before: [limiters.token],
    summary: 'Check a reset link before showing the form',
    schema: v.checkToken,
    handler: c.checkResetToken,
  },
  {
    method: 'post',
    path: '/password/reset',
    access: 'public',
    before: [limiters.token],
    summary: 'Set a new password with a reset link',
    schema: v.useToken,
    handler: c.resetPassword,
    successStatus: 204,
  },
  {
    method: 'post',
    path: '/invitations/check',
    access: 'public',
    before: [limiters.token],
    summary: 'Check an invitation link before showing the form',
    schema: v.checkToken,
    handler: c.checkInvitation,
  },
  {
    method: 'post',
    path: '/invitations/accept',
    access: 'public',
    before: [limiters.token],
    summary: 'Accept an invitation and set the first password',
    schema: v.useToken,
    handler: c.acceptInvitation,
    successStatus: 204,
  },
  {
    method: 'get',
    path: '/sessions',
    access: 'authenticated',
    summary: 'My active sessions',
    handler: c.sessions,
  },
  {
    method: 'delete',
    path: '/sessions/:id',
    access: 'authenticated',
    summary: 'End one of my sessions',
    schema: v.sessionParam,
    handler: c.revokeSession,
    successStatus: 204,
  },
];
