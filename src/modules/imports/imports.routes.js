// @ts-check
'use strict';

/** /api/v1/imports (12.17): partner import with a preview (dry run) and a commit. */
const multer = require('multer');
const { z, schemas } = require('../../shared/schemas');
const { appError } = require('../../shared/errors');
const service = require('./imports.service');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');

const MAX_MB = 5;
const single = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_MB * 1048576, files: 1, fields: 5 },
}).single('file');

/**
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
function parseFile(req, res, next) {
  single(req, res, (/** @type {any} */ err) => {
    if (!err) return next();
    if (err.code === 'LIMIT_FILE_SIZE')
      return next(appError('FILE_TOO_LARGE', `The file may be at most ${MAX_MB} MB.`));
    if (err instanceof multer.MulterError)
      return next(
        appError('BAD_REQUEST', 'The upload could not be read.', [
          { field: 'file', message: err.message },
        ]),
      );
    return next(err);
  });
}

/** @typedef {import('express').Request & { valid: any, user: any, file?: Express.Multer.File }} Req */

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/templates/:entity',
    access: ['import.run'],
    summary: 'The Excel template of an import (partners)',
    schema: { params: z.strictObject({ entity: z.enum(['partners']) }) },
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    handler: async (req, res) => {
      const buf = await service.template();
      res.setHeader(
        'Content-Type',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      res.setHeader('Content-Disposition', 'attachment; filename="partner-import-template.xlsx"');
      res.end(buf);
    },
  },
  {
    method: 'post',
    path: '/',
    access: ['import.run'],
    summary: 'Upload a filled partner template: every row is checked and kept as a preview',
    description: 'Multipart field "file" (.xlsx, at most 5 MB, 2,000 rows); entity = PARTNER.',
    parse: [parseFile],
    schema: { body: z.strictObject({ entity: z.enum(['PARTNER']) }) },
    handler: async (req, res) => {
      const r = /** @type {Req} */ (req);
      sendData(req, res, await service.upload(r.file, requestMeta(req)), 201);
    },
  },
  {
    method: 'get',
    path: '/:id',
    access: ['import.run'],
    summary: 'An import batch with every row, its status and messages',
    schema: { params: schemas.idParam },
    handler: async (req, res) => {
      sendData(req, res, await service.get(/** @type {Req} */ (req).valid.params.id));
    },
  },
  {
    method: 'post',
    path: '/:id/commit',
    access: ['import.run'],
    summary: 'Create the valid rows of a preview; new duplicates are skipped; audited IMPORTED',
    schema: { params: schemas.idParam },
    handler: async (req, res) => {
      const r = /** @type {Req} */ (req);
      sendData(req, res, await service.commit(r.valid.params.id, requestMeta(req)));
    },
  },
];
