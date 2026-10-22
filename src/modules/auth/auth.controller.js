// @ts-check
'use strict';

const config = require('../../config');
const service = require('./auth.service');
const {
  setRefreshCookie,
  clearRefreshCookie,
  readRefreshCookie,
} = require('../../auth/refreshCookie');
const { requestMeta } = require('../../shared/requestMeta');
const { sendData, sendNoContent } = require('../../shared/response');
const { errors } = require('../../shared/errors');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

/**
 * CSRF defence on the cookie-authenticated refresh endpoint (10.4): SameSite=Strict plus
 * an Origin check when the browser sends one.
 * @param {import('express').Request} req
 */
function assertTrustedOrigin(req) {
  const origin = req.get('origin');
  if (!origin) return;
  const allowed = new Set([...config.corsOrigins, new URL(config.uiBaseUrl).origin]);
  if (!allowed.has(origin)) throw errors.forbidden('Request origin not allowed.');
}

/** @param {{ accessToken: string, expiresIn: number, tokenType: string, mustChangePassword: boolean }} t */
const tokenBody = (t) => ({
  accessToken: t.accessToken,
  expiresIn: t.expiresIn,
  tokenType: t.tokenType,
  mustChangePassword: t.mustChangePassword,
});

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async login(req, res) {
    const r = /** @type {Req} */ (req);
    const result = await service.login(r.valid.body, requestMeta(req));
    setRefreshCookie(res, result.refreshToken, result.sessionExpiresAt);
    sendData(req, res, tokenBody(result));
  },

  /** @type {import('../../shared/types').Handler} */
  async refresh(req, res) {
    assertTrustedOrigin(req);
    try {
      const result = await service.refresh(readRefreshCookie(req), requestMeta(req));
      setRefreshCookie(res, result.refreshToken, result.sessionExpiresAt);
      sendData(req, res, tokenBody(result));
    } catch (err) {
      if (/** @type {any} */ (err).status === 401) clearRefreshCookie(res);
      throw err;
    }
  },

  /** @type {import('../../shared/types').Handler} */
  async logout(req, res) {
    const r = /** @type {Req} */ (req);
    await service.logout(r.user, readRefreshCookie(req), requestMeta(req));
    clearRefreshCookie(res);
    sendNoContent(res);
  },

  /** @type {import('../../shared/types').Handler} */
  async logoutAll(req, res) {
    const r = /** @type {Req} */ (req);
    await service.logoutAll(r.user, requestMeta(req));
    clearRefreshCookie(res);
    sendNoContent(res);
  },

  /** @type {import('../../shared/types').Handler} */
  async me(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.me(r.user));
  },

  /** @type {import('../../shared/types').Handler} */
  async changePassword(req, res) {
    const r = /** @type {Req} */ (req);
    await service.changePassword(r.user, r.valid.body, readRefreshCookie(req), requestMeta(req));
    sendNoContent(res);
  },

  /** @type {import('../../shared/types').Handler} */
  async forgotPassword(req, res) {
    const r = /** @type {Req} */ (req);
    await service.forgotPassword(r.valid.body.email, requestMeta(req));
    sendData(req, res, { message: 'If the account exists, a reset link has been sent.' }, 202);
  },

  /** @type {import('../../shared/types').Handler} */
  async checkResetToken(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.checkLink(r.valid.body.token, 'RESET'));
  },

  /** @type {import('../../shared/types').Handler} */
  async resetPassword(req, res) {
    const r = /** @type {Req} */ (req);
    await service.useLink(r.valid.body.token, 'RESET', r.valid.body.newPassword, requestMeta(req));
    sendNoContent(res);
  },

  /** @type {import('../../shared/types').Handler} */
  async checkInvitation(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.checkLink(r.valid.body.token, 'INVITE'));
  },

  /** @type {import('../../shared/types').Handler} */
  async acceptInvitation(req, res) {
    const r = /** @type {Req} */ (req);
    await service.useLink(r.valid.body.token, 'INVITE', r.valid.body.newPassword, requestMeta(req));
    sendNoContent(res);
  },

  /** @type {import('../../shared/types').Handler} */
  async sessions(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.sessions(r.user, readRefreshCookie(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async revokeSession(req, res) {
    const r = /** @type {Req} */ (req);
    await service.revokeSession(r.user, r.valid.params.id, requestMeta(req));
    sendNoContent(res);
  },
};
