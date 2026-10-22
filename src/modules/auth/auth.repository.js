// @ts-check
'use strict';

/** Authentication data access: thin wrappers around the V004 stored procedures. */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} RequestMeta */

module.exports = {
  /** @param {string} email */
  getLoginUser: (email) => callProcedureOne('sp_auth_get_login_user', [email]),

  /**
   * @param {{ email: string, passwordOk: boolean, refreshHash: string, familyId: string, ttlMinutes: number }} a
   * @param {RequestMeta} meta
   */
  login: (a, meta) =>
    callProcedureOne('sp_auth_login', [
      a.email,
      a.passwordOk ? 1 : 0,
      a.refreshHash,
      a.familyId,
      a.ttlMinutes,
      meta.ip,
      meta.userAgent,
      meta.requestId,
    ]),

  /**
   * @param {string} oldHash
   * @param {string} newHash
   * @param {RequestMeta} meta
   */
  refresh: (oldHash, newHash, meta) =>
    callProcedureOne('sp_auth_refresh', [
      oldHash,
      newHash,
      meta.ip,
      meta.userAgent,
      meta.requestId,
    ]),

  /**
   * @param {number} userId
   * @param {string | null} refreshHash
   * @param {RequestMeta} meta
   */
  logout: (userId, refreshHash, meta) =>
    callProcedure('sp_auth_logout', [userId, refreshHash, meta.ip, meta.userAgent, meta.requestId]),

  /**
   * @param {number} userId
   * @param {RequestMeta} meta
   */
  logoutAll: (userId, meta) =>
    callProcedure('sp_auth_logout_all', [userId, meta.ip, meta.userAgent, meta.requestId]),

  /**
   * @param {number} userId
   * @param {string | null} currentHash
   */
  sessions: async (userId, currentHash) =>
    (await callProcedure('sp_auth_sessions_list', [userId, currentHash]))[0] ?? [],

  /**
   * @param {number} userId
   * @param {string} familyId
   * @param {RequestMeta} meta
   */
  revokeSession: (userId, familyId, meta) =>
    callProcedure('sp_auth_session_revoke', [
      userId,
      familyId,
      meta.ip,
      meta.userAgent,
      meta.requestId,
    ]),

  /**
   * @param {number} userId
   * @returns {Promise<{ user: Record<string, any> | null, hashes: Array<{ passwordHash: string, kind: string }> }>}
   */
  passwordHashes: async (userId) => {
    const [users, hashes] = await callProcedure('sp_auth_password_hashes', [userId]);
    return { user: users?.[0] ?? null, hashes: /** @type {any} */ (hashes ?? []) };
  },

  /**
   * @param {number} userId
   * @param {string} newHash
   * @param {string | null} keepRefreshHash
   * @param {RequestMeta} meta
   */
  changePassword: (userId, newHash, keepRefreshHash, meta) =>
    callProcedureOne('sp_auth_password_change', [
      userId,
      newHash,
      keepRefreshHash,
      meta.ip,
      meta.userAgent,
      meta.requestId,
    ]),

  /**
   * @param {{ purpose: 'RESET' | 'INVITE', email?: string | null, userId?: number | null, tokenHash: string }} a
   * @param {RequestMeta} meta  meta.actorUserId is set for admin actions
   */
  createLinkToken: (a, meta) =>
    callProcedureOne('sp_auth_link_token_create', [
      a.purpose,
      a.email ?? null,
      a.userId ?? null,
      a.tokenHash,
      meta.actorUserId,
      meta.ip,
      meta.requestId,
    ]),

  /**
   * @param {string} tokenHash
   * @param {'RESET' | 'INVITE'} purpose
   */
  peekLinkToken: (tokenHash, purpose) =>
    callProcedureOne('sp_auth_link_token_peek', [tokenHash, purpose]),

  /**
   * @param {string} tokenHash
   * @param {'RESET' | 'INVITE'} purpose
   * @param {string} newHash
   * @param {RequestMeta} meta
   */
  consumeLinkToken: (tokenHash, purpose, newHash, meta) =>
    callProcedureOne('sp_auth_link_token_consume', [
      tokenHash,
      purpose,
      newHash,
      meta.ip,
      meta.userAgent,
      meta.requestId,
    ]),

  /** @param {string[]} keys */
  settingValues: async (keys) =>
    (await callProcedure('sp_setting_values', [JSON.stringify(keys)]))[0] ?? [],
};
