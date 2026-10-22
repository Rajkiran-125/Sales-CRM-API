// @ts-check
'use strict';

/** Leads, read + write side (12.4; V008, V011, V012). */
const repo = require('./leads.repository');
const { shape, shapeAll } = require('../../shared/readModel');
const { offsetOf } = require('../../shared/schemas');

const EXPORT_LIMIT = 10000;

module.exports = {
  /**
   * The filtered list for Excel (8.11, 19.1 "every list screen also offers an Excel export").
   * shortcut: capped at EXPORT_LIMIT rows, move to an async job (20.2) past that
   * @param {number} userId
   * @param {any} q
   */
  async exportRows(userId, q) {
    const { rows } = await repo.list(userId, { ...q, offset: 0, limit: EXPORT_LIMIT });
    return rows;
  },

  /**
   * @param {number} userId
   * @param {any} q
   */
  async list(userId, q) {
    const { rows, total, stageCounts } = await repo.list(userId, {
      ...q,
      offset: offsetOf(q),
      limit: q.pageSize,
    });
    return {
      rows: shapeAll(rows, { bools: ['isOverdue'], numbers: ['qualificationPct'] }),
      meta: { page: q.page, pageSize: q.pageSize, total, sort: q.sort, stageCounts },
    };
  },

  /**
   * Create a lead in stage NEW; the procedure checks BR-LD-01, 02, 09 and the owner's team.
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async create(body, meta) {
    const created = await repo.create(body, meta);
    if (!created) throw new Error('sp_lead_create returned no row');
    return { id: Number(created.id), leadNo: String(created.leadNo) };
  },

  /**
   * Update a lead; the procedure recalculates qualification_pct.
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async update(id, body, meta) {
    const result = await repo.update(id, body, meta);
    if (!result) throw new Error('sp_lead_update returned no row');
    return { id: Number(result.id) };
  },

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async disqualify(id, body, meta) {
    const result = await repo.disqualify(id, body, meta);
    if (!result) throw new Error('sp_lead_disqualify returned no row');
    return { id: Number(result.id) };
  },

  /**
   * Add (dmuId null) or edit a DMU person; the procedure recalculates qualification_pct.
   * @param {number} id
   * @param {number | null} dmuId
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async dmuSave(id, dmuId, body, meta) {
    const result = await repo.dmuSave(id, dmuId, body, meta);
    if (!result) throw new Error('sp_lead_dmu_save returned no row');
    return { id: Number(result.id) };
  },

  /**
   * @param {number} id
   * @param {number} dmuId
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async dmuRemove(id, dmuId, meta) {
    const result = await repo.dmuRemove(id, dmuId, meta);
    if (!result) throw new Error('sp_lead_dmu_remove returned no row');
    return { id: Number(result.id) };
  },

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async convert(id, body, meta) {
    const result = await repo.convert(id, body, meta);
    if (!result) throw new Error('sp_lead_convert returned no row');
    return {
      opportunityId: Number(result.opportunityId),
      opportunityNo: String(result.opportunityNo),
    };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  async get(userId, id) {
    const [[lead], facts, products, dmu, competitors, activities, tasks, history] = await repo.get(
      userId,
      id,
    );
    const shapedFacts = shapeAll(facts, { bools: ['done'] }).map(({ seq: _seq, ...f }) => f);
    return {
      lead: shape(lead, {
        bools: ['isNewAccount', 'procurementStepsKnown'],
        numbers: ['qualificationPct', 'rowVersion'],
      }),
      qualification: {
        facts: shapedFacts,
        done: shapedFacts.filter((f) => f.done).length,
        total: shapedFacts.length,
      },
      products,
      dmu,
      competitors,
      activities,
      tasks,
      history,
    };
  },
};
