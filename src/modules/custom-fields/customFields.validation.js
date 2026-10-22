// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const ENTITIES = /** @type {const} */ ([
  'PARTNER',
  'ACCOUNT',
  'CONTACT',
  'LEAD',
  'OPPORTUNITY',
  'TENDER',
]);
const TYPES = /** @type {const} */ ([
  'TEXT',
  'LONG_TEXT',
  'NUMBER',
  'MONEY',
  'DATE',
  'SINGLE_SELECT',
  'MULTI_SELECT',
  'YES_NO',
  'URL',
  'EMAIL',
]);
const entity = z.enum(ENTITIES);

/** Fields an admin may change after creation (entity, key and type are fixed, 12.15). */
const changeable = {
  section: schemas.optionalText(40),
  label: z.string().trim().min(1, 'Required.').max(150),
  options: z
    .array(z.string().trim().min(1).max(100))
    .max(100)
    .transform((a) => [...new Set(a)])
    .nullish()
    .transform((v) => v ?? null),
  isMandatory: z.boolean().default(false),
  isFilterable: z.boolean().default(false),
  sortOrder: z.number().int().min(0).max(9999).default(0),
  helpText: schemas.optionalText(500),
  isActive: z.boolean().default(true),
};

module.exports = {
  ENTITIES,
  list: {
    query: z.strictObject({
      entity: entity.optional(),
      includeInactive: schemas.boolQuery.optional(),
    }),
  },
  create: {
    body: z.strictObject({
      entity,
      fieldKey: z
        .string()
        .trim()
        .toLowerCase()
        .regex(
          /^[a-z][a-z0-9_]{1,59}$/,
          'Use 2-60 lower-case letters, digits or _ starting with a letter.',
        ),
      fieldType: z.enum(TYPES),
      ...changeable,
    }),
  },
  update: { params: schemas.idParam, body: z.strictObject(changeable) },
  valuesGet: {
    query: z.strictObject({ entity, recordId: schemas.id }),
  },
  valuesSave: {
    body: z.strictObject({
      entity,
      recordId: schemas.id,
      /** the partner section being saved: its mandatory fields are enforced (BR-PT-06) */
      section: schemas.optionalText(40),
      /** fieldKey → value; null / '' / [] clears the field */
      values: z.record(z.string().max(60), z.unknown()),
    }),
  },
};
