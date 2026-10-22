// @ts-check
'use strict';

/** Offers write side (V018 procedures). */
const { callProcedureOne } = require('../../db/pool');

module.exports = {
  /**
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  create: (b, meta, allowAny) =>
    callProcedureOne('sp_offer_create', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      b.opportunityId,
      b.offerValue,
      b.listValue,
      b.discountPct,
      b.valueAdds,
      b.paymentTerms,
      b.validTill,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  update: (id, b, meta, allowAny) =>
    callProcedureOne('sp_offer_update', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.offerValue,
      b.listValue,
      b.discountPct,
      b.valueAdds,
      b.paymentTerms,
      b.validTill,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  submit: (id, meta, allowAny) =>
    callProcedureOne('sp_offer_submit', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  approve: (id, b, meta) =>
    callProcedureOne('sp_offer_approve', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.approved ? 1 : 0,
      b.approvalRemark,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  send: (id, b, meta, allowAny) =>
    callProcedureOne('sp_offer_send', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.sentTo,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  respond: (id, b, meta, allowAny) =>
    callProcedureOne('sp_offer_respond', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.accepted ? 1 : 0,
      b.customerResponse,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  revise: (id, meta, allowAny) =>
    callProcedureOne('sp_offer_revise', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      allowAny ? 1 : 0,
    ]),
};
