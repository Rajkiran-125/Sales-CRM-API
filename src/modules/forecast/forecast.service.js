// @ts-check
'use strict';

/**
 * Forecast & status, read side (12.10; D-27): the weekly status grid (BR-FC-01), the monthly
 * closure (BR-FC-03) and the hierarchy funnel. "team" (the whole visible tree) needs
 * forecast.view_team; without it the user sees their own deals. Submitting the week and the
 * monthly commitment comes with the rest of Phase 1.
 */
const repo = require('./forecast.repository');
const { shape, shapeAll } = require('../../shared/readModel');

/** @param {Set<string>} permissions @param {boolean | undefined} team */
const teamView = (permissions, team) => Boolean(team) && permissions.has('forecast.view_team');

module.exports = {
  /**
   * Monthly closure commits (BR-FC-03); a null type removes the deal's commit (V038).
   * @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny
   */
  async monthlySave(body, meta, allowAny) {
    const row = await repo.monthlySave(body, meta, allowAny);
    return { committed: Number(row?.committed ?? 0) };
  },

  /**
   * One task to every team member with deals still without this week's status (12.10).
   * @param {string} weekStart @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async nudge(weekStart, meta) {
    const row = await repo.nudge(weekStart, meta);
    return { nudged: Number(row?.nudged ?? 0) };
  },

  /**
   * @param {number} userId
   * @param {Set<string>} permissions
   * @param {{ weekStart?: string, team?: boolean }} q
   */
  async weekly(userId, permissions, q) {
    const team = teamView(permissions, q.team);
    const [[week], deals, [summary]] = await repo.weekly(userId, q.weekStart ?? null, team);
    return { week: shape(week, { bools: ['isCurrentWeek'] }), team, deals, summary };
  },

  /**
   * @param {number} userId
   * @param {Set<string>} permissions
   * @param {{ month?: string, team?: boolean }} q
   */
  async monthly(userId, permissions, q) {
    const team = teamView(permissions, q.team);
    const [[month], deals, [totals]] = await repo.monthly(userId, q.month ?? null, team);
    return {
      month,
      team,
      deals: shapeAll(deals, { bools: ['achieved', 'monthEndFlag'] }),
      totals,
    };
  },

  /**
   * @param {number} userId
   * @param {{ month?: string }} q
   */
  async hierarchy(userId, q) {
    const [[period], people] = await repo.hierarchy(userId, q.month ?? null);
    return { period, people };
  },
};
