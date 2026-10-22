// @ts-check
'use strict';

/** Monday 06:00 IST: a weekly status task per open deal, due per OD-16 (12.18, UM 6.4). */
const { callProcedureOne } = require('../db/pool');
const { istMonday, istAt } = require('./time');

/** @type {import('./scheduler').Job} */
module.exports = {
  name: 'weekly-status-tasks',
  catchUpHours: 7 * 24,
  scheduledAt: (now) => istAt(istMonday(now), '06:00'),
  async run(now) {
    const row = await callProcedureOne('sp_job_weekly_status_tasks', [istMonday(now)]);
    return Number(row?.processed ?? 0);
  },
};
