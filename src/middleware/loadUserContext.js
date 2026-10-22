// @ts-check
'use strict';

/**
 * Layer 2 (8.4): load the user context (cached) and reject the request when the account
 * is no longer active or the token was issued before a "log out everywhere", password
 * change or deactivation (token version). Fails CLOSED with 503 when the database cannot
 * be reached.
 */
const accessContext = require('../services/accessContext.service');
const requestContext = require('../config/requestContext');
const { AppError, appError, errors } = require('../shared/errors');

/** @type {import('../shared/types').Handler} */
async function loadUserContext(req, _res, next) {
  const r = /** @type {any} */ (req);
  let ctx;
  try {
    ctx = await accessContext.getUserContext(r.auth.userId);
  } catch (err) {
    if (err instanceof AppError && err.status < 500) throw err;
    throw errors.serviceUnavailable('Authentication service temporarily unavailable.');
  }

  if (!ctx) throw errors.unauthenticated('Session ended. Please sign in again.');
  if (ctx.tokenVersion !== r.auth.tokenVersion) {
    throw errors.unauthenticated('Session ended. Please sign in again.');
  }
  if (!ctx.isActive) {
    throw appError(
      'ACCOUNT_INACTIVE',
      'Your account is not active. Contact your CRM administrator.',
    );
  }

  r.user = ctx;
  const store = requestContext.current();
  if (store) store.userId = ctx.id;
  next();
}

module.exports = loadUserContext;
