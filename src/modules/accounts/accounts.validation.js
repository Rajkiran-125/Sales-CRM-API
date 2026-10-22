// @ts-check
'use strict';

const { z, schemas, listQuery } = require('../../shared/schemas');

/** Optional trimmed text: '' and null become null. @param {number} max */
const optText = (max) =>
  z
    .string()
    .trim()
    .max(max)
    .nullish()
    .transform((v) => v || null);

/** Optional upper-case code matching a pattern ('' becomes null). */
const optCode = (/** @type {RegExp} */ re, /** @type {string} */ message) =>
  z
    .string()
    .trim()
    .toUpperCase()
    .refine((v) => v === '' || re.test(v), message)
    .nullish()
    .transform((v) => v || null);

const accountBody = z.strictObject({
  name: z.string().trim().min(1, 'Required.').max(200),
  legalName: optText(250),
  industryId: schemas.id.nullish().transform((v) => v ?? null),
  segment: optText(60),
  accountType: z.enum(['PROSPECT', 'CUSTOMER', 'STRATEGIC', 'DORMANT']).default('PROSPECT'),
  isStrategic: z.boolean().default(false),
  country: optText(80),
  state: optText(80),
  city: optText(100),
  address: optText(500),
  website: optText(255),
  gstNo: optCode(
    /^[0-9]{2}[A-Z0-9]{13}$/,
    'A GST number has 15 characters, starting with 2 digits.',
  ),
  panNo: optCode(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'A PAN looks like ABCDE1234F.'),
  locationsCount: z
    .number()
    .int()
    .min(0)
    .max(1000000)
    .nullish()
    .transform((v) => v ?? null),
  existingVendor: optText(200),
  /** Create: defaults to the creator. Update: null keeps the current owner. */
  ownerUserId: schemas.id.nullish().transform((v) => v ?? null),
  backupOwnerUserId: schemas.id.nullish().transform((v) => v ?? null),
  notes: optText(4000),
  /** BR-AC-02: the user saw the duplicate warning and saves anyway. */
  ignoreDuplicates: z.boolean().default(false),
});

module.exports = {
  list: {
    query: listQuery(['name', 'openPipeline', 'wonValue'], '-openPipeline').extend({
      type: z.enum(['PROSPECT', 'CUSTOMER', 'STRATEGIC', 'DORMANT']).optional(),
      industryId: schemas.id.optional(),
      ownerUserId: schemas.id.optional(),
    }),
  },
  byId: { params: schemas.idParam },
  create: { body: accountBody },
  update: {
    params: schemas.idParam,
    body: accountBody.extend({ rowVersion: z.number().int().min(1) }),
  },
  merge: {
    params: schemas.idParam,
    body: z.strictObject({ survivorAccountId: schemas.id }),
  },
};
