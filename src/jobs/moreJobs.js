// @ts-check
'use strict';

/**
 * The remaining scheduler jobs of 12.18 (V039). Each is one procedure; the jobs that notify
 * send one email per row the procedure returns. Times are IST.
 */
const { callProcedure, callProcedureOne } = require('../db/pool');
const mailer = require('../integrations/mailer');
const { istDate, istAt, istMonday, addDays } = require('./time');

const DAYS = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];

/** The latest due day of the IST week at 09:00 (the reminder before the due time). @param {Date} now @param {string} dueDay */
function dueDayMorning(now, dueDay) {
  const offset = Math.max(0, DAYS.indexOf(String(dueDay).toUpperCase()));
  const at = istAt(addDays(istMonday(now), offset), '09:00');
  // before this week's due day the latest moment is last week's
  return at <= now ? at : istAt(addDays(istMonday(now), offset - 7), '09:00');
}

/** 06:xx IST of today. @param {string} hhmm */
const daily = (hhmm) => (/** @type {Date} */ now) => istAt(istDate(now), hhmm);

/** @param {string} proc @param {(row: any) => Promise<void>} [each] */
async function rowsOf(proc, each) {
  const [rows] = await callProcedure(proc, []);
  if (each) for (const r of rows ?? []) await each(r);
  return rows?.length ?? 0;
}

/** @type {import('./scheduler').Job[]} */
const MORE_JOBS = [
  {
    name: 'weekly-status-reminder',
    catchUpHours: 8,
    scheduledAt: (now, s) => dueDayMorning(now, s.weeklyStatusDueDay ?? 'FRIDAY'),
    run: () =>
      rowsOf('sp_job_weekly_status_reminder', (r) =>
        mailer.sendTemplate('WEEKLY_STATUS_REMINDER', r.email, {
          fullName: r.fullName,
          pendingCount: Number(r.pendingCount),
          weekStart: istDate(new Date(r.weekStart)),
        }),
      ),
  },
  {
    name: 'monthly-close',
    catchUpHours: 72,
    // the 1st of the month 06:20 IST
    scheduledAt: (now) => istAt(`${istDate(now).slice(0, 8)}01`, '06:20'),
    async run() {
      const r = await callProcedureOne('sp_job_monthly_close', []);
      return Number(r?.achievedMarked ?? 0) + Number(r?.tasks ?? 0);
    },
  },
  {
    name: 'wake-up',
    catchUpHours: 24,
    scheduledAt: daily('06:10'),
    run: () =>
      rowsOf('sp_job_wake_up', (r) =>
        mailer.sendTemplate(
          'DEAL_WAKE_UP',
          r.email,
          { fullName: r.fullName, opportunityNo: r.opportunityNo, title: r.title },
          { entityType: 'OPP', entityId: Number(r.id) },
        ),
      ),
  },
  {
    name: 'invoice-due',
    catchUpHours: 24,
    scheduledAt: daily('06:15'),
    async run() {
      const r = await callProcedureOne('sp_job_invoice_due', []);
      return Number(r?.overdue ?? 0) + Number(r?.tasks ?? 0);
    },
  },
  {
    name: 'engagement-reminder',
    catchUpHours: 12,
    scheduledAt: daily('08:00'),
    run: () =>
      rowsOf('sp_job_engagement_reminder', (r) =>
        mailer.sendTemplate(
          'ENGAGEMENT_REMINDER',
          r.email,
          { fullName: r.fullName, partnerName: r.partnerName, plan: r.plan ?? '' },
          { entityType: 'PARTNER', entityId: Number(r.partnerId) },
        ),
      ),
  },
  {
    name: 'stage-ageing',
    catchUpHours: 12,
    // Monday 07:00 IST
    scheduledAt: (now) => istAt(istMonday(now), '07:00'),
    run: () =>
      rowsOf('sp_job_stage_ageing', (r) =>
        mailer.sendTemplate('STAGE_AGEING_DIGEST', r.email, {
          fullName: r.fullName,
          dealCount: Number(r.dealCount),
          deals: r.deals,
        }),
      ),
  },
  {
    name: 'housekeeping',
    catchUpHours: 24,
    scheduledAt: daily('02:00'),
    async run() {
      const r = await callProcedureOne('sp_job_housekeeping', []);
      return Number(r?.tokens ?? 0) + Number(r?.refreshTokens ?? 0) + Number(r?.loginAttempts ?? 0);
    },
  },
];

module.exports = { MORE_JOBS, dueDayMorning };
