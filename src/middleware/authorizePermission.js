// @ts-check
'use strict';

/**
 * Layer 3 (8.5): permission check declared on every business route. The user needs ANY
 * of the given codes. A denial returns 403 FORBIDDEN and is written to the security log
 * as ACCESS_DENIED with the permission and endpoint (10.12).
 */
const logger = require('../config/logger');
const { callProcedure } = require('../db/pool');
const { errors } = require('../shared/errors');
const { requestMeta } = require('../shared/requestMeta');

/**
 * @param {...string} codes
 * @returns {import('express').RequestHandler}
 */
function authorizePermission(...codes) {
  if (!codes.length) throw new Error('authorizePermission needs at least one permission code');

  return async (req, _res, next) => {
    const user = /** @type {any} */ (req).user;
    if (user && codes.some((code) => user.permissions.has(code))) return next();

    const meta = requestMeta(req);
    try {
      await callProcedure('sp_security_event_write', [
        'ACCESS_DENIED',
        user ? user.id : null,
        null,
        meta.ip,
        meta.userAgent,
        meta.requestId,
        JSON.stringify({ permissions: codes, method: req.method, path: req.baseUrl + req.path }),
      ]);
    } catch (err) {
      logger.error(`Could not record ACCESS_DENIED: ${/** @type {Error} */ (err).message}`);
    }
    return next(errors.forbidden());
  };
}

module.exports = authorizePermission;
