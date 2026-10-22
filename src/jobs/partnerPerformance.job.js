// @ts-check
'use strict';

/**
 * Nightly 01:30 IST: partner scorecards of the current quarter (open snapshot), the previous
 * quarter (frozen once: the quarter-end snapshot) and the fiscal-year values on the partner
 * (12.11, V033).
 */
const { callProcedureOne } = require('../db/pool');
const { istDate, istAt } = require('./time');

/** @type {import('./scheduler').Job} */
module.exports = {
  name: 'partner-performance',
  catchUpHours: 24,
  scheduledAt: (now) => istAt(istDate(now), '01:30'),
  async run() {
    const r = await callProcedureOne('sp_partner_performance_recompute', []);
    return Number(r?.partners ?? 0);
  },
};
