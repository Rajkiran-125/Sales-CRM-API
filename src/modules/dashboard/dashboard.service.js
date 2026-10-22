// @ts-check
'use strict';

/**
 * Management dashboard v1 (12.2, UM 8). The numbers are computed by sp_dashboard_get inside
 * the user's data scope; this service only shapes the result sets into the response of 14.3.
 * Money stays a decimal string with 2 decimals, in INR (OD-27); counts and percentages are
 * numbers.
 */
const repo = require('./dashboard.repository');

/** @param {unknown} v */
const num = (v) => (v === null || v === undefined ? null : Number(v));

/** @param {number} fy @param {number | null} q */
function periodLabel(fy, q) {
  const fyLabel = `FY ${fy}-${String((fy + 1) % 100).padStart(2, '0')}`;
  return q ? `${fyLabel} Q${q}` : fyLabel;
}

module.exports = {
  /**
   * @param {number} userId
   * @param {any} filters
   */
  async get(userId, filters) {
    const [
      [period],
      [kpi],
      funnel,
      closures,
      bySource,
      lossReasons,
      topPartners,
      detail,
      owners,
      partners,
      products,
      industries,
    ] = await repo.get(userId, filters);
    const cycle = await repo.cycleTimes(userId, filters);

    const fiscalYear = Number(period.fiscalYear);
    const quarter = num(period.quarter);
    const won = Number(kpi.wonCount);
    const lost = Number(kpi.lostCount);
    return {
      period: { ...period, fiscalYear, quarter, label: periodLabel(fiscalYear, quarter) },
      kpi,
      funnelByStage: funnel.map((s) => ({ ...s, confidencePct: num(s.confidencePct) })),
      closures,
      bySource,
      winLoss: {
        wonCount: won,
        wonValue: kpi.wonValue,
        lostCount: lost,
        lostValue: kpi.lostValue,
        winRatePct: won + lost === 0 ? null : Math.round((1000 * won) / (won + lost)) / 10,
        topLossReasons: lossReasons,
      },
      topPartners: topPartners.map((p) => ({ ...p, winRatePct: num(p.winRatePct) })),
      detail,
      cycleTimes: {
        leadToDealDays: num(cycle?.leadToDealDays),
        dealToWinDays: num(cycle?.dealToWinDays),
        orderToBookDays: num(cycle?.orderToBookDays),
      },
      filterOptions: { owners, partners, products, industries },
    };
  },

  /**
   * @param {number} userId
   * @param {string} tile
   * @param {any} q  validated query (filters, key, page, pageSize)
   */
  drill: (userId, tile, q) =>
    repo.drill(userId, tile, q.key ?? null, q, (q.page - 1) * q.pageSize, q.pageSize),
};
