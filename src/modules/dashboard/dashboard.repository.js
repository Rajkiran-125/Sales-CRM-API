// @ts-check
'use strict';

/** Management dashboard (V007 procedures, read-only). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @param {any} f */
const filterParams = (f) => [
  f.fiscalYear ?? null,
  f.quarter ?? null,
  f.source ?? null,
  f.productId ?? null,
  f.industryId ?? null,
  f.ownerUserId ?? null,
  f.partnerId ?? null,
];

module.exports = {
  /**
   * The twelve result sets of sp_dashboard_get, in order.
   * @param {number} userId
   * @param {any} f
   */
  get: (userId, f) => callProcedure('sp_dashboard_get', [userId, ...filterParams(f)]),

  /** The cycle times tile (V040). @param {number} userId @param {any} f */
  cycleTimes: (userId, f) =>
    callProcedureOne('sp_dashboard_cycle_times', [userId, ...filterParams(f)]),

  /**
   * @param {number} userId
   * @param {string} tile
   * @param {string | null} key
   * @param {any} f
   * @param {number} offset
   * @param {number} limit
   */
  async drill(userId, tile, key, f, offset, limit) {
    const [rows, totals] = await callProcedure('sp_dashboard_drill', [
      userId,
      tile,
      key,
      ...filterParams(f),
      offset,
      limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0) };
  },
};
