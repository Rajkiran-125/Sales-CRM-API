// @ts-check
'use strict';

/**
 * Monday at report.monday.time (IST): last week's weekly status of every open deal, emailed
 * to the active sales heads with an Excel attachment (12.18, UM 8; recipients per OD-16 default).
 */
const { callProcedure } = require('../db/pool');
const mailer = require('../integrations/mailer');
const { workbookBuffer } = require('../integrations/excel');
const logger = require('../config/logger');
const { istMonday, istAt, addDays } = require('./time');

const RISK = new Set(['AT_RISK', 'SLIPPED', 'STALLED']);

/** @type {import('../integrations/excel').Column[]} */
const COLUMNS = [
  { header: 'Owner', key: 'ownerName', width: 22 },
  { header: 'Manager', key: 'managerName', width: 22 },
  { header: 'Deal no.', key: 'opportunityNo', width: 16 },
  { header: 'Deal', key: 'title', width: 36 },
  { header: 'Account', key: 'accountName', width: 28 },
  { header: 'Stage', key: 'stageName', width: 16 },
  { header: 'Health', key: 'health', width: 12 },
  {
    header: 'Value (INR)',
    key: 'valueInr',
    width: 16,
    format: (v) => (v === null ? '' : Number(v)),
  },
  {
    header: 'Weighted (INR)',
    key: 'weightedInr',
    width: 16,
    format: (v) => (v === null ? '' : Number(v)),
  },
  { header: 'Expected close', key: 'expectedCloseDate', width: 14 },
  { header: 'Week status', key: 'weekStatus', width: 14, format: (v) => v ?? 'NOT SUBMITTED' },
  { header: 'This week', key: 'thisWeek', width: 40 },
  { header: 'Next step', key: 'nextStep', width: 40 },
  { header: 'Submitted at (UTC)', key: 'submittedAt', width: 20 },
];

/** @type {import('./scheduler').Job} */
module.exports = {
  name: 'monday-report',
  catchUpHours: 12,
  scheduledAt: (now, settings) => istAt(istMonday(now), settings.mondayReportTime),
  async run(now) {
    const weekStart = addDays(istMonday(now), -7);
    const [rows, recipients] = await callProcedure('sp_job_monday_report', [weekStart]);
    if (!recipients?.length) {
      logger.warn('Monday report: no active sales head to send it to');
      return 0;
    }
    const content = await workbookBuffer(`Week of ${weekStart}`, COLUMNS, rows ?? []);
    const submitted = (rows ?? []).filter((r) => r.weekStatus).length;
    const values = {
      weekStart,
      dealCount: rows?.length ?? 0,
      submittedCount: submitted,
      pendingCount: (rows?.length ?? 0) - submitted,
      riskCount: (rows ?? []).filter((r) => RISK.has(r.weekStatus)).length,
    };
    for (const r of recipients) {
      await mailer.sendTemplate(
        'WEEKLY_STATUS_REPORT',
        r.email,
        { ...values, fullName: r.fullName },
        { attachments: [{ filename: `weekly-status-${weekStart}.xlsx`, content }] },
      );
    }
    return recipients.length;
  },
};
