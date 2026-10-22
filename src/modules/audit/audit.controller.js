// @ts-check
'use strict';

/**
 * Security and data audit viewer (18.5, M02): read-only, paged, exportable. Every export
 * is itself logged as an EXPORT access (19.2).
 */
const repo = require('./audit.repository');
const { sendWorkbook } = require('../../integrations/excel');
const { sendList } = require('../../shared/response');
const { logExport } = require('../../shared/readModel');

const EXPORT_LIMIT = 10000;

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

/** @param {any} q */
const window = (q) => ({ ...q, offset: (q.page - 1) * q.pageSize, limit: q.pageSize });

/** @param {Date | string | null} v */
const iso = (v) => (v ? new Date(v).toISOString() : '');

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async auditLogs(req, res) {
    const q = /** @type {Req} */ (req).valid.query;
    const { rows, total } = await repo.auditLogs(window(q));
    sendList(req, res, rows, { page: q.page, pageSize: q.pageSize, total });
  },

  /** @type {import('../../shared/types').Handler} */
  async securityEvents(req, res) {
    const q = /** @type {Req} */ (req).valid.query;
    const { rows, total } = await repo.securityEvents(window(q));
    sendList(req, res, rows, { page: q.page, pageSize: q.pageSize, total });
  },

  /** @type {import('../../shared/types').Handler} */
  async recordAccessLogs(req, res) {
    const q = /** @type {Req} */ (req).valid.query;
    const { rows, total } = await repo.recordAccessLogs(window(q));
    sendList(req, res, rows, { page: q.page, pageSize: q.pageSize, total });
  },

  /** @type {import('../../shared/types').Handler} */
  async exportAuditLogs(req, res) {
    const q = /** @type {Req} */ (req).valid.query;
    const { rows } = await repo.auditLogs({ ...q, offset: 0, limit: EXPORT_LIMIT });
    await logExport(req, 'AUDIT_LOG', q);
    await sendWorkbook(
      res,
      'audit-log',
      'Audit log',
      [
        { header: 'When (UTC)', key: 'occurredAt', width: 24, format: iso },
        { header: 'User', key: 'userName', width: 24 },
        { header: 'Entity', key: 'entityType', width: 18 },
        { header: 'Record', key: 'entityId', width: 12 },
        { header: 'Action', key: 'action', width: 16 },
        { header: 'Changes', key: 'changes', width: 80 },
        { header: 'Reason', key: 'reason', width: 30 },
        { header: 'IP', key: 'ipAddress', width: 16 },
        { header: 'Request id', key: 'requestId', width: 38 },
      ],
      rows,
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async exportSecurityEvents(req, res) {
    const q = /** @type {Req} */ (req).valid.query;
    const { rows } = await repo.securityEvents({ ...q, offset: 0, limit: EXPORT_LIMIT });
    await logExport(req, 'SECURITY_EVENT', q);
    await sendWorkbook(
      res,
      'security-events',
      'Security events',
      [
        { header: 'When (UTC)', key: 'occurredAt', width: 24, format: iso },
        { header: 'Event', key: 'eventCode', width: 26 },
        { header: 'By', key: 'userName', width: 24 },
        { header: 'Target user', key: 'targetUserName', width: 24 },
        { header: 'Detail', key: 'detail', width: 60 },
        { header: 'IP', key: 'ipAddress', width: 16 },
        { header: 'Request id', key: 'requestId', width: 38 },
      ],
      rows,
    );
  },
};
