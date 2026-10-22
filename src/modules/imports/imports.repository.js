// @ts-check
'use strict';

/** Import batches (V036 procedures). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} Meta */

module.exports = {
  lookups: () => callProcedure('sp_import_lookups', []),

  /**
   * @param {Meta} m @param {string} entity
   * @param {{ key: string, name: string, mime: string, size: number, sha256: string }} f
   * @param {unknown[]} rows
   */
  createBatch: (m, entity, f, rows) =>
    callProcedureOne('sp_import_batch_create', [
      m.actorUserId,
      entity,
      f.key,
      f.name,
      f.mime,
      f.size,
      f.sha256,
      JSON.stringify(rows),
    ]),

  /** @param {number} id */
  get: (id) => callProcedure('sp_import_batch_get', [id]),

  /**
   * @param {Meta} m @param {number} batchId @param {number} rowNo
   * @param {'CREATED' | 'SKIPPED' | 'INVALID'} status @param {number | null} entityId @param {string[] | null} errors
   */
  rowDone: (m, batchId, rowNo, status, entityId, errors) =>
    callProcedure('sp_import_row_done', [
      m.actorUserId,
      m.requestId,
      m.ip,
      batchId,
      rowNo,
      status,
      entityId,
      errors ? JSON.stringify(errors) : null,
    ]),

  /** @param {Meta} m @param {number} batchId @param {'COMMITTED' | 'FAILED'} status */
  finish: (m, batchId, status) =>
    callProcedure('sp_import_batch_finish', [m.actorUserId, batchId, status]),
};
