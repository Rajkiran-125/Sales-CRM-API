// @ts-check
'use strict';

/**
 * The reports catalogue of 19.1. Every report reads through the service of its screen, so the
 * figures and the data scope are the screen's (19.2 "must reconcile"). The Partner Quarterly
 * Report is the PDF of the partner (D-51); every other report also exports to Excel.
 */
const forecast = require('../forecast/forecast.service');
const winLoss = require('../win-loss/winLoss.service');
const accounts = require('../accounts/accounts.service');
const tenders = require('../tenders/tenders.service');
const partners = require('../partners/partners.service');
const reportsRepo = require('./reports.repository');
const { appError } = require('../../shared/errors');

/** @typedef {import('../../integrations/excel').Sheet} Sheet */
/** @typedef {{ userId: number, permissions: Set<string>, q: any }} Ctx */

const day = (/** @type {any} */ v) =>
  v ? String(v instanceof Date ? v.toISOString() : v).slice(0, 10) : '';
const yesNo = (/** @type {any} */ v) =>
  v === null || v === undefined ? '' : Number(v) ? 'Yes' : 'No';
/** @param {string} header @param {string} key @param {number} [width] */
const col = (header, key, width = 18) => ({ header, key, width });
/** @param {string} header @param {string} key @param {number} [width] */
const money = (header, key, width = 16) => ({ header, key, width, format: Number });
/** @param {string} header @param {string} key */
const date = (header, key) => ({ header, key, width: 12, format: day });

/**
 * @typedef {object} Report
 * @property {string} code
 * @property {string} name
 * @property {string} content
 * @property {string} filters
 * @property {string} link       the screen that shows it
 * @property {string} viewPermission
 * @property {((c: Ctx) => Promise<Sheet[]>) | null} sheets   null = not an Excel report
 */

/** @type {Report[]} */
const REPORTS = [
  {
    code: 'WEEKLY_STATUS',
    name: 'Weekly status',
    content: 'Per deal: stage, value, status, this week, next step, close date; pending updates.',
    filters: 'Week, my deals or my team',
    link: '/crm/forecast',
    viewPermission: 'forecast.view',
    async sheets({ userId, permissions, q }) {
      const w = await forecast.weekly(userId, permissions, {
        weekStart: q.weekStart,
        team: q.team === 'true',
      });
      return [
        {
          name: `Week of ${day(w.week.weekStart)}`,
          columns: [
            col('Deal no', 'opportunityNo', 16),
            col('Title', 'title', 34),
            col('Account', 'accountName', 26),
            col('Owner', 'ownerName', 22),
            col('Stage', 'stageName', 16),
            money('Value (INR)', 'value'),
            col('Status', 'status', 12),
            col('This week', 'thisWeek', 40),
            col('Next step', 'nextStep', 34),
            date('Close date', 'statusCloseDate'),
            date('Submitted', 'submittedAt'),
          ],
          rows: w.deals,
        },
      ];
    },
  },
  {
    code: 'MONTHLY_CLOSURE',
    name: 'Monthly closure',
    content: 'Committed vs achieved, next-month forecast and best case per deal.',
    filters: 'Month, my deals or my team',
    link: '/crm/forecast',
    viewPermission: 'forecast.view',
    async sheets({ userId, permissions, q }) {
      const m = await forecast.monthly(userId, permissions, {
        month: q.month,
        team: q.team === 'true',
      });
      return [
        {
          name: `Month ${day(m.month.month).slice(0, 7)}`,
          columns: [
            col('Deal no', 'opportunityNo', 16),
            col('Title', 'title', 34),
            col('Account', 'accountName', 26),
            col('Owner', 'ownerName', 22),
            col('Stage', 'stageName', 16),
            col('Commitment', 'commitType', 12),
            money('Committed (INR)', 'commitValue'),
            money('Value (INR)', 'value'),
            date('Close date', 'expectedCloseDate'),
            { header: 'Achieved', key: 'achieved', width: 10, format: yesNo },
            money('Won (INR)', 'wonValue'),
          ],
          rows: m.deals,
        },
      ];
    },
  },
  {
    code: 'HIERARCHY_FUNNEL',
    name: 'Hierarchy funnel',
    content: 'Owner → team: open funnel, weighted, committed, achieved, quarter target.',
    filters: 'Month',
    link: '/crm/forecast',
    viewPermission: 'forecast.view_team',
    async sheets({ userId, q }) {
      const h = await forecast.hierarchy(userId, { month: q.month });
      return [
        {
          name: 'Hierarchy funnel',
          columns: [
            col('Person', 'name', 26),
            col('Open deals', 'openDeals', 12),
            money('Open (INR)', 'openValue'),
            money('Weighted (INR)', 'weighted'),
            money('Committed (INR)', 'committed'),
            money('Achieved (INR)', 'achieved'),
            money('Quarter target (INR)', 'quarterTarget', 18),
            money('Quarter won (INR)', 'quarterWon', 18),
          ],
          rows: h.people,
        },
      ];
    },
  },
  {
    code: 'PARTNER_QUARTERLY',
    name: 'Partner quarterly report',
    content: 'All UM 7.2 measures, deals, engagements of one partner (PDF, one click).',
    filters: 'Partner, fiscal year, quarter',
    link: '/crm/partner-performance',
    viewPermission: 'partner_report.generate',
    sheets: null,
  },
  {
    code: 'WIN_LOSS',
    name: 'Win / loss analysis',
    content: 'Closed deals with reasons, competitors and lessons.',
    filters: 'Period, product, industry, partner, owner, competitor',
    link: '/crm/win-loss',
    viewPermission: 'winloss.view',
    async sheets({ userId, q }) {
      return [
        {
          name: 'Closed deals',
          columns: [
            col('Deal no', 'opportunityNo', 16),
            col('Title', 'title', 34),
            col('Account', 'accountName', 26),
            col('Owner', 'ownerName', 22),
            col('Outcome', 'stageCode', 10),
            money('Value (INR)', 'value'),
            date('Closed on', 'closedOn'),
            col('Loss reason', 'lossReason', 22),
            col('Competitor', 'competitor', 22),
            col('Win reasons', 'winReasons', 28),
            col('Partner', 'partnerName', 22),
            col('Detail', 'detail', 40),
          ],
          rows: await winLoss.exportRows(userId, q),
        },
      ];
    },
  },
  {
    code: 'ACCOUNT_360',
    name: 'Account 360',
    content: 'Every deal, contact, order and partner at one account.',
    filters: 'Account',
    link: '/crm/accounts',
    viewPermission: 'account.view',
    async sheets({ userId, q }) {
      if (!q.accountId)
        throw appError('VALIDATION_FAILED', 'Choose the account.', [
          { field: 'accountId', message: 'Required.' },
        ]);
      const a = await accounts.get360(userId, Number(q.accountId));
      return [
        {
          name: 'Deals',
          columns: [
            col('Deal no', 'opportunityNo', 16),
            col('Title', 'title', 34),
            col('Stage', 'stageName', 16),
            money('Value (INR)', 'value'),
            money('Weighted (INR)', 'weighted'),
            date('Expected close', 'expectedCloseDate'),
            date('Closed on', 'closedAt'),
            col('Owner', 'ownerName', 22),
          ],
          rows: a.opportunities,
        },
        {
          name: 'Contacts',
          columns: [
            col('Name', 'name', 24),
            col('Designation', 'designation', 22),
            col('Department', 'department', 18),
            col('Email', 'email', 28),
            col('Phone', 'phone', 16),
            col('Stand', 'stand', 12),
          ],
          rows: a.contacts,
        },
        {
          name: 'Orders',
          columns: [
            col('Order no', 'orderNo', 16),
            col('PO number', 'poNumber', 16),
            date('PO date', 'poDate'),
            money('PO value (INR)', 'poValue'),
            money('Invoiced (INR)', 'invoicedValue'),
            money('Received (INR)', 'receivedValue'),
          ],
          rows: a.orders,
        },
        {
          name: 'Partners',
          columns: [
            col('Partner', 'partnerName', 26),
            col('Roles', 'roles', 28),
            col('Deals', 'deals', 10),
          ],
          rows: a.partners,
        },
      ];
    },
  },
  {
    code: 'TENDER_PIPELINE',
    name: 'Tender pipeline',
    content: 'Tenders by status, dates, readiness and value.',
    filters: 'Status, owner',
    link: '/crm/tenders',
    viewPermission: 'tender.view',
    async sheets({ userId, q }) {
      const rows = await tenders.exportRows(userId, { sort: 'submissionOn', ...q });
      return [
        {
          name: 'Tenders',
          columns: [
            col('Tender no', 'tenderNo', 14),
            col('Authority', 'authority', 28),
            col('Title', 'title', 34),
            col('Account', 'accountName', 24),
            money('Estimated value (INR)', 'estimatedValue', 18),
            col('Status', 'statusName', 18),
            date('Submission', 'submissionOn'),
            { header: 'Readiness %', key: 'readinessPct', width: 12, format: Number },
            col('Owner', 'ownerName', 22),
          ],
          rows,
        },
      ];
    },
  },
  {
    code: 'PRODUCT_MIX',
    name: 'Product mix',
    content: 'Products per partner and per account (single vs multi product).',
    filters: 'Fiscal year, quarter, partner',
    link: '/crm/reports',
    viewPermission: 'report.view',
    async sheets({ userId, q }) {
      const [, byPartner, byAccount] = await reportsRepo.productMix(userId, q);
      const cols = [
        col('Deals', 'deals', 10),
        col('Won', 'won', 10),
        col('Products', 'products', 10),
        col('Product names', 'productNames', 40),
      ];
      return [
        {
          name: 'By partner',
          columns: [col('Partner', 'partnerName', 28), ...cols],
          rows: byPartner ?? [],
        },
        {
          name: 'By account',
          columns: [col('Account', 'accountName', 28), ...cols],
          rows: byAccount ?? [],
        },
      ];
    },
  },
  {
    code: 'REVENUE_GM',
    name: 'Revenue and GM',
    content: 'Revenue and gross margin by product, partner, industry or month.',
    filters: 'Fiscal year, quarter, dimension',
    link: '/crm/reports',
    viewPermission: 'report.view',
    async sheets({ userId, q }) {
      const [, rows] = await reportsRepo.revenueGm(userId, q);
      return [
        {
          name: 'Revenue and GM',
          columns: [
            col(q.dimension ?? 'PRODUCT', 'label', 28),
            col('Deals', 'deals', 10),
            money('Revenue (INR)', 'revenue'),
            money('Gross margin (INR)', 'grossMargin', 18),
            { header: 'GM %', key: 'gmPct', width: 8, format: Number },
            money('Revenue without GM (INR)', 'revenueWithoutGm', 22),
          ],
          rows: rows ?? [],
        },
      ];
    },
  },
  {
    code: 'PARTNER_SCORECARD',
    name: 'Partner scorecard',
    content: 'Scorecards, score and rating of every visible partner.',
    filters: 'Fiscal year, quarter, owner, type',
    link: '/crm/partner-performance',
    viewPermission: 'partner_performance.view',
    async sheets({ userId, q }) {
      const p = await partners.performance(userId, q);
      return [
        {
          name: 'Scorecards',
          columns: [
            col('Partner no', 'partnerNo', 14),
            col('Partner', 'partnerName', 28),
            col('Types', 'types', 22),
            col('Owner', 'ownerName', 22),
            col('Active deals', 'activeDeals', 12),
            money('Pipeline (INR)', 'pipeline'),
            col('Won', 'wonDeals', 8),
            col('Lost', 'lostDeals', 8),
            col('Win %', 'winPct', 8),
            money('Revenue (INR)', 'revenue'),
            col('On-time payment %', 'onTimePaymentPct', 16),
            col('Repeat', 'repeatBusiness', 8),
            col('New logos', 'newLogos', 10),
            col('Score', 'score', 8),
            col('Rating', 'rating', 8),
            col('Recommended tier', 'tierRecommendation', 16),
          ],
          rows: p.scorecards,
        },
      ];
    },
  },
];

module.exports = { REPORTS };
