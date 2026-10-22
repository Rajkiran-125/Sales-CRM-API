// @ts-check
'use strict';

const { z, schemas, listQuery } = require('../../shared/schemas');

const STATUSES = [
  'IDENTIFIED',
  'READINESS',
  'CAPTURED',
  'SUBMITTED',
  'TECH_QUALIFIED',
  'L1_L2',
  'AWARDED',
  'NOT_AWARDED',
  'CANCELLED',
];

const text = schemas.optionalText;
const nullId = schemas.id.nullish().transform((v) => v ?? null);
const day = z.iso
  .date()
  .nullish()
  .transform((v) => v ?? null);
const money = z
  .number()
  .min(0)
  .max(99999999999999)
  .nullish()
  .transform((v) => v ?? null);

/** The UM 4.4 tender fields (12.8). */
const tenderBody = z.strictObject({
  referenceNo: text(100),
  portal: text(150),
  authority: z.string().trim().min(1, 'Required.').max(200),
  accountId: nullId,
  title: z.string().trim().min(1, 'Required.').max(250),
  productId: nullId,
  estimatedValue: money,
  ourRole: z.enum(['OEM', 'BIDDER', 'CONSORTIUM']),
  bidderPartnerId: nullId,
  preBidOn: day,
  submissionOn: day,
  openingOn: day,
  specInfluenced: z.boolean().default(false),
  rfpInfluenced: z.boolean().default(false),
  prebidQueriesFiled: z.boolean().default(false),
  intelligenceNotes: text(10000),
  /** create: defaults to the creator; edit: null keeps the owner */
  ownerUserId: nullId,
  backupOwnerUserId: nullId,
});

const checklistBody = z.strictObject({
  itemText: z.string().trim().min(1, 'Required.').max(500),
  isMandatory: z.boolean().default(true),
  isDone: z.boolean().default(false),
  documentId: nullId,
});
const itemParams = z.object({ id: schemas.id, itemId: schemas.id });
const listQ = listQuery(['submissionOn', 'estimatedValue', 'createdAt'], 'submissionOn').extend({
  status: z.enum(STATUSES).optional(),
  ownerUserId: schemas.id.optional(),
});

module.exports = {
  STATUSES,
  list: { query: listQ },
  byId: { params: schemas.idParam },
  create: { body: tenderBody },
  update: {
    params: schemas.idParam,
    body: tenderBody.extend({ rowVersion: z.number().int().min(1) }),
  },
  transition: {
    params: schemas.idParam,
    body: z.strictObject({
      rowVersion: z.number().int().min(1),
      toStatus: z.enum(STATUSES),
      result: text(20),
      l1Price: money,
      ourPrice: money,
      winner: text(200),
      lossReasonId: nullId,
      opportunityId: nullId,
      reason: text(1000),
    }),
  },
  checklistCreate: { params: schemas.idParam, body: checklistBody },
  checklistUpdate: { params: itemParams, body: checklistBody },
  checklistDelete: { params: itemParams },
};
