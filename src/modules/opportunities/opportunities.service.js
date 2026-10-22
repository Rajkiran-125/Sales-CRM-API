// @ts-check
'use strict';

/**
 * Opportunities, read + write side (12.5; D-27): list with counts per view, kanban by stage
 * (no drag), the deal workspace, and the write actions (update, move-stage, validate, close)
 * from V013.
 */
const repo = require('./opportunities.repository');
const { shape, shapeAll } = require('../../shared/readModel');
const { offsetOf } = require('../../shared/schemas');
const { appError } = require('../../shared/errors');

const PCT = { numbers: ['confidencePct'] };

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
    const { rows, total, counts } = await repo.list(userId, {
      ...q,
      offset: offsetOf(q),
      limit: q.pageSize,
    });
    return {
      rows: shapeAll(rows, PCT),
      meta: { page: q.page, pageSize: q.pageSize, total, sort: q.sort, counts },
    };
  },

  /**
   * @param {number} userId
   * @param {any} q
   */
  async kanban(userId, q) {
    const { columns, cards } = await repo.kanban(userId, q);
    return {
      columns: shapeAll(columns, PCT).map((col) => ({
        ...col,
        cards: cards
          .filter((card) => card.stageCode === col.stageCode)
          .map(({ rn: _rn, stageCode: _stage, ...card }) => card),
      })),
    };
  },

  /**
   * @param {number} userId
   * @param {number} id
   * @param {boolean} canSeeCommercial
   */
  async get(userId, id, canSeeCommercial) {
    const [
      [deal],
      stages,
      products,
      dmu,
      partners,
      competitors,
      [poc],
      offers,
      partnerCommercials,
      activities,
      weeklyStatus,
      monthlyCommits,
      history,
      [winLoss],
      tasks,
    ] = await repo.get(userId, id, canSeeCommercial);
    return {
      deal: shape(deal, { numbers: ['confidencePct', 'fxRate', 'daysInStage'] }),
      stages: shapeAll(stages, PCT),
      products,
      dmu,
      partners,
      competitors,
      poc: poc ?? null,
      offers: shapeAll(offers, { numbers: ['discountPct'] }),
      partnerCommercials: canSeeCommercial
        ? shapeAll(partnerCommercials, { numbers: ['partnerMarginPct'] })
        : null,
      activities,
      weeklyStatus,
      monthlyCommits,
      history,
      winLoss: winLoss ?? null,
      tasks,
    };
  },

  /**
   * Update opportunity core fields (title, value, owners, products, etc.).
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {string[]} sentKeys  the keys the client sent
   */
  async update(id, body, meta, sentKeys) {
    // PATCH: only the fields the client sent change; the procedure replaces every column (D-42)
    const current = (await repo.editValues(id)) ?? {};
    const sent = Object.fromEntries(sentKeys.filter((k) => k in body).map((k) => [k, body[k]]));
    const result = await repo.update(
      id,
      { ...body, ...current, ...sent, rowVersion: body.rowVersion, productIds: body.productIds },
      meta,
    );
    if (!result) throw new Error('sp_opportunity_update returned no row');
    return { id: Number(result.id) };
  },

  /**
   * Move one stage forward with the gate met, or override with a reason (16.3, V026).
   * A GATE_NOT_MET error lists the missing items as details.
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} canOverride
   */
  async moveStage(id, body, meta, canOverride) {
    try {
      const result = await repo.moveStage(id, body, meta, canOverride);
      if (!result) throw new Error('sp_opportunity_move_stage returned no row');
      return { id: Number(result.id), overridden: Boolean(Number(result.overridden)) };
    } catch (err) {
      if (/** @type {any} */ (err)?.code !== 'GATE_NOT_MET') throw err;
      const { missing } = await this.gate(meta.actorUserId, id);
      throw appError(
        'GATE_NOT_MET',
        /** @type {Error} */ (err).message,
        missing.map((m) => ({ field: 'toStage', message: m })),
      );
    }
  },

  /**
   * The next stage and what is still missing to move there (16.3).
   * @param {number} userId
   * @param {number} id
   */
  async gate(userId, id) {
    const [[row], items] = await repo.gate(userId, id);
    return {
      stageCode: row?.stageCode ?? null,
      nextStage: row?.nextStage ?? null,
      allowed: Boolean(Number(row?.allowed)),
      missing: (items ?? []).map((i) => String(i.item)),
    };
  },

  /**
   * The POC record with ids, or null (12.5.4).
   * @param {number} userId
   * @param {number} id
   */
  async pocGet(userId, id) {
    return (await repo.pocGet(userId, id)) ?? null;
  },

  /**
   * Save the POC record of a deal (12.5.4).
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async pocSave(id, body, meta) {
    const result = await repo.pocSave(id, body, meta);
    return { id: Number(result?.id) };
  },

  /**
   * Mark opportunity as VALID or NOT_VALID.
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async validate(id, body, meta) {
    const result = await repo.validate(id, body, meta);
    if (!result) throw new Error('sp_opportunity_validate returned no row');
    return { id: Number(result.id) };
  },

  /**
   * Add or update a DMU member on a deal.
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  async dmuUpsert(id, body, meta, allowAny) {
    const result = await repo.dmuUpsert(id, body, meta, allowAny);
    if (!result) throw new Error('sp_opportunity_dmu_upsert returned no row');
    return { id: Number(result.id) };
  },

  /**
   * Remove a DMU member from a deal.
   * @param {number} id
   * @param {number} dmuId
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  async dmuRemove(id, dmuId, meta, allowAny) {
    const result = await repo.dmuRemove(id, dmuId, meta, allowAny);
    if (!result) throw new Error('sp_opportunity_dmu_remove returned no row');
    return { id: Number(result.id) };
  },

  /**
   * Close opportunity as WON, LOST or DORMANT.
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async close(id, body, meta) {
    const result = await repo.close(id, body, meta);
    if (!result) throw new Error('sp_opportunity_close returned no row');
    return { id: Number(result.id) };
  },
};
