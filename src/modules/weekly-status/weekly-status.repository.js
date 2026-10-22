// @ts-check
'use strict';

const { callProcedureOne } = require('../../db/pool');

/**
 * @param {any} b   validated body
 * @param {import('../../shared/requestMeta').RequestMeta} meta
 * @param {boolean} allowAny
 */
function upsert(b, meta, allowAny) {
  return callProcedureOne('sp_weekly_status_upsert', [
    meta.actorUserId,
    meta.requestId,
    meta.ip,
    b.opportunityId,
    b.weekStart,
    b.status,
    b.thisWeek,
    b.nextStep,
    b.expectedCloseDate,
    b.closeChangeReason,
    b.expectedValue,
    allowAny ? 1 : 0,
  ]);
}

/**
 * @param {number} id
 * @param {import('../../shared/requestMeta').RequestMeta} meta
 * @param {boolean} allowAny
 */
function del(id, meta, allowAny) {
  return callProcedureOne('sp_weekly_status_delete', [
    meta.actorUserId,
    meta.requestId,
    meta.ip,
    id,
    allowAny ? 1 : 0,
  ]);
}

module.exports = { upsert, del };
