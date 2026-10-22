// @ts-check
'use strict';

/** Custom fields (V032 procedures). */
const { callProcedure } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} Meta */

module.exports = {
  /** @param {string | null} entity @param {boolean} includeInactive */
  list: (entity, includeInactive) =>
    callProcedure('sp_custom_field_list', [entity, includeInactive ? 1 : 0]),

  /** @param {number | null} id @param {any} b @param {Meta} m */
  save: (id, b, m) =>
    callProcedure('sp_custom_field_save', [
      m.actorUserId,
      m.requestId,
      m.ip,
      id,
      b.entity ?? null,
      b.section,
      b.fieldKey ?? null,
      b.label,
      b.fieldType ?? null,
      b.options ? JSON.stringify(b.options) : null,
      b.isMandatory ? 1 : 0,
      b.isFilterable ? 1 : 0,
      b.sortOrder,
      b.helpText,
      b.isActive ? 1 : 0,
    ]),

  /** @param {number} userId @param {string} entity @param {number} recordId */
  values: (userId, entity, recordId) =>
    callProcedure('sp_custom_field_values_get', [userId, entity, recordId]),

  /**
   * @param {string} entity @param {number} recordId
   * @param {Array<Record<string, unknown>>} typed  [{fieldId, text|number|date|bool|json}]
   * @param {Meta} m @param {boolean} allowAny
   */
  saveValues: (entity, recordId, typed, m, allowAny) =>
    callProcedure('sp_custom_field_values_save', [
      m.actorUserId,
      m.requestId,
      m.ip,
      entity,
      recordId,
      JSON.stringify(typed),
      allowAny ? 1 : 0,
    ]),
};
