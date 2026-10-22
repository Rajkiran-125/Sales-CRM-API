// @ts-check
'use strict';

/**
 * Daily 06:05 IST: open deals with an expected close date in the past become SLIPPED and get
 * an "update the close date" task; a corrected date puts them back on track (12.18).
 */
const { callProcedureOne } = require('../db/pool');
const { istDate, istAt } = require('./time');

/** @type {import('./scheduler').Job} */
module.exports = {
  name: 'close-date-slip',
  catchUpHours: 24,
  scheduledAt: (now) => istAt(istDate(now), '06:05'),
  async run() {
    const r = await callProcedureOne('sp_job_close_date_slip', []);
    return Number(r?.slipped ?? 0) + Number(r?.recovered ?? 0);
  },
};
