// @ts-check
'use strict';

/**
 * Accounts (12.6): the account list with pipeline figures and Account 360 (UM 8: every deal,
 * contact, order and partner at an account), plus create / edit (V020). An account is visible
 * when the user's tree owns it or can see one of its deals (10.8 rule 4); only visible deals count.
 */
const repo = require('./accounts.repository');
const { offsetOf } = require('../../shared/schemas');

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q
   */
  async list(userId, q) {
    const { rows, total } = await repo.list(userId, {
      ...q,
      offset: offsetOf(q),
      limit: q.pageSize,
    });
    return { rows, meta: { page: q.page, pageSize: q.pageSize, total, sort: q.sort } };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  async get360(userId, id) {
    const [[account], [kpis], contacts, opportunities, orders, partners, activities] =
      await repo.get(userId, id);
    return { account, kpis, contacts, opportunities, orders, partners, activities };
  },

  /**
   * New accounts default to the creator as owner.
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  create: (body, meta, allowAny) =>
    repo.create({ ...body, ownerUserId: body.ownerUserId ?? meta.actorUserId }, meta, allowAny),

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  update: (id, body, meta, allowAny) => repo.update(id, body, meta, allowAny),

  /**
   * Move everything of account `id` onto the survivor and retire `id` (12.6, V028).
   * @param {number} id
   * @param {number} survivorId
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async merge(id, survivorId, meta) {
    const row = await repo.merge(id, survivorId, meta);
    const moved = typeof row?.moved === 'string' ? JSON.parse(row.moved) : row?.moved;
    return { id: Number(row?.id), moved };
  },

  /**
   * The filtered list for Excel, newest sort as on screen (8.11).
   * shortcut: capped at EXPORT_LIMIT rows, move to an async job (20.2) past that
   * @param {number} userId
   * @param {any} q
   */
  async exportRows(userId, q) {
    const { rows } = await repo.list(userId, { ...q, offset: 0, limit: EXPORT_LIMIT });
    return rows;
  },
};

const EXPORT_LIMIT = 10000;
