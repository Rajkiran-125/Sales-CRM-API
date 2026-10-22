// @ts-check
'use strict';

/** Tasks (V008 read, V016 write). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

module.exports = {
  /**
   * @param {number} userId
   * @param {boolean} canValidate
   * @param {boolean} canApprove
   */
  myDay: (userId, canValidate, canApprove) =>
    callProcedure('sp_task_my_day', [userId, canValidate ? 1 : 0, canApprove ? 1 : 0]),

  /**
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  create: (b, meta) =>
    callProcedureOne('sp_task_create', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      b.entityType,
      b.entityId,
      b.title,
      b.description,
      b.ownerUserId,
      b.dueAt,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  update: (id, b, meta, allowAny) =>
    callProcedureOne('sp_task_update', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.title,
      b.description,
      b.dueAt,
      b.ownerUserId,
      b.status,
      allowAny ? 1 : 0,
    ]),
};
