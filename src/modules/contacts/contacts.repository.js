// @ts-check
'use strict';

/** Contacts write side (V017). */
const { callProcedureOne } = require('../../db/pool');

module.exports = {
  /**
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  create: (b, meta) =>
    callProcedureOne('sp_contact_create', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      b.accountId,
      b.partnerId,
      b.name,
      b.designation,
      b.department,
      b.email,
      b.phone,
      b.seniority,
      b.influenceLevel,
      b.stand,
      b.intelNotes,
      b.spocType,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  update: (id, b, meta) =>
    callProcedureOne('sp_contact_update', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.name,
      b.designation,
      b.department,
      b.email,
      b.phone,
      b.seniority,
      b.influenceLevel,
      b.stand,
      b.intelNotes,
      b.spocType,
    ]),

  /**
   * @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  deactivate: (id, meta) =>
    callProcedureOne('sp_contact_deactivate', [meta.actorUserId, meta.requestId, meta.ip, id]),
};
