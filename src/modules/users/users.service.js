// @ts-check
'use strict';

/**
 * User administration (11.4, 10.7). Rules live in the V005 procedures: unique email,
 * reporting line without loops, at least one role, last active CRM Admin protected,
 * no self-deactivation. This service creates the link tokens, merges partial updates
 * and sends the emails after the procedures commit.
 */
const repo = require('./users.repository');
const authRepo = require('../auth/auth.repository');
const authService = require('../auth/auth.service');
const accessContext = require('../../services/accessContext.service');
const { randomToken, sha256 } = require('../../shared/crypto');
const { errors } = require('../../shared/errors');
const { offsetOf } = require('../../shared/schemas');

/** @typedef {import('../../shared/requestMeta').RequestMeta} RequestMeta */

/** @param {number} id */
async function getOrThrow(id) {
  const user = await repo.get(id);
  if (!user) throw errors.notFound('User not found.');
  return user;
}

module.exports = {
  /** @param {any} q */
  async list(q) {
    const { rows, total } = await repo.list({ ...q, offset: offsetOf(q), limit: q.pageSize });
    return { rows, meta: { page: q.page, pageSize: q.pageSize, total, sort: q.sort } };
  },

  get: getOrThrow,

  /** @param {{ search?: string, includeInactive: boolean, limit: number }} q */
  lookup: (q) => repo.lookup(q.search, q.includeInactive, q.limit),

  /**
   * Create the user in status INVITED and email the one-time invitation link.
   * @param {any} input
   * @param {RequestMeta} meta
   */
  async create(input, meta) {
    const token = randomToken();
    const created = await repo.create(input, sha256(token), meta);
    if (!created) throw new Error('sp_user_create returned no row');
    authService.sendInvitation(created, token);
    return getOrThrow(Number(created.id));
  },

  /**
   * PATCH: fields not sent keep their current value.
   * @param {number} id
   * @param {any} patch
   * @param {RequestMeta} meta
   */
  async update(id, patch, meta) {
    const current = await getOrThrow(id);
    const merged = {
      rowVersion: patch.rowVersion,
      fullName: patch.fullName ?? current.fullName,
      mobile: patch.mobile !== undefined ? patch.mobile : current.mobile,
      designation: patch.designation !== undefined ? patch.designation : current.designation,
      department: patch.department !== undefined ? patch.department : current.department,
      reportingToUserId:
        patch.reportingToUserId !== undefined ? patch.reportingToUserId : current.reportingToUserId,
      roleIds: patch.roleIds ?? current.roles.map((/** @type {any} */ r) => Number(r.id)),
    };
    const updated = await repo.update(id, merged, meta);
    accessContext.invalidate(id);
    return updated;
  },

  /**
   * @param {number} id
   * @param {{ status: 'ACTIVE' | 'INACTIVE', reason: string }} input
   * @param {RequestMeta} meta
   */
  async setStatus(id, input, meta) {
    const user = await repo.setStatus(id, input.status, input.reason, meta);
    accessContext.invalidate(id);
    return user;
  },

  /**
   * @param {number} id
   * @param {RequestMeta} meta
   */
  async unlock(id, meta) {
    const user = await repo.unlock(id, meta);
    accessContext.invalidate(id);
    return user;
  },

  /**
   * Admin reset (10.5): the user receives a reset link; the admin never sees a password.
   * @param {number} id
   * @param {RequestMeta} meta
   */
  async sendPasswordReset(id, meta) {
    const token = randomToken();
    const target = await authRepo.createLinkToken(
      { purpose: 'RESET', userId: id, tokenHash: sha256(token) },
      meta,
    );
    if (target) authService.sendResetLink(target, token);
  },

  /**
   * @param {number} id
   * @param {RequestMeta} meta
   */
  async resendInvitation(id, meta) {
    const token = randomToken();
    const target = await authRepo.createLinkToken(
      { purpose: 'INVITE', userId: id, tokenHash: sha256(token) },
      meta,
    );
    if (target) authService.sendInvitation(target, token);
  },

  /**
   * @param {number} id
   * @param {RequestMeta} meta
   */
  async revokeSessions(id, meta) {
    await repo.revokeSessions(id, meta);
    accessContext.invalidate(id);
  },
};
