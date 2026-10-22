// @ts-check
'use strict';

/** Activities write side (V014 procedures). */
const { callProcedureOne } = require('../../db/pool');

module.exports = {
  /**
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  create: (b, meta) =>
    callProcedureOne('sp_activity_create', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      b.entityType,
      b.entityId,
      b.activityType,
      b.activityAt,
      b.subject,
      b.peopleMet,
      b.notes,
      b.outcome,
      b.nextAction,
      b.nextActionOn,
      b.nextActionOwnerId,
      b.contactIds !== null ? JSON.stringify(b.contactIds) : null,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  update: (id, b, meta, allowAny) =>
    callProcedureOne('sp_activity_update', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.activityType,
      b.activityAt,
      b.subject,
      b.peopleMet,
      b.notes,
      b.outcome,
      b.nextAction,
      b.nextActionOn,
      b.nextActionOwnerId,
      b.contactIds !== null ? JSON.stringify(b.contactIds) : null,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  delete: (id, meta, allowAny) =>
    callProcedureOne('sp_activity_delete', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      allowAny ? 1 : 0,
    ]),
};
