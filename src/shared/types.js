// @ts-check
'use strict';

/**
 * Shared JSDoc types.
 *
 * Express 5 types declare a handler's return value as `unknown`; with checkJs that makes
 * every handler that returns nothing an error, so handlers use this type instead (it is
 * assignable to Express's RequestHandler; Express 5 forwards rejected promises to next()).
 *
 * @typedef {(req: import('express').Request, res: import('express').Response, next: import('express').NextFunction) => void | Promise<void>} Handler
 */

module.exports = {};
