// @ts-check
'use strict';

/**
 * Layer 1 (8.4): read and verify the Bearer access token.
 * Missing -> 401 UNAUTHENTICATED; expired -> 401 TOKEN_EXPIRED; invalid -> 401.
 * Tokens signed with a foreign key, issuer or audience (e.g. the Orchestrator's) fail here.
 */
const { verifyAccessToken } = require('../auth/tokens');
const { errors } = require('../shared/errors');

/** @type {import('../shared/types').Handler} */
function authenticate(req, _res, next) {
  const header = req.get('authorization') || '';
  const match = /^Bearer\s+([A-Za-z0-9._-]+)$/.exec(header);
  if (!match) return next(errors.unauthenticated());
  /** @type {any} */ (req).auth = verifyAccessToken(match[1]);
  return next();
}

module.exports = authenticate;
