// @ts-check
'use strict';

/** Reports (19.1): HTTP only. */
const service = require('./reports.service');
const { REPORTS } = require('./reports.catalogue');
const { sendData } = require('../../shared/response');
const { logExport } = require('../../shared/readModel');
const { sendSheets } = require('../../integrations/excel');
const { appError } = require('../../shared/errors');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** The catalogue, only the reports the user may open. @type {import('../../shared/types').Handler} */
  async catalogue(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      REPORTS.filter((x) => r.user.permissions.has(x.viewPermission)).map((x) => ({
        code: x.code,
        name: x.name,
        content: x.content,
        filters: x.filters,
        link: x.link,
        output: x.sheets ? 'SCREEN_EXCEL' : 'PDF',
      })),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async get(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.get(r.user.id, r.valid.params.code, r.valid.query));
  },

  /** Excel of one report with the screen's figures and scope; logged (19.2). @type {import('../../shared/types').Handler} */
  async exportReport(req, res) {
    const r = /** @type {Req} */ (req);
    const report = /** @type {any} */ (REPORTS.find((x) => x.code === r.valid.params.code));
    if (!r.user.permissions.has(report.viewPermission))
      throw appError('FORBIDDEN', 'You do not have permission to view this report.');
    if (!report.sheets)
      throw appError('VALIDATION_FAILED', 'This report is a PDF: generate it from the partner.', [
        { field: 'code', message: 'Not an Excel report.' },
      ]);
    const q = r.valid.query;
    const sheets = await report.sheets({ userId: r.user.id, permissions: r.user.permissions, q });
    await logExport(req, `REPORT_${report.code}`, q);
    await sendSheets(res, report.code.toLowerCase().replace(/_/g, '-'), sheets);
  },
};
