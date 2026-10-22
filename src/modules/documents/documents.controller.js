// @ts-check
'use strict';

/** Documents (12.13): HTTP only. */
const service = require('./documents.service');
const storage = require('../../integrations/fileStorage');
const { sendData, sendList } = require('../../shared/response');
const auditRepo = require('../audit/audit.repository');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any, user: any, files?: Express.Multer.File[] }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async list(req, res) {
    const r = /** @type {Req} */ (req);
    const { rows, meta } = await service.list(r.user.id, r.valid.query);
    sendList(req, res, rows, meta);
  },

  /** @type {import('../../shared/types').Handler} */
  async upload(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.upload(r.files ?? [], r.valid.body, requestMeta(req)), 201);
  },

  /** Served only here, always as an attachment (17.9). @type {import('../../shared/types').Handler} */
  async download(req, res) {
    const r = /** @type {Req} */ (req);
    const id = r.valid.params.id;
    const f = await service.file(r.user.id, id);
    const meta = requestMeta(req);
    await auditRepo.recordAccess({
      userId: r.user.id,
      entityType: 'DOCUMENT',
      entityId: id,
      accessType: 'DOWNLOAD',
      ip: meta.ip ?? '',
      requestId: meta.requestId,
    });
    res.setHeader('Content-Type', f.mimeType);
    res.setHeader('Content-Length', String(f.sizeBytes));
    res.setHeader(
      'Content-Disposition',
      `attachment; filename*=UTF-8''${encodeURIComponent(f.originalName)}`,
    );
    res.setHeader('Cache-Control', 'private, no-store');
    await new Promise((resolve, reject) => {
      storage.stream(f.storageKey).on('error', reject).pipe(res).on('finish', resolve);
    });
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.update(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async remove(req, res) {
    const r = /** @type {Req} */ (req);
    await service.remove(r.valid.params.id, requestMeta(req), r.user.dataScope.widest === 'ALL');
    res.status(204).end();
  },
};
