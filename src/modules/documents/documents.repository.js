// @ts-check
'use strict';

/** Documents: search (V010), upload / download / delete (V023). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} Meta */

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q  validated query plus offset / limit
   */
  async list(userId, q) {
    const [rows, totals, typeCounts, tags] = await callProcedure('sp_document_list', [
      userId,
      q.search ?? null,
      q.type ?? null,
      q.entityType ?? null,
      q.sharedWith ?? null,
      q.partnerId ?? null,
      q.accountId ?? null,
      q.tag ?? null,
      q.offset,
      q.limit,
    ]);
    return {
      rows: rows ?? [],
      total: Number(totals?.[0]?.total ?? 0),
      typeCounts: typeCounts ?? [],
      tags: tags ?? [],
    };
  },

  limits: () => callProcedureOne('sp_document_limits', []),

  /**
   * @param {any} b  validated body
   * @param {{ title: string, originalName: string, ext: string, mime: string, size: number, sha256: string, key: string }} f
   * @param {Meta} m
   */
  create: (b, f, m) =>
    callProcedureOne('sp_document_create', [
      m.actorUserId,
      m.requestId,
      m.ip,
      b.entityType,
      b.entityId,
      b.documentTypeCode,
      f.title,
      f.originalName,
      f.ext,
      f.mime,
      f.size,
      f.sha256,
      f.key,
      b.sharedWith,
      b.sharedWithPartnerId ?? null,
      b.sharedOn ?? null,
      b.notes,
      b.tags.length ? JSON.stringify(b.tags) : null,
    ]),

  /** @param {number} userId @param {number} id */
  file: (userId, id) => callProcedureOne('sp_document_file', [userId, id]),

  /** @param {number} id @param {{ tags?: string[], notes?: string | null }} b @param {Meta} m */
  update: (id, b, m) =>
    callProcedureOne('sp_document_update', [
      m.actorUserId,
      m.requestId,
      m.ip,
      id,
      b.notes !== undefined ? 1 : 0,
      b.notes ?? null,
      b.tags ? JSON.stringify(b.tags) : null,
    ]),

  /** @param {number} id @param {Meta} m @param {boolean} allowAny */
  remove: (id, m, allowAny) =>
    callProcedure('sp_document_delete', [m.actorUserId, m.requestId, m.ip, id, allowAny ? 1 : 0]),
};
