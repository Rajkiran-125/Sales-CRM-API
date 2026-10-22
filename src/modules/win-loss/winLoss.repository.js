// @ts-check
'use strict';

/** Win / loss analysis, read side (V010 procedures; competitor filter V035). */
const { callProcedure } = require('../../db/pool');

/** @param {any} q */
const filters = (q) => [
  q.fiscalYear ?? null,
  q.quarter ?? null,
  q.ownerUserId ?? null,
  q.productId ?? null,
  q.industryId ?? null,
  q.partnerId ?? null,
  q.competitorId ?? null,
];

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q
   */
  summary: (userId, q) => callProcedure('sp_winloss_summary', [userId, ...filters(q)]),

  /**
   * @param {number} userId
   * @param {any} q  validated query plus offset / limit
   */
  async deals(userId, q) {
    const [rows, totals] = await callProcedure('sp_winloss_deals', [
      userId,
      ...filters(q),
      q.outcome ?? null,
      q.offset,
      q.limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0) };
  },
};
