// @ts-check
'use strict';

/**
 * Custom fields (12.15, OD-45): the CRM Admin defines fields per entity (partner fields per
 * section); the API checks every value against its definition and the mandatory fields of the
 * section being saved (BR-PT-06) before the procedure stores it.
 */
const repo = require('./customFields.repository');
const { appError } = require('../../shared/errors');

/** @typedef {{ id: number, entity: string, section: string | null, fieldKey: string, label: string, fieldType: string, options: string[] | null, isMandatory: boolean, isFilterable: boolean, sortOrder: number, helpText: string | null, isActive: boolean }} FieldDef */

/** @param {any} r @returns {FieldDef} */
const shapeDef = (r) => ({
  ...r,
  id: Number(r.id),
  options: typeof r.options === 'string' ? JSON.parse(r.options) : (r.options ?? null),
  isMandatory: Boolean(Number(r.isMandatory)),
  isFilterable: Boolean(Number(r.isFilterable)),
  isActive: Boolean(Number(r.isActive)),
});

/** @param {unknown} v */
const isEmpty = (v) =>
  v === null || v === undefined || v === '' || (Array.isArray(v) && v.length === 0);

/**
 * One value as the typed column the procedure stores (only that key is sent, so the other
 * columns read as SQL NULL), or a message.
 * @param {FieldDef} d
 * @param {unknown} v
 * @returns {{ col: Record<string, unknown> } | { error: string }}
 */
function typed(d, v) {
  if (isEmpty(v)) return { col: {} };
  const opts = d.options ?? [];
  switch (d.fieldType) {
    case 'TEXT':
    case 'LONG_TEXT': {
      const max = d.fieldType === 'TEXT' ? 1000 : 10000;
      if (typeof v !== 'string') return { error: 'Must be text.' };
      if (v.trim().length > max) return { error: `At most ${max} characters.` };
      return { col: { text: v.trim() } };
    }
    case 'NUMBER':
    case 'MONEY':
      if (typeof v !== 'number' || !Number.isFinite(v)) return { error: 'Must be a number.' };
      if (d.fieldType === 'MONEY' && v < 0) return { error: 'Must be zero or more.' };
      if (Math.abs(v) >= 1e14) return { error: 'Too large.' };
      return { col: { number: v } };
    case 'DATE':
      if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v) || Number.isNaN(Date.parse(v)))
        return { error: 'Must be a date (YYYY-MM-DD).' };
      return { col: { date: v } };
    case 'YES_NO':
      if (typeof v !== 'boolean') return { error: 'Must be yes or no.' };
      return { col: { bool: v ? 1 : 0 } };
    case 'SINGLE_SELECT':
      if (typeof v !== 'string' || !opts.includes(v))
        return { error: 'Choose one of the options.' };
      return { col: { text: v } };
    case 'MULTI_SELECT':
      if (!Array.isArray(v) || !v.every((x) => typeof x === 'string' && opts.includes(x)))
        return { error: 'Choose from the options.' };
      return { col: { json: [...new Set(v)] } };
    case 'URL':
      if (typeof v !== 'string' || v.length > 1000 || !/^https?:\/\/\S+\.\S+$/i.test(v.trim()))
        return { error: 'Must be a web address starting with http:// or https://.' };
      return { col: { text: v.trim() } };
    case 'EMAIL':
      if (typeof v !== 'string' || v.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim()))
        return { error: 'Must be an email address.' };
      return { col: { text: v.trim() } };
    default:
      return { error: 'Unknown field type.' };
  }
}

/**
 * Check the sent values against the active definitions in scope; mandatory fields of the
 * scope must be sent and filled.
 * @param {FieldDef[]} defs  active definitions in scope (the section, or the whole entity)
 * @param {Record<string, unknown>} values
 */
function typedValues(defs, values) {
  const byKey = new Map(defs.map((d) => [d.fieldKey, d]));
  /** @type {{ field: string, message: string }[]} */
  const errors = [];
  const out = [];
  for (const [key, v] of Object.entries(values)) {
    const d = byKey.get(key);
    if (!d) {
      errors.push({ field: key, message: 'Unknown or inactive field.' });
      continue;
    }
    const r = typed(d, v);
    if ('error' in r) errors.push({ field: key, message: r.error });
    else out.push({ fieldId: d.id, ...r.col });
  }
  for (const d of defs) {
    if (d.isMandatory && isEmpty(values[d.fieldKey]))
      errors.push({ field: d.fieldKey, message: `${d.label} is required.` });
  }
  if (errors.length) throw appError('VALIDATION_FAILED', 'Some fields are not valid.', errors);
  return out;
}

/**
 * A stored row in the shape the UI edits.
 * @param {FieldDef} d
 * @param {any} row
 */
function untyped(d, row) {
  switch (d.fieldType) {
    case 'NUMBER':
    case 'MONEY':
      return row.valueNumber === null ? null : Number(row.valueNumber);
    case 'DATE': {
      const v = row.valueDate;
      if (!v) return null;
      return v instanceof Date ? v.toISOString().slice(0, 10) : String(v).slice(0, 10);
    }
    case 'YES_NO':
      return row.valueBool === null ? null : Boolean(Number(row.valueBool));
    case 'MULTI_SELECT':
      return typeof row.valueJson === 'string' ? JSON.parse(row.valueJson) : (row.valueJson ?? []);
    default:
      return row.valueText;
  }
}

/** Who may change values of an entity (the procedure checks the record's visibility). */
const EDIT_PERMISSION = {
  PARTNER: 'partner.update',
  ACCOUNT: 'account.update',
  CONTACT: 'contact.manage',
  LEAD: 'lead.update',
  OPPORTUNITY: 'opportunity.update',
  TENDER: 'tender.update',
};

/** @param {string | null} entity @param {boolean} includeInactive */
async function list(entity, includeInactive) {
  const [rows] = await repo.list(entity, includeInactive);
  return (rows ?? []).map(shapeDef);
}

module.exports = {
  EDIT_PERMISSION,
  typedValues,
  list,

  /**
   * @param {number | null} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async save(id, body, meta) {
    const [[row]] = await repo.save(id, body, meta);
    return { id: Number(row?.id) };
  },

  /**
   * The definitions of the entity and the record's values by field key.
   * @param {number} userId
   * @param {string} entity
   * @param {number} recordId
   */
  async values(userId, entity, recordId) {
    const [defs, [rows]] = await Promise.all([
      list(entity, false),
      repo.values(userId, entity, recordId),
    ]);
    const byId = new Map(defs.map((d) => [d.id, d]));
    /** @type {Record<string, unknown>} */
    const values = {};
    for (const row of rows ?? []) {
      const d = byId.get(Number(row.fieldId));
      if (d) values[d.fieldKey] = untyped(d, row);
    }
    return { fields: defs, values };
  },

  /**
   * @param {any} body  { entity, recordId, section, values }
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  async saveValues(body, meta, allowAny) {
    const defs = await list(body.entity, false);
    const scoped = body.section ? defs.filter((d) => d.section === body.section) : defs;
    const rows = typedValues(scoped, body.values);
    if (rows.length) await repo.saveValues(body.entity, body.recordId, rows, meta, allowAny);
    return { saved: rows.length };
  },
};
