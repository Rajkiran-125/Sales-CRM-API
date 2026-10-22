// @ts-check
'use strict';

/** Roles and permission catalogue (V005 procedures). */
const { callProcedure } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} RequestMeta */

/**
 * @param {Array<Array<Record<string, any>>>} sets
 * @returns {Record<string, any> | null}
 */
function roleDetail(sets) {
  const [roles, permissions, modules] = sets;
  const role = roles?.[0];
  if (!role) return null;
  return {
    ...role,
    permissionCodes: (permissions ?? []).map((p) => p.code),
    moduleScopes: (modules ?? []).map((m) => m.module),
  };
}

module.exports = {
  /** @param {boolean} includeInactive */
  list: async (includeInactive) =>
    (await callProcedure('sp_role_list', [includeInactive ? 1 : 0]))[0] ?? [],

  /** @param {number} id */
  get: async (id) => roleDetail(await callProcedure('sp_role_get', [id])),

  permissions: async () => (await callProcedure('sp_permission_list'))[0] ?? [],

  /**
   * @param {{ code: string, name: string, description: string | null, dataScope: string, permissionCodes: string[], moduleScopes: string[] }} r
   * @param {RequestMeta} m
   */
  create: async (r, m) =>
    roleDetail(
      await callProcedure('sp_role_create', [
        m.actorUserId,
        m.requestId,
        m.ip,
        r.code,
        r.name,
        r.description,
        r.dataScope,
        JSON.stringify(r.permissionCodes),
        JSON.stringify(r.moduleScopes),
      ]),
    ),

  /**
   * @param {number} id
   * @param {{ rowVersion: number, name: string, description: string | null, dataScope: string, isActive: boolean, permissionCodes: string[], moduleScopes: string[] }} r
   * @param {RequestMeta} m
   */
  update: async (id, r, m) =>
    roleDetail(
      await callProcedure('sp_role_update', [
        m.actorUserId,
        m.requestId,
        m.ip,
        id,
        r.rowVersion,
        r.name,
        r.description,
        r.dataScope,
        r.isActive ? 1 : 0,
        JSON.stringify(r.permissionCodes),
        JSON.stringify(r.moduleScopes),
      ]),
    ),
};
