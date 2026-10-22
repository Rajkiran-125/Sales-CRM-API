// @ts-check
'use strict';

/** Masters and stages (V006 procedures). */
const { callProcedure } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} RequestMeta */

/** @param {RequestMeta} m */
const ctx = (m) => [m.actorUserId, m.requestId, m.ip];

/**
 * @param {string} name
 * @param {unknown[]} params
 */
const rows = async (name, params) => (await callProcedure(name, params))[0] ?? [];

module.exports = {
  simple: {
    /** @param {string} type @param {boolean} inactive */
    list: (type, inactive) => rows('sp_master_simple_list', [type, inactive ? 1 : 0]),
    /** @param {string} type @param {any} b @param {RequestMeta} m */
    create: async (type, b, m) =>
      (await rows('sp_master_simple_create', [...ctx(m), type, b.code, b.name, b.sortOrder]))[0],
    /** @param {string} type @param {number} id @param {any} b @param {RequestMeta} m */
    update: async (type, id, b, m) =>
      (
        await rows('sp_master_simple_update', [
          ...ctx(m),
          type,
          id,
          b.name,
          b.sortOrder,
          b.isActive ? 1 : 0,
        ])
      )[0],
  },
  solution: {
    /** @param {any} q @param {boolean} inactive */
    list: (q, inactive) => rows('sp_solution_list', [q.productId ?? null, inactive ? 1 : 0]),
    /** @param {any} b @param {RequestMeta} m */
    create: async (b, m) =>
      (
        await rows('sp_solution_create', [
          ...ctx(m),
          b.productId,
          b.name,
          b.description,
          b.sortOrder,
        ])
      )[0],
    /** @param {number} id @param {any} b @param {RequestMeta} m */
    update: async (id, b, m) =>
      (
        await rows('sp_solution_update', [
          ...ctx(m),
          id,
          b.name,
          b.description,
          b.sortOrder,
          b.isActive ? 1 : 0,
        ])
      )[0],
  },
  reason: {
    /** @param {any} q @param {boolean} inactive */
    list: (q, inactive) => rows('sp_reason_list', [q.reasonType ?? null, inactive ? 1 : 0]),
    /** @param {any} b @param {RequestMeta} m */
    create: async (b, m) =>
      (
        await rows('sp_reason_create', [
          ...ctx(m),
          b.reasonType,
          b.code,
          b.name,
          b.category,
          b.competitorRequired ? 1 : 0,
          b.sortOrder,
        ])
      )[0],
    /** @param {number} id @param {any} b @param {RequestMeta} m */
    update: async (id, b, m) =>
      (
        await rows('sp_reason_update', [
          ...ctx(m),
          id,
          b.name,
          b.category,
          b.competitorRequired ? 1 : 0,
          b.sortOrder,
          b.isActive ? 1 : 0,
        ])
      )[0],
  },
  competitor: {
    /** @param {any} _q @param {boolean} inactive */
    list: (_q, inactive) => rows('sp_competitor_list', [inactive ? 1 : 0]),
    /** @param {any} b @param {RequestMeta} m */
    create: async (b, m) =>
      (
        await rows('sp_competitor_create', [
          ...ctx(m),
          b.name,
          b.products,
          b.strengths,
          b.weaknesses,
        ])
      )[0],
    /** @param {number} id @param {any} b @param {RequestMeta} m */
    update: async (id, b, m) =>
      (
        await rows('sp_competitor_update', [
          ...ctx(m),
          id,
          b.name,
          b.products,
          b.strengths,
          b.weaknesses,
          b.isActive ? 1 : 0,
        ])
      )[0],
  },
  procurementStep: {
    /** @param {any} q @param {boolean} inactive */
    list: (q, inactive) =>
      rows('sp_procurement_step_list', [q.procurementTypeId ?? null, inactive ? 1 : 0]),
    /** @param {any} b @param {RequestMeta} m */
    create: (b, m) =>
      rows('sp_procurement_step_create', [
        ...ctx(m),
        b.procurementTypeId,
        b.sequenceNo,
        b.name,
        b.hintConfidencePct,
      ]),
    /** @param {number} id @param {any} b @param {RequestMeta} m */
    update: (id, b, m) =>
      rows('sp_procurement_step_update', [
        ...ctx(m),
        id,
        b.sequenceNo,
        b.name,
        b.hintConfidencePct,
        b.isActive ? 1 : 0,
      ]),
  },
  stage: {
    /** @param {any} q */
    list: (q) => rows('sp_stage_list', [q.entity ?? null]),
    /** @param {number} id @param {any} b @param {RequestMeta} m */
    update: (id, b, m) =>
      rows('sp_stage_update', [
        ...ctx(m),
        id,
        b.name,
        b.defaultConfidencePct,
        b.slaDays,
        b.colourToken,
      ]),
  },
};
