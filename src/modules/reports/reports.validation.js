// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const { REPORTS } = require('./reports.catalogue');

const codes = /** @type {[string, ...string[]]} */ (REPORTS.map((r) => r.code));

module.exports = {
  /** every filter a catalogue report may use; each report reads the ones it knows */
  export: {
    params: z.object({ code: z.enum(codes) }),
    query: z
      .strictObject({
        fiscalYear: z.coerce.number().int().min(2000).max(2100).optional(),
        quarter: z.coerce.number().int().min(1).max(4).optional(),
        month: z
          .string()
          .regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM.')
          .transform((m) => m + '-01')
          .optional(),
        weekStart: z.iso.date().optional(),
        team: schemas.boolQuery.optional(),
        dimension: z.enum(['PRODUCT', 'PARTNER', 'INDUSTRY', 'MONTH']).optional(),
        accountId: schemas.id.optional(),
        partnerId: schemas.id.optional(),
        ownerUserId: schemas.id.optional(),
        productId: schemas.id.optional(),
        industryId: schemas.id.optional(),
        competitorId: schemas.id.optional(),
        type: schemas.code.optional(),
        status: z.string().trim().max(20).optional(),
        outcome: z.enum(['WON', 'LOST']).optional(),
      })
      .refine((q) => q.quarter === undefined || q.fiscalYear !== undefined, {
        message: 'Choose the fiscal year with the quarter.',
        path: ['quarter'],
      }),
  },
  byCode: {
    params: z.object({ code: z.enum(['REVENUE_GM', 'PRODUCT_MIX']) }),
    query: z
      .strictObject({
        fiscalYear: z.coerce.number().int().min(2000).max(2100).optional(),
        quarter: z.coerce.number().int().min(1).max(4).optional(),
        dimension: z.enum(['PRODUCT', 'PARTNER', 'INDUSTRY', 'MONTH']).optional(),
        partnerId: schemas.id.optional(),
      })
      .refine((q) => q.quarter === undefined || q.fiscalYear !== undefined, {
        message: 'Choose the fiscal year with the quarter.',
        path: ['quarter'],
      }),
  },
};
