// @ts-check
'use strict';

/**
 * /api/v1/documents (12.13, 14.9): search over the documents of the records the user can see
 * (a document has the visibility of its parent, 10.8 rule 3), upload, download and delete.
 */
const c = require('./documents.controller');
const v = require('./documents.validation');
const { parseUpload } = require('./documents.upload');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['document.view'],
    summary: 'Search documents by text, type, record, shared with, partner, account or tag',
    schema: v.list,
    handler: c.list,
  },
  {
    method: 'post',
    path: '/',
    access: ['document.upload'],
    summary: 'Upload files (multipart field "files") and attach them to a visible record',
    description:
      'Allowed types, size and count come from settings (17.9); the content must match the extension.',
    parse: [parseUpload],
    schema: v.upload,
    handler: c.upload,
  },
  {
    method: 'get',
    path: '/:id/download',
    access: ['document.view'],
    summary: 'Download a document of a visible record (attachment)',
    schema: v.byId,
    handler: c.download,
    produces: 'application/octet-stream',
  },
  {
    method: 'patch',
    path: '/:id',
    access: ['document.upload'],
    summary: 'Replace the tags and / or the notes of a visible document',
    schema: v.update,
    handler: c.update,
  },
  {
    method: 'delete',
    path: '/:id',
    access: ['document.delete'],
    summary: 'Delete a document (soft): the uploader, or an administrator',
    schema: v.byId,
    handler: c.remove,
  },
];
