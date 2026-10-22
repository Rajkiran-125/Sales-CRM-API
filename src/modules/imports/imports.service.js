// @ts-check
'use strict';

/**
 * Data import (12.17), partners first: template → upload (every row checked, stored as a
 * PREVIEW batch: the dry run) → commit (valid rows created through sp_partner_create, a
 * duplicate that appeared since the preview is skipped, each record audited IMPORTED). Users,
 * accounts and the trial records come in Phase 4.
 */
const ExcelJS = require('exceljs');
const repo = require('./imports.repository');
const rules = require('./imports.partners');
const partnersRepo = require('../partners/partners.repository');
const storage = require('../../integrations/fileStorage');
const { workbookBuffer } = require('../../integrations/excel');
const { contentMatches } = require('../documents/documents.upload');
const { appError } = require('../../shared/errors');

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

/**
 * The CRM duplicate search of V030 for one row.
 * @param {{ name: string, gstNo: string, website: string }} r
 * @returns {Promise<any>}
 */
async function inCrm(r) {
  const [rows] = await partnersRepo.duplicates({
    name: r.name || null,
    gstNo: r.gstNo || null,
    website: r.website || null,
  });
  return rows?.[0] ?? null;
}

/** @param {any} v */
const parseJson = (v) => (typeof v === 'string' ? JSON.parse(v) : v);

module.exports = {
  /** The partner template: header and one example row. */
  template: () => workbookBuffer('Partners', rules.COLUMNS, [rules.EXAMPLE]),

  /**
   * @param {Express.Multer.File | undefined} file
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async upload(file, meta) {
    if (!file)
      throw appError('VALIDATION_FAILED', 'Choose the filled template (.xlsx).', [
        { field: 'file', message: 'Required.' },
      ]);
    if (!/\.xlsx$/i.test(file.originalname) || !contentMatches('xlsx', file.buffer))
      throw appError('UNSUPPORTED_FILE_TYPE', 'Upload the template as an .xlsx file.');
    const wb = new ExcelJS.Workbook();
    try {
      await wb.xlsx.load(/** @type {any} */ (file.buffer));
    } catch {
      throw appError('UNSUPPORTED_FILE_TYPE', 'The file could not be read as an Excel workbook.');
    }
    const sheet = wb.worksheets[0];
    const rows = sheet ? rules.readRows(sheet) : [];
    if (!rows.length)
      throw appError('VALIDATION_FAILED', 'The sheet has no data rows.', [
        { field: 'file', message: 'No rows.' },
      ]);
    if (rows.length > rules.MAX_ROWS)
      throw appError('VALIDATION_FAILED', `At most ${rules.MAX_ROWS} rows per file.`, [
        { field: 'file', message: 'Too many rows.' },
      ]);

    const [types, users] = await repo.lookups();
    const checked = await rules.checkRows(rows, /** @type {any} */ ({ types, users }), inCrm);
    const { key, sha256 } = await storage.save(file.buffer);
    try {
      const row = await repo.createBatch(
        meta,
        'PARTNER',
        { key, name: file.originalname.slice(0, 255), mime: XLSX, size: file.size, sha256 },
        checked,
      );
      return this.get(Number(row?.id));
    } catch (err) {
      await storage.remove(key);
      throw err;
    }
  },

  /** @param {number} id */
  async get(id) {
    const [[batch], rows] = await repo.get(id);
    return {
      ...batch,
      rows: (rows ?? []).map((r) => ({
        rowNo: r.rowNo,
        raw: parseJson(r.raw),
        status: r.status,
        errors: parseJson(r.errors),
        createdEntityId: r.createdEntityId,
      })),
    };
  },

  /**
   * Create the valid rows of a preview batch. Each row stands alone: one failing row is
   * recorded with its message and the rest go on.
   * @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async commit(id, meta) {
    const [[batch], rows] = await repo.get(id);
    if (batch.status !== 'PREVIEW')
      throw appError('VALIDATION_FAILED', 'This batch was already committed.', [
        { field: 'id', message: batch.status },
      ]);
    for (const r of rows ?? []) {
      if (r.status !== 'VALID') continue;
      const mapped = parseJson(r.mapped);
      const dup = await inCrm({
        name: mapped.legalName,
        gstNo: mapped.gstNo ?? '',
        website: mapped.website ?? '',
      });
      if (dup) {
        await repo.rowDone(meta, id, r.rowNo, 'SKIPPED', null, [
          `Already in the CRM: ${dup.name} (${dup.partnerNo}).`,
        ]);
        continue;
      }
      try {
        const created = await partnersRepo.create(mapped, meta, true);
        await repo.rowDone(meta, id, r.rowNo, 'CREATED', Number(created.id), null);
      } catch (err) {
        await repo.rowDone(meta, id, r.rowNo, 'INVALID', null, [
          /** @type {Error} */ (err).message,
        ]);
      }
    }
    await repo.finish(meta, id, 'COMMITTED');
    return this.get(id);
  },
};
