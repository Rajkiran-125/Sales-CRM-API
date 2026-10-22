// @ts-check
'use strict';

/** Partners and partner performance: HTTP only. */
const service = require('./partners.service');
const { sendData, sendList } = require('../../shared/response');
const { logView, logExport } = require('../../shared/readModel');
const { requestMeta } = require('../../shared/requestMeta');
const { sendWorkbook } = require('../../integrations/excel');
const { appError } = require('../../shared/errors');
const { runJob } = require('../../jobs/scheduler');
const partnerPerformanceJob = require('../../jobs/partnerPerformance.job');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

const allowAny = (/** @type {Req} */ r) => r.user.dataScope.widest === 'ALL';

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async list(req, res) {
    const r = /** @type {Req} */ (req);
    const { rows, meta } = await service.list(r.user.id, r.valid.query);
    sendList(req, res, rows, meta);
  },

  /** @type {import('../../shared/types').Handler} */
  async get(req, res) {
    const r = /** @type {Req} */ (req);
    const id = r.valid.params.id;
    const data = await service.get(r.user.id, id);
    await logView(req, 'PARTNER', id);
    sendData(req, res, data);
  },

  /** @type {import('../../shared/types').Handler} */
  async engagementSave(req, res) {
    const r = /** @type {Req} */ (req);
    const { id, engagementId } = r.valid.params;
    const data = await service.engagementSave(
      id,
      engagementId ?? null,
      r.valid.body,
      requestMeta(req),
      allowAny(r),
    );
    sendData(req, res, data, engagementId ? 200 : 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async accountMapSave(req, res) {
    const r = /** @type {Req} */ (req);
    const { id, rowId } = r.valid.params;
    const data = await service.accountMapSave(
      id,
      rowId ?? null,
      r.valid.body,
      requestMeta(req),
      allowAny(r),
    );
    sendData(req, res, data, rowId ? 200 : 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async accountMapDelete(req, res) {
    const r = /** @type {Req} */ (req);
    await service.accountMapDelete(
      r.valid.params.id,
      r.valid.params.rowId,
      requestMeta(req),
      allowAny(r),
    );
    res.status(204).end();
  },

  /** @type {import('../../shared/types').Handler} */
  async customerCodeSave(req, res) {
    const r = /** @type {Req} */ (req);
    const { id, codeId } = r.valid.params;
    const data = await service.customerCodeSave(
      id,
      codeId ?? null,
      r.valid.body,
      requestMeta(req),
      allowAny(r),
    );
    sendData(req, res, data, codeId ? 200 : 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async customerCodeDelete(req, res) {
    const r = /** @type {Req} */ (req);
    await service.customerCodeDelete(
      r.valid.params.id,
      r.valid.params.codeId,
      requestMeta(req),
      allowAny(r),
    );
    res.status(204).end();
  },

  /** @type {import('../../shared/types').Handler} */
  async duplicates(req, res) {
    sendData(req, res, await service.duplicates(/** @type {Req} */ (req).valid.query));
  },

  /** @type {import('../../shared/types').Handler} */
  async create(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.create(r.valid.body, requestMeta(req), allowAny(r)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async editGet(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.editGet(r.user.id, r.valid.params.id));
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.saveSection(r.valid.params.id, r.valid.body, requestMeta(req), allowAny(r)),
    );
  },

  /** Needs partner.view as well as report.export (the route checks the second). @type {import('../../shared/types').Handler} */
  async exportList(req, res) {
    const r = /** @type {Req} */ (req);
    if (!r.user.permissions.has('partner.view')) {
      throw appError('FORBIDDEN', 'You do not have permission to view partners.');
    }
    const q = r.valid.query;
    const rows = await service.exportRows(r.user.id, q);
    await logExport(req, 'PARTNER', q);
    const date = (/** @type {any} */ v) => (v ? String(v).slice(0, 10) : '');
    await sendWorkbook(
      res,
      'partners',
      'Partners',
      [
        { header: 'Partner no', key: 'partnerNo', width: 14 },
        { header: 'Name', key: 'name', width: 32 },
        { header: 'Legal name', key: 'legalName', width: 36 },
        { header: 'Types', key: 'types', width: 24 },
        { header: 'Tier', key: 'tier', width: 14 },
        { header: 'City', key: 'city', width: 16 },
        { header: 'Owner', key: 'ownerName', width: 22 },
        { header: 'Agreement', key: 'agreementStatus', width: 14 },
        { header: 'Agreement valid till', key: 'agreementValidTill', width: 14, format: date },
        { header: 'Completeness %', key: 'completenessPct', width: 14 },
        { header: 'Active deals', key: 'activeDeals', width: 12, format: Number },
        { header: 'Pipeline (INR)', key: 'pipeline', width: 16, format: Number },
        { header: 'Won deals', key: 'wonDeals', width: 11, format: Number },
        { header: 'Won value (INR)', key: 'wonValue', width: 16, format: Number },
        { header: 'Win %', key: 'winPct', width: 9 },
        { header: 'Rating', key: 'rating', width: 8 },
        { header: 'Last engagement', key: 'lastEngagementOn', width: 14, format: date },
        { header: 'Next engagement', key: 'nextEngagementOn', width: 14, format: date },
      ],
      rows,
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async quarterlyReport(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.quarterlyReport(r.valid.params.id, r.valid.body, requestMeta(req)),
      201,
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async quarterlyReports(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.quarterlyReports(r.user.id, r.valid.params.id));
  },

  /** Runs under the job lock, like the nightly run. @type {import('../../shared/types').Handler} */
  async recompute(req, res) {
    const result = await runJob(partnerPerformanceJob);
    if (result.status === 'LOCKED') {
      throw appError('CONFLICT', 'A recompute is already running. Try again in a few minutes.');
    }
    if (result.status === 'FAILED') throw new Error(result.error);
    sendData(req, res, { partners: result.processed });
  },

  /** @type {import('../../shared/types').Handler} */
  async performance(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.performance(r.user.id, r.valid.query));
  },

  /** @type {import('../../shared/types').Handler} */
  async performanceOne(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.performanceOne(r.user.id, r.valid.params.partnerId, r.valid.query),
    );
  },
};
