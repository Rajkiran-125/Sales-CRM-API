// @ts-check
'use strict';

/** User administration data access (V005 procedures). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} RequestMeta */

/** @param {RequestMeta} m */
const ctx = (m) => [m.actorUserId, m.requestId, m.ip];

/**
 * @param {Array<Array<Record<string, any>>>} sets
 * @returns {Record<string, any> | null}
 */
function userWithRoles(sets) {
  const [users, roles] = sets;
  const user = users?.[0];
  return user ? { ...user, roles: roles ?? [] } : null;
}

module.exports = {
  /**
   * @param {{ search?: string, status?: string, roleId?: number, managerId?: number, sort: string, offset: number, limit: number }} q
   */
  async list(q) {
    const [rows, totals] = await callProcedure('sp_user_list', [
      q.search ?? null,
      q.status ?? null,
      q.roleId ?? null,
      q.managerId ?? null,
      q.sort,
      q.offset,
      q.limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0) };
  },

  /** @param {number} id */
  get: async (id) => userWithRoles(await callProcedure('sp_user_get', [id])),

  /**
   * @param {string | undefined} search
   * @param {boolean} includeInactive
   * @param {number} limit
   */
  lookup: async (search, includeInactive, limit) =>
    (await callProcedure('sp_user_lookup', [search ?? null, includeInactive ? 1 : 0, limit]))[0] ??
    [],

  /**
   * @param {{ email: string, fullName: string, mobile: string | null, designation: string | null, department: string | null, reportingToUserId: number | null, roleIds: number[] }} u
   * @param {string} inviteHash
   * @param {RequestMeta} meta
   */
  create: (u, inviteHash, meta) =>
    callProcedureOne('sp_user_create', [
      ...ctx(meta),
      u.email,
      u.fullName,
      u.mobile,
      u.designation,
      u.department,
      u.reportingToUserId,
      JSON.stringify(u.roleIds),
      inviteHash,
    ]),

  /**
   * @param {number} id
   * @param {{ rowVersion: number, fullName: string, mobile: string | null, designation: string | null, department: string | null, reportingToUserId: number | null, roleIds: number[] }} u
   * @param {RequestMeta} meta
   */
  update: async (id, u, meta) =>
    userWithRoles(
      await callProcedure('sp_user_update', [
        ...ctx(meta),
        id,
        u.rowVersion,
        u.fullName,
        u.mobile,
        u.designation,
        u.department,
        u.reportingToUserId,
        JSON.stringify(u.roleIds),
      ]),
    ),

  /**
   * @param {number} id
   * @param {'ACTIVE' | 'INACTIVE'} status
   * @param {string} reason
   * @param {RequestMeta} meta
   */
  setStatus: async (id, status, reason, meta) =>
    userWithRoles(await callProcedure('sp_user_set_status', [...ctx(meta), id, status, reason])),

  /**
   * @param {number} id
   * @param {RequestMeta} meta
   */
  unlock: async (id, meta) =>
    userWithRoles(await callProcedure('sp_user_unlock', [...ctx(meta), id])),

  /**
   * @param {number} id
   * @param {RequestMeta} meta
   */
  revokeSessions: (id, meta) => callProcedure('sp_user_revoke_sessions', [...ctx(meta), id]),
};
