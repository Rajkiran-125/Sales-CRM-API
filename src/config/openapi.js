// @ts-check
'use strict';

/**
 * OpenAPI 3.1 document generated from the route registry and its zod schemas
 * (decision D-19), served by swagger-ui-express at /api-docs outside production (OD-23).
 */
const { z } = require('zod');
const config = require('./index');

/** @param {import('zod').ZodType | undefined} schema */
function jsonSchema(schema) {
  if (!schema) return undefined;
  try {
    return /** @type {any} */ (z.toJSONSchema(schema, { io: 'input', unrepresentable: 'any' }));
  } catch {
    return { type: 'object' };
  }
}

/**
 * @param {import('zod').ZodType | undefined} schema
 * @param {'path' | 'query'} where
 */
function parameters(schema, where) {
  const js = jsonSchema(schema);
  if (!js || !js.properties) return [];
  const required = new Set(js.required ?? []);
  return Object.entries(js.properties).map(([name, s]) => ({
    name,
    in: where,
    required:
      where === 'path' ? true : required.has(name) && !('default' in /** @type {any} */ (s)),
    schema: s,
  }));
}

const envelope = {
  Error: {
    type: 'object',
    required: ['success', 'error', 'requestId'],
    properties: {
      success: { const: false },
      error: {
        type: 'object',
        required: ['code', 'message'],
        properties: {
          code: { type: 'string', example: 'VALIDATION_FAILED' },
          message: { type: 'string' },
          details: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                field: { type: 'string' },
                code: { type: 'string' },
                message: { type: 'string' },
              },
            },
          },
        },
      },
      requestId: { type: 'string' },
    },
  },
  Success: {
    type: 'object',
    required: ['success', 'data', 'requestId'],
    properties: {
      success: { const: true },
      data: {},
      meta: {
        type: 'object',
        properties: {
          page: { type: 'integer' },
          pageSize: { type: 'integer' },
          total: { type: 'integer' },
          sort: { type: 'string' },
        },
      },
      requestId: { type: 'string' },
    },
  },
};

/** @param {import('../shared/routeTable').RegisteredRoute[]} registry */
function buildOpenApi(registry) {
  /** @type {Record<string, Record<string, unknown>>} */
  const paths = {};
  const errorRef = {
    content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
  };

  for (const r of registry) {
    const p = r.fullPath.replace(/:([A-Za-z]+)/g, '{$1}');
    paths[p] = paths[p] || {};
    const access = Array.isArray(r.access)
      ? `Permission (any of): ${r.access.join(', ')}`
      : r.access === 'public'
        ? 'Public'
        : 'Any signed-in user';
    const status = String(r.successStatus ?? 200);

    /** @type {Record<string, unknown>} */
    const responses = {
      [status]:
        status === '204'
          ? { description: 'No content' }
          : r.produces
            ? {
                description: 'File download',
                content: { [r.produces]: { schema: { type: 'string', format: 'binary' } } },
              }
            : {
                description: 'Success',
                content: {
                  'application/json': { schema: { $ref: '#/components/schemas/Success' } },
                },
              },
      422: { description: 'Validation or business rule failure', ...errorRef },
      ...(r.access !== 'public'
        ? { 401: { description: 'Not signed in / token expired', ...errorRef } }
        : {}),
      ...(Array.isArray(r.access)
        ? { 403: { description: 'Missing permission', ...errorRef } }
        : {}),
    };

    paths[p][r.method] = {
      tags: [r.tag],
      summary: r.summary,
      description: [r.description, `**Access:** ${access}`].filter(Boolean).join('\n\n'),
      ...(r.access === 'public' ? { security: [] } : {}),
      ...(Array.isArray(r.access) ? { 'x-permissions': r.access } : {}),
      parameters: [
        ...parameters(r.schema?.params, 'path'),
        ...parameters(r.schema?.query, 'query'),
      ],
      ...(r.schema?.body
        ? {
            requestBody: {
              required: true,
              content: { 'application/json': { schema: jsonSchema(r.schema.body) } },
            },
          }
        : {}),
      responses,
    };
  }

  return {
    openapi: '3.1.0',
    info: {
      title: 'Sales CRM API',
      version: '1.0.0',
      description:
        'Cnergee Sales CRM REST API. Send `Authorization: Bearer <accessToken>` (from POST /auth/login or /auth/refresh). ' +
        'Every response uses the envelope { success, data | error, meta?, requestId }.',
    },
    servers: [{ url: '/' }],
    security: [{ bearerAuth: [] }],
    components: {
      securitySchemes: { bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' } },
      schemas: envelope,
    },
    paths,
    'x-environment': config.env,
  };
}

module.exports = { buildOpenApi };
