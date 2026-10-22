// @ts-check
'use strict';

/**
 * Reports (19.1), read side (D-27). REVENUE_GM: won revenue (the order revenue entered by
 * finance, else the PO value) and the gross margin where finance has entered it (BR-OR-06: the
 * revenue without GM is shown apart). PRODUCT_MIX: products per partner and per account over
 * the open deals and the deals won in the period. Both within the user's data scope (19.2).
 */
const repo = require('./reports.repository');
const { shape, shapeAll } = require('../../shared/readModel');

/** @param {any} period */
const periodOf = (period) => ({
  ...period,
  quarter: period.quarter === null ? null : Number(period.quarter),
});

module.exports = {
  /**
   * @param {number} userId
   * @param {'REVENUE_GM' | 'PRODUCT_MIX'} code
   * @param {any} q
   */
  async get(userId, code, q) {
    if (code === 'REVENUE_GM') {
      const [[period], rows, [totals]] = await repo.revenueGm(userId, q);
      return {
        code,
        period: periodOf(period),
        rows: shapeAll(rows, { numbers: ['gmPct'] }),
        totals: shape(totals, { numbers: ['gmPct'] }),
      };
    }
    const [[period], partners, accounts] = await repo.productMix(userId, q);
    return { code, period: periodOf(period), partners, accounts };
  },
};
