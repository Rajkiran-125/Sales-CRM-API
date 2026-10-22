// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

/** "2026-10" -> "2026-10-01" */
const monthRequired = z
  .string()
  .regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM.')
  .transform((v) => `${v}-01`);
const month = monthRequired.optional();

module.exports = {
  monthlySave: {
    body: z.strictObject({
      month: monthRequired,
      items: z
        .array(
          z.strictObject({
            opportunityId: schemas.id,
            /** null removes the commit */
            commitType: z.enum(['COMMIT', 'UPSIDE', 'NEXT_MONTH']).nullable(),
            commitValue: z.number().positive().max(99999999999999).nullable(),
          }),
        )
        .min(1)
        .max(500),
    }),
  },
  nudge: { body: z.strictObject({ weekStart: z.iso.date() }) },
  weekly: {
    query: z.strictObject({ weekStart: z.iso.date().optional(), team: schemas.boolQuery }),
  },
  monthly: {
    query: z.strictObject({ month, team: schemas.boolQuery }),
  },
  hierarchy: {
    query: z.strictObject({ month }),
  },
};
