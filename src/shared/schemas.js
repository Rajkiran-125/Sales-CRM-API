// @ts-check
'use strict';

/**
 * Reusable request-shape schemas (zod 4) mirroring the field rules of tech doc 16.2.
 * Business rules are enforced by the stored procedures (decision D-02).
 */
const { z } = require('zod');

const trimmed = (/** @type {number} */ max) => z.string().trim().max(max);

const schemas = {
  id: z.coerce.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  idParam: z.object({ id: z.coerce.number().int().positive().max(Number.MAX_SAFE_INTEGER) }),
  rowVersion: z.number().int().positive(),

  email: z
    .string()
    .trim()
    .toLowerCase()
    .max(150)
    .pipe(z.email({ message: 'Enter a valid email address.' })),
  /** 10-15 digits with an optional leading + */
  phone: z
    .string()
    .trim()
    .regex(/^\+?[0-9]{10,15}$/, 'Enter 10 to 15 digits, optionally starting with +.'),
  name: trimmed(150).min(1, 'Required.'),
  optionalText: (/** @type {number} */ max) =>
    z
      .string()
      .trim()
      .max(max)
      .nullish()
      .transform((v) => (v ? v : null)),
  code: z
    .string()
    .trim()
    .toUpperCase()
    .regex(/^[A-Z][A-Z0-9_]{1,39}$/, 'Use 2-40 letters, digits or _ starting with a letter.'),
  boolQuery: z
    .enum(['true', 'false'])
    .optional()
    .transform((v) => v === 'true'),
  isoDateTime: z.iso.datetime({ offset: true }),
  password: z.string().min(1, 'Required.').max(128, 'At most 128 characters.'),
  token: z.string().trim().min(20).max(200),
};

/**
 * Paging and sorting query (14.1): ?page=1&pageSize=25 (max 100)&sort=-name
 * @param {string[]} sortFields allowed sort keys (without the leading -)
 * @param {string} defaultSort
 */
function listQuery(sortFields, defaultSort) {
  const allowed = new Set(sortFields.flatMap((f) => [f, `-${f}`]));
  return z.object({
    page: z.coerce.number().int().min(1).max(100000).default(1),
    pageSize: z.coerce.number().int().min(1).max(100).default(25),
    sort: z
      .string()
      .optional()
      .transform((v) => v ?? defaultSort)
      .refine((v) => allowed.has(v), { message: `Sort by one of: ${[...allowed].join(', ')}` }),
    search: z.string().trim().max(100).optional(),
  });
}

/** @param {{ page: number, pageSize: number }} q */
function offsetOf(q) {
  return (q.page - 1) * q.pageSize;
}

module.exports = { z, schemas, listQuery, offsetOf };
