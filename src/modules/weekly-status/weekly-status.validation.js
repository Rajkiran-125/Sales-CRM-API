// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const STATUS_VALUES = /** @type {[string, ...string[]]} */ ([
  'ON_TRACK',
  'AT_RISK',
  'SLIPPED',
  'STALLED',
]);

const upsertBody = z
  .strictObject({
    opportunityId: schemas.id,
    weekStart: z.iso.date(),
    status: z.enum(STATUS_VALUES),
    thisWeek: z.string().trim().min(1).max(2000),
    nextStep: z.string().trim().min(1).max(1000),
    expectedCloseDate: z.iso
      .date()
      .nullish()
      .transform((v) => v ?? null),
    closeChangeReason: z
      .string()
      .trim()
      .max(1000)
      .nullish()
      .transform((v) => v ?? null),
    expectedValue: z
      .number()
      .positive()
      .nullish()
      .transform((v) => v ?? null),
  })
  .superRefine((d, ctx) => {
    if (d.closeChangeReason && !d.expectedCloseDate) {
      ctx.addIssue({
        code: 'custom',
        path: ['expectedCloseDate'],
        message: 'Required when close change reason is provided.',
      });
    }
  });

module.exports = {
  upsert: { body: upsertBody },
  delete: { params: schemas.idParam },
};
