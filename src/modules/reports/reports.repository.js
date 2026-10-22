// @ts-check
'use strict';

/** Reports, read side (V010 procedures). */
const { callProcedure } = require('../../db/pool');

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q
   */
  revenueGm: (userId, q) =>
    callProcedure('sp_report_revenue_gm', [
      userId,
      q.fiscalYear ?? null,
      q.quarter ?? null,
      q.dimension ?? 'PRODUCT',
    ]),

  /**
   * @param {number} userId
   * @param {any} q
   */
  productMix: (userId, q) =>
    callProcedure('sp_report_product_mix', [
      userId,
      q.fiscalYear ?? null,
      q.quarter ?? null,
      q.partnerId ?? null,
    ]),
};
