// @ts-check
'use strict';

/**
 * Daily 06:00 IST: deals with no activity and no weekly status for deal.stale_days become
 * STALE; the owner and the manager are emailed once, on the change (12.18, BR-OP-14).
 */
const { callProcedure } = require('../db/pool');
const mailer = require('../integrations/mailer');
const { istDate, istAt } = require('./time');

/** @type {import('./scheduler').Job} */
module.exports = {
  name: 'stale-deals',
  catchUpHours: 24,
  scheduledAt: (now) => istAt(istDate(now), '06:00'),
  async run() {
    const [rows] = await callProcedure('sp_job_stale_deals', []);
    for (const d of rows ?? []) {
      const values = {
        opportunityNo: d.opportunityNo,
        title: d.title,
        ownerName: d.ownerName,
        daysQuiet: Number(d.daysQuiet),
      };
      const ref = { entityType: 'OPP', entityId: Number(d.id) };
      await mailer.sendTemplate(
        'DEAL_STALE',
        d.ownerEmail,
        { ...values, fullName: d.ownerName },
        ref,
      );
      if (d.managerEmail)
        await mailer.sendTemplate(
          'DEAL_STALE',
          d.managerEmail,
          { ...values, fullName: d.managerName },
          ref,
        );
    }
    return rows?.length ?? 0;
  },
};
