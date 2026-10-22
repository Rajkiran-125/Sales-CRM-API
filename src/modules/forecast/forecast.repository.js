// @ts-check
'use strict';

/** Forecast & status, read side (V008 procedures). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} Meta */

module.exports = {
  /** @param {any} b @param {Meta} m @param {boolean} allowAny */
  monthlySave: (b, m, allowAny) =>
    callProcedureOne('sp_monthly_commit_save', [
      m.actorUserId,
      m.requestId,
      m.ip,
      b.month,
      JSON.stringify(b.items),
      allowAny ? 1 : 0,
    ]),

  /** @param {string} weekStart @param {Meta} m */
  nudge: (weekStart, m) =>
    callProcedureOne('sp_forecast_nudge', [m.actorUserId, m.requestId, m.ip, weekStart]),

  /**
   * @param {number} userId
   * @param {string | null} weekStart
   * @param {boolean} team
   */
  weekly: (userId, weekStart, team) =>
    callProcedure('sp_forecast_weekly', [userId, weekStart, team ? 1 : 0]),

  /**
   * @param {number} userId
   * @param {string | null} month  first day of the month
   * @param {boolean} team
   */
  monthly: (userId, month, team) =>
    callProcedure('sp_forecast_monthly', [userId, month, team ? 1 : 0]),

  /**
   * @param {number} userId
   * @param {string | null} month
   */
  hierarchy: (userId, month) => callProcedure('sp_forecast_hierarchy', [userId, month]),
};
