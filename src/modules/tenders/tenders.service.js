// @ts-check
'use strict';

/**
 * Tenders (12.8, UM 4.4): the list by status with the submission countdown, the tender page
 * with the readiness checklist, market intelligence and the result; create / edit, status
 * transitions and the checklist (V037).
 */
const repo = require('./tenders.repository');
const { shape } = require('../../shared/readModel');
const { offsetOf } = require('../../shared/schemas');

/** @typedef {import('../../shared/requestMeta').RequestMeta} Meta */

const EXPORT_LIMIT = 10000;

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q
   */
  async list(userId, q) {
    const { rows, total, statusCounts } = await repo.list(userId, {
      ...q,
      offset: offsetOf(q),
      limit: q.pageSize,
    });
    return {
      rows: rows.map((r) => shape(r, { numbers: ['readinessPct'] })),
      meta: { page: q.page, pageSize: q.pageSize, total, sort: q.sort, statusCounts },
    };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  async get(userId, id) {
    const [[tender], stages, checklist, activities] = await repo.get(userId, id);
    return {
      tender: shape(tender, { numbers: ['readinessPct'] }),
      stages,
      checklist,
      activities,
    };
  },

  /** @param {number} userId @param {number} id */
  async editGet(userId, id) {
    const row = await repo.editGet(userId, id);
    return shape(row, { bools: ['specInfluenced', 'rfpInfluenced', 'prebidQueriesFiled'] });
  },

  /** @param {number | null} id @param {any} body @param {Meta} meta @param {boolean} allowAny */
  async save(id, body, meta, allowAny) {
    const row = await repo.save(id, body, meta, allowAny);
    return { id: Number(row.id), tenderNo: row.tenderNo, rowVersion: Number(row.rowVersion) };
  },

  /**
   * Move along the track; the answer carries the linked deal and its stage, so the UI can
   * close an AWARDED tender's deal as WON (D-55).
   * @param {number} id @param {any} body @param {Meta} meta @param {boolean} allowAny
   */
  async transition(id, body, meta, allowAny) {
    const row = await repo.transition(id, body, meta, allowAny);
    return {
      id: Number(row.id),
      status: row.status,
      rowVersion: Number(row.rowVersion),
      opportunityId: row.opportunityId === null ? null : Number(row.opportunityId),
      opportunityStage: row.opportunityStage ?? null,
    };
  },

  /**
   * @param {number} tenderId @param {number | null} itemId @param {any} body
   * @param {Meta} meta @param {boolean} allowAny
   */
  async checklistSave(tenderId, itemId, body, meta, allowAny) {
    const row = await repo.checklistSave(tenderId, itemId, body, meta, allowAny);
    return { id: Number(row.id), readinessPct: Number(row.readinessPct) };
  },

  /** @param {number} tenderId @param {number} itemId @param {Meta} meta @param {boolean} allowAny */
  checklistDelete: (tenderId, itemId, meta, allowAny) =>
    repo.checklistDelete(tenderId, itemId, meta, allowAny),

  /**
   * The filtered list for Excel. shortcut: capped at EXPORT_LIMIT rows, move to an async job
   * (20.2) past that
   * @param {number} userId
   * @param {any} q
   */
  async exportRows(userId, q) {
    const { rows } = await repo.list(userId, { ...q, offset: 0, limit: EXPORT_LIMIT });
    return rows;
  },
};
