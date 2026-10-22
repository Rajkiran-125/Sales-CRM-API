// @ts-check
'use strict';

/**
 * Roles (11.1-11.4). Rules live in the procedures: known permission codes only, system
 * roles cannot be deactivated, the CRM Admin role keeps its lock-out protection. A change
 * of permissions applies at the next request of every user, so the context cache is cleared.
 */
const repo = require('./roles.repository');
const accessContext = require('../../services/accessContext.service');
const { errors } = require('../../shared/errors');

/** @param {number} id */
async function getOrThrow(id) {
  const role = await repo.get(id);
  if (!role) throw errors.notFound('Role not found.');
  return role;
}

module.exports = {
  /** @param {boolean} includeInactive */
  list: (includeInactive) => repo.list(includeInactive),

  get: getOrThrow,

  /** Permission catalogue grouped by module, in display order. */
  async permissions() {
    const rows = await repo.permissions();
    /** @type {Map<string, any[]>} */
    const groups = new Map();
    for (const p of rows) {
      if (!groups.has(p.module)) groups.set(p.module, []);
      /** @type {any[]} */ (groups.get(p.module)).push(p);
    }
    return [...groups.entries()].map(([module, permissions]) => ({ module, permissions }));
  },

  /**
   * @param {any} input
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  create: (input, meta) => repo.create({ ...input, moduleScopes: input.moduleScopes ?? [] }, meta),

  /**
   * PATCH: fields not sent keep their current value.
   * @param {number} id
   * @param {any} patch
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async update(id, patch, meta) {
    const current = await getOrThrow(id);
    const updated = await repo.update(
      id,
      {
        rowVersion: patch.rowVersion,
        name: patch.name ?? current.name,
        description: patch.description !== undefined ? patch.description : current.description,
        dataScope: patch.dataScope ?? current.dataScope,
        isActive: patch.isActive ?? Boolean(current.isActive),
        permissionCodes: patch.permissionCodes ?? current.permissionCodes,
        moduleScopes: patch.moduleScopes ?? current.moduleScopes,
      },
      meta,
    );
    accessContext.invalidateAll();
    return updated;
  },
};
