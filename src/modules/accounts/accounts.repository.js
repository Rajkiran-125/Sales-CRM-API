// @ts-check
'use strict';

/** Accounts: read side (V008), write side (V020). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** The account fields in sp_account_create / sp_account_update order. @param {any} b */
const fields = (b) => [
  b.name,
  b.legalName,
  b.industryId,
  b.segment,
  b.accountType,
  b.isStrategic ? 1 : 0,
  b.country,
  b.state,
  b.city,
  b.address,
  b.website,
  b.gstNo,
  b.panNo,
  b.locationsCount,
  b.existingVendor,
  b.ownerUserId,
  b.backupOwnerUserId,
  b.notes,
  b.ignoreDuplicates ? 1 : 0,
];

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q  validated query plus offset / limit
   */
  async list(userId, q) {
    const [rows, totals] = await callProcedure('sp_account_list', [
      userId,
      q.search ?? null,
      q.type ?? null,
      q.industryId ?? null,
      q.ownerUserId ?? null,
      q.sort,
      q.offset,
      q.limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0) };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  get: (userId, id) => callProcedure('sp_account_get', [userId, id]),

  /**
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny  ALL-scope actor
   */
  create: (b, meta, allowAny) =>
    callProcedureOne('sp_account_create', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      ...fields(b),
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny  ALL-scope actor
   */
  update: (id, b, meta, allowAny) =>
    callProcedureOne('sp_account_update', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.rowVersion,
      ...fields(b),
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id  merged away
   * @param {number} survivorId
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  merge: (id, survivorId, meta) =>
    callProcedureOne('sp_account_merge', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      survivorId,
    ]),
};
