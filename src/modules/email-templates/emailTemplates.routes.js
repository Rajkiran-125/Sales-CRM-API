// @ts-check
'use strict';

/**
 * /api/v1/email-templates (12.14). Admin email templates are the only rich text allowed in
 * v1 and are sanitised server-side before they are stored (17.5). Placeholder checks are
 * done by sp_email_template_update.
 */
const sanitizeHtml = require('sanitize-html');
const { callProcedure, callProcedureOne } = require('../../db/pool');
const mailer = require('../../integrations/mailer');
const { z, schemas } = require('../../shared/schemas');
const { requestMeta } = require('../../shared/requestMeta');
const { sendData, sendNoContent } = require('../../shared/response');
const { errors } = require('../../shared/errors');

const SANITIZE = {
  allowedTags: [
    'p',
    'br',
    'strong',
    'b',
    'em',
    'i',
    'u',
    'a',
    'ul',
    'ol',
    'li',
    'h1',
    'h2',
    'h3',
    'h4',
    'span',
    'div',
    'table',
    'thead',
    'tbody',
    'tr',
    'td',
    'th',
    'hr',
    'blockquote',
  ],
  allowedAttributes: {
    a: ['href', 'style', 'target', 'rel'],
    '*': ['style', 'align'],
  },
  allowedSchemes: ['https', 'http', 'mailto'],
  allowedStyles: {
    '*': {
      color: [/^#[0-9a-f]{3,8}$/i, /^[a-z]+$/i],
      background: [/^#[0-9a-f]{3,8}$/i],
      'background-color': [/^#[0-9a-f]{3,8}$/i],
      'text-align': [/^(left|right|center|justify)$/],
      'text-decoration': [/^(none|underline)$/],
      'font-weight': [/^(normal|bold|[1-9]00)$/],
      'font-size': [/^\d{1,2}px$/],
      display: [/^(inline-block|block|inline)$/],
      padding: [/^(\d{1,2}px\s?){1,4}$/],
      margin: [/^(\d{1,2}px\s?){1,4}$/],
      'border-radius': [/^\d{1,3}px$/],
    },
  },
};

const codeParam = z.object({
  code: z
    .string()
    .trim()
    .toUpperCase()
    .regex(/^[A-Z_]{2,60}$/),
});

/** @param {string} code */
async function getOrThrow(code) {
  const row = await callProcedureOne('sp_email_template_get', [code]);
  if (!row) throw errors.notFound('Email template not found.');
  return row;
}

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['email_template.manage'],
    summary: 'List email templates',
    handler: async (req, res) => {
      sendData(req, res, (await callProcedure('sp_email_template_list'))[0] ?? []);
    },
  },
  {
    method: 'get',
    path: '/:code',
    access: ['email_template.manage'],
    summary: 'Get an email template',
    schema: { params: codeParam },
    handler: async (req, res) => {
      sendData(req, res, await getOrThrow(/** @type {any} */ (req).valid.params.code));
    },
  },
  {
    method: 'patch',
    path: '/:code',
    access: ['email_template.manage'],
    summary: 'Edit the subject / body of an email template',
    schema: {
      params: codeParam,
      body: z.strictObject({
        rowVersion: schemas.rowVersion,
        subject: z.string().trim().min(1).max(255).optional(),
        bodyHtml: z.string().min(1).max(100000).optional(),
        isActive: z.boolean().optional(),
      }),
    },
    handler: async (req, res) => {
      const { params, body } = /** @type {any} */ (req).valid;
      const current = await getOrThrow(params.code);
      const m = requestMeta(req);
      const html =
        body.bodyHtml !== undefined ? sanitizeHtml(body.bodyHtml, SANITIZE) : current.bodyHtml;
      const sets = await callProcedure('sp_email_template_update', [
        m.actorUserId,
        m.requestId,
        m.ip,
        params.code,
        body.rowVersion,
        body.subject ?? current.subject,
        html,
        body.isActive === undefined ? (current.isActive ? 1 : 0) : body.isActive ? 1 : 0,
      ]);
      sendData(req, res, sets[0]?.[0] ?? null);
    },
  },
  {
    method: 'post',
    path: '/:code/test',
    access: ['email_template.manage'],
    summary: 'Send the template with sample values to my own email address',
    schema: { params: codeParam },
    successStatus: 204,
    handler: async (req, res) => {
      const code = /** @type {any} */ (req).valid.params.code;
      const template = await getOrThrow(code);
      const user = /** @type {any} */ (req).user;
      /** @type {Record<string, string>} */
      const sample = {};
      for (const name of template.placeholders ?? []) {
        if (name !== 'appName') sample[name] = `[${name}]`;
      }
      Object.assign(sample, {
        fullName: user.fullName,
        link: 'https://example.invalid/sample-link',
      });
      await mailer.sendTemplate(code, user.email, sample);
      sendNoContent(res);
    },
  },
];
