// @ts-check
'use strict';

/** Partners, competitors and partner commercial on a deal (V022). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} Meta */

/** @param {Meta} m */
const who = (m) => [m.actorUserId, m.requestId, m.ip];

module.exports = {
  /** @param {number} id @param {any} b @param {Meta} m */
  partnerAdd: (id, b, m) =>
    callProcedureOne('sp_opportunity_partner_add', [
      ...who(m),
      id,
      b.partnerId,
      b.partnerRole,
      b.partnerContactId,
      b.engagementLevel,
      b.isPrimary ? 1 : 0,
      b.commercialConfirmed ? 1 : 0,
      b.notes,
    ]),

  /** @param {number} id @param {number} rowId @param {any} b @param {Meta} m */
  partnerUpdate: (id, rowId, b, m) =>
    callProcedureOne('sp_opportunity_partner_update', [
      ...who(m),
      id,
      rowId,
      b.partnerRole,
      b.partnerContactId,
      b.engagementLevel,
      b.isPrimary ? 1 : 0,
      b.commercialConfirmed ? 1 : 0,
      b.notes,
    ]),

  /** @param {number} id @param {number} rowId @param {Meta} m */
  partnerRemove: (id, rowId, m) =>
    callProcedure('sp_opportunity_partner_remove', [...who(m), id, rowId]),

  /** @param {number} id @param {any} b @param {Meta} m */
  competitorAdd: (id, b, m) =>
    callProcedureOne('sp_opportunity_competitor_add', [
      ...who(m),
      id,
      b.competitorId,
      b.theirPrice,
      b.theirStrength,
      b.ourDifferentiator,
    ]),

  /** @param {number} id @param {number} rowId @param {any} b @param {Meta} m */
  competitorUpdate: (id, rowId, b, m) =>
    callProcedureOne('sp_opportunity_competitor_update', [
      ...who(m),
      id,
      rowId,
      b.theirPrice,
      b.theirStrength,
      b.ourDifferentiator,
    ]),

  /** @param {number} id @param {number} rowId @param {Meta} m */
  competitorRemove: (id, rowId, m) =>
    callProcedure('sp_opportunity_competitor_remove', [...who(m), id, rowId]),

  /** @param {number} id @param {any} b @param {Meta} m */
  commercialCreate: (id, b, m) =>
    callProcedureOne('sp_partner_commercial_create', [
      ...who(m),
      id,
      b.partnerId,
      b.partnerRole,
      b.dealSizeBasis,
      b.priceToPartner,
      b.partnerMarginPct,
      b.paymentTerms,
      b.payPartnerAfterCustomer ? 1 : 0,
      b.validTill,
      b.bundleTag,
      b.remarks,
    ]),
};
