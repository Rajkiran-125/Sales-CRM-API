// @ts-check
'use strict';

/**
 * While must_change_password is set, only the routes that let the user change the
 * password or leave are reachable (10.2 step 7; Orchestrator defaultPasswordEnforcement).
 */
const { appError } = require('../shared/errors');

/**
 * @param {boolean} allowed true for routes reachable during a forced password change
 * @returns {import('express').RequestHandler}
 */
function enforcePasswordChange(allowed) {
  return (req, _res, next) => {
    const user = /** @type {any} */ (req).user;
    if (!allowed && user?.mustChangePassword) {
      return next(appError('PASSWORD_CHANGE_REQUIRED', 'Change your password to continue.'));
    }
    return next();
  };
}

module.exports = enforcePasswordChange;
