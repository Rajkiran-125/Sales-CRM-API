// @ts-check
'use strict';

/**
 * Refresh-token cookie (10.4): HttpOnly; Secure; SameSite=Strict; Path=/api/v1/auth.
 * The cookie name is CRM-specific and never the Orchestrator's (10.14).
 */
const config = require('../config');

const COOKIE_PATH = `${config.apiBasePath}/auth`;

/**
 * @param {import('express').Response} res
 * @param {string} token
 * @param {Date} expiresAt absolute end of the session
 */
function setRefreshCookie(res, token, expiresAt) {
  res.cookie(config.auth.refreshCookieName, token, {
    httpOnly: true,
    secure: config.auth.refreshCookieSecure,
    sameSite: 'strict',
    path: COOKIE_PATH,
    expires: expiresAt,
  });
}

/** @param {import('express').Response} res */
function clearRefreshCookie(res) {
  res.clearCookie(config.auth.refreshCookieName, {
    httpOnly: true,
    secure: config.auth.refreshCookieSecure,
    sameSite: 'strict',
    path: COOKIE_PATH,
  });
}

/**
 * @param {import('express').Request} req
 * @returns {string | null}
 */
function readRefreshCookie(req) {
  const value = /** @type {any} */ (req).cookies?.[config.auth.refreshCookieName];
  return typeof value === 'string' && value.length >= 20 && value.length <= 200 ? value : null;
}

module.exports = { setRefreshCookie, clearRefreshCookie, readRefreshCookie, COOKIE_PATH };
