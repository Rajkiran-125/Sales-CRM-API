// @ts-check
'use strict';

/**
 * /api/v1/masters/{type} (12.14, 14.9). Any signed-in user can read active entries (forms
 * need them); master.manage is needed to see inactive entries and to create / edit.
 * Routes are generated per master type from MASTER_TYPES, so each has its own schema.
 */
const repo = require('./masters.repository');
const { z, schemas } = require('../../shared/schemas');
const { requestMeta } = require('../../shared/requestMeta');
const { sendData } = require('../../shared/response');
const { errors } = require('../../shared/errors');

const sortOrder = z.number().int().min(0).max(9999).default(0);
const pct = z.number().min(0).max(100).multipleOf(0.01);

const simpleCreate = z.strictObject({
  code: schemas.code,
  name: z.string().trim().min(1).max(100),
  sortOrder,
});
const simpleUpdate = z.strictObject({
  name: z.string().trim().min(1).max(100),
  sortOrder,
  isActive: z.boolean().default(true),
});

/**
 * @typedef {Object} MasterType
 * @property {string} slug
 * @property {string} label
 * @property {(q: any, inactive: boolean) => Promise<any>} list
 * @property {import('zod').ZodObject} [listQuery]
 * @property {import('zod').ZodType} [createBody]
 * @property {(b: any, m: any) => Promise<any>} [create]
 * @property {import('zod').ZodType} updateBody
 * @property {(id: number, b: any, m: any) => Promise<any>} update
 */

/** @param {string} type @param {string} slug @param {string} label @returns {MasterType} */
const simple = (type, slug, label) => ({
  slug,
  label,
  list: (_q, inactive) => repo.simple.list(type, inactive),
  createBody: simpleCreate,
  create: (b, m) => repo.simple.create(type, b, m),
  updateBody: simpleUpdate,
  update: (id, b, m) => repo.simple.update(type, id, b, m),
});

/** @type {MasterType[]} */
const MASTER_TYPES = [
  simple('PARTNER_TYPE', 'partner-types', 'Partner types'),
  simple('INDUSTRY', 'industries', 'Industries'),
  simple('PRODUCT', 'products', 'Products'),
  simple('PROCUREMENT_TYPE', 'procurement-types', 'Procurement types'),
  simple('DOCUMENT_TYPE', 'document-types', 'Document types'),
  simple('CERTIFICATION_TYPE', 'certification-types', 'Certification types'),
  {
    slug: 'solutions',
    label: 'Solutions',
    listQuery: z.object({ productId: schemas.id.optional() }),
    list: repo.solution.list,
    createBody: z.strictObject({
      productId: schemas.id,
      name: z.string().trim().min(1).max(150),
      description: schemas.optionalText(500),
      sortOrder,
    }),
    create: repo.solution.create,
    updateBody: z.strictObject({
      name: z.string().trim().min(1).max(150),
      description: schemas.optionalText(500),
      sortOrder,
      isActive: z.boolean().default(true),
    }),
    update: repo.solution.update,
  },
  {
    slug: 'reasons',
    label: 'Reasons',
    listQuery: z.object({
      reasonType: z.enum(['WIN', 'LOSS', 'DISQUALIFY', 'DORMANT', 'NOT_VALID']).optional(),
    }),
    list: repo.reason.list,
    createBody: z.strictObject({
      reasonType: z.enum(['WIN', 'LOSS', 'DISQUALIFY', 'DORMANT', 'NOT_VALID']),
      code: schemas.code,
      name: z.string().trim().min(1).max(150),
      category: schemas.optionalText(100),
      competitorRequired: z.boolean().default(false),
      sortOrder,
    }),
    create: repo.reason.create,
    updateBody: z.strictObject({
      name: z.string().trim().min(1).max(150),
      category: schemas.optionalText(100),
      competitorRequired: z.boolean().default(false),
      sortOrder,
      isActive: z.boolean().default(true),
    }),
    update: repo.reason.update,
  },
  {
    slug: 'competitors',
    label: 'Competitors',
    list: repo.competitor.list,
    createBody: z.strictObject({
      name: z.string().trim().min(1).max(150),
      products: schemas.optionalText(500),
      strengths: schemas.optionalText(4000),
      weaknesses: schemas.optionalText(4000),
    }),
    create: repo.competitor.create,
    updateBody: z.strictObject({
      name: z.string().trim().min(1).max(150),
      products: schemas.optionalText(500),
      strengths: schemas.optionalText(4000),
      weaknesses: schemas.optionalText(4000),
      isActive: z.boolean().default(true),
    }),
    update: repo.competitor.update,
  },
  {
    slug: 'procurement-steps',
    label: 'Procurement steps',
    listQuery: z.object({ procurementTypeId: schemas.id.optional() }),
    list: repo.procurementStep.list,
    createBody: z.strictObject({
      procurementTypeId: schemas.id,
      sequenceNo: z.number().int().min(1).max(99),
      name: z.string().trim().min(1).max(150),
      hintConfidencePct: pct.nullish().transform((v) => v ?? null),
    }),
    create: repo.procurementStep.create,
    updateBody: z.strictObject({
      sequenceNo: z.number().int().min(1).max(99),
      name: z.string().trim().min(1).max(150),
      hintConfidencePct: pct.nullish().transform((v) => v ?? null),
      isActive: z.boolean().default(true),
    }),
    update: repo.procurementStep.update,
  },
  {
    slug: 'stages',
    label: 'Stages and confidence',
    listQuery: z.object({ entity: z.enum(['LEAD', 'OPP', 'TENDER', 'ORDER']).optional() }),
    list: (q) => repo.stage.list(q),
    updateBody: z.strictObject({
      name: z.string().trim().min(1).max(100),
      defaultConfidencePct: pct.nullish().transform((v) => v ?? null),
      slaDays: z
        .number()
        .int()
        .min(1)
        .max(365)
        .nullish()
        .transform((v) => v ?? null),
      colourToken: z
        .enum(['neutral', 'info', 'warning', 'success', 'danger'])
        .nullish()
        .transform((v) => v ?? null),
    }),
    update: repo.stage.update,
  },
];

/** @param {import('express').Request} req */
const valid = (req) => /** @type {any} */ (req).valid;

/** @type {import('../../shared/routeTable').RouteDef[]} */
const routes = [
  {
    method: 'get',
    path: '/',
    access: 'authenticated',
    summary: 'Master types available to the Masters screen',
    handler: (req, res) => {
      sendData(
        req,
        res,
        MASTER_TYPES.map((t) => ({ type: t.slug, label: t.label, canCreate: !!t.create })),
      );
    },
  },
];

for (const t of MASTER_TYPES) {
  const listQuery = (t.listQuery ?? z.object({})).extend({ includeInactive: schemas.boolQuery });

  routes.push({
    method: 'get',
    path: `/${t.slug}`,
    access: 'authenticated',
    summary: `List ${t.label.toLowerCase()} (inactive entries need master.manage)`,
    schema: { query: listQuery },
    handler: async (req, res) => {
      const q = valid(req).query;
      const user = /** @type {any} */ (req).user;
      const inactive = q.includeInactive && user.permissions.has('master.manage');
      sendData(req, res, await t.list(q, inactive));
    },
  });

  if (t.create && t.createBody) {
    const create = t.create;
    routes.push({
      method: 'post',
      path: `/${t.slug}`,
      access: ['master.manage'],
      summary: `Create an entry in ${t.label.toLowerCase()}`,
      schema: { body: t.createBody },
      successStatus: 201,
      handler: async (req, res) => {
        sendData(req, res, await create(valid(req).body, requestMeta(req)), 201);
      },
    });
  }

  routes.push({
    method: 'patch',
    path: `/${t.slug}/:id`,
    access: ['master.manage'],
    summary: `Edit an entry in ${t.label.toLowerCase()}`,
    schema: { params: schemas.idParam, body: t.updateBody },
    handler: async (req, res) => {
      const result = await t.update(valid(req).params.id, valid(req).body, requestMeta(req));
      if (!result) throw errors.notFound();
      sendData(req, res, result);
    },
  });
}

module.exports = routes;
