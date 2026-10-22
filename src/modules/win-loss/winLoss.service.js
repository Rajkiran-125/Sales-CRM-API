// @ts-check
'use strict';

/**
 * Win / loss analysis (12.12, UM 8), read side (D-27): the deals won or lost in a fiscal year
 * or quarter (IST close date), within the user's data scope. Values are INR (OD-51); a won
 * deal counts at its PO value.
 */
const repo = require('./winLoss.repository');
const { shape, shapeAll } = require('../../shared/readModel');
const { offsetOf } = require('../../shared/schemas');

const EXPORT_LIMIT = 10000;

module.exports = {
  /**
   * The closed deals of the filters for Excel (8.11).
   * shortcut: capped at EXPORT_LIMIT rows, move to an async job (20.2) past that
   * @param {number} userId
   * @param {any} q
   */
  async exportRows(userId, q) {
    const { rows } = await repo.deals(userId, { ...q, offset: 0, limit: EXPORT_LIMIT });
    return rows;
  },

  /**
   * @param {number} userId
   * @param {any} q
   */
  async summary(userId, q) {
    const [[period], [kpis], trend, lossReasons, competitors, winReasons, lessons] =
      await repo.summary(userId, q);
    return {
      period: { ...period, quarter: period.quarter === null ? null : Number(period.quarter) },
      kpis: shape(kpis, { numbers: ['winRatePct', 'valueWinRatePct'] }),
      trend: shapeAll(trend, { numbers: ['winRatePct'] }),
      lossReasons,
      competitors,
      winReasons,
      lessons: shapeAll(lessons, { bools: ['isWon'] }),
    };
  },

  /**
   * @param {number} userId
   * @param {any} q
   */
  async deals(userId, q) {
    const { rows, total } = await repo.deals(userId, {
      ...q,
      offset: offsetOf(q),
      limit: q.pageSize,
    });
    return { rows, meta: { page: q.page, pageSize: q.pageSize, total } };
  },
};
