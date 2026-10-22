// @ts-check
'use strict';

/**
 * Request-shape validation (8.6) with zod: path params, query and body. Bodies are strict
 * objects (unknown fields rejected, no mass assignment). The parsed values are placed on
 * req.valid; controllers read only from there.
 */
const { errors } = require('../shared/errors');

/**
 * @typedef {{ params?: import('zod').ZodType, query?: import('zod').ZodType, body?: import('zod').ZodType }} RouteSchema
 */

/**
 * @param {import('zod').ZodError} error
 * @param {string} source
 */
function toDetails(error, source) {
  return error.issues.map((issue) => {
    const keys = /** @type {any} */ (issue).keys;
    const field =
      issue.code === 'unrecognized_keys' && Array.isArray(keys)
        ? keys.join(', ')
        : issue.path.map(String).join('.') || source;
    const message =
      issue.code === 'unrecognized_keys' ? 'This field is not accepted.' : issue.message;
    return { field, code: issue.code.toUpperCase(), message };
  });
}

/**
 * @param {RouteSchema} [schema]
 * @returns {import('express').RequestHandler}
 */
function validate(schema = {}) {
  return (req, _res, next) => {
    /** @type {Record<string, unknown>} */
    const valid = {};
    /** @type {Array<{ field: string, code: string, message: string }>} */
    const details = [];

    for (const source of /** @type {const} */ (['params', 'query', 'body'])) {
      const s = schema[source];
      if (!s) continue;
      const input = source === 'body' ? (req.body ?? {}) : req[source];
      const result = s.safeParse(input);
      if (result.success) valid[source] = result.data;
      else details.push(...toDetails(result.error, source));
    }

    if (details.length) return next(errors.validation(details));
    /** @type {any} */ (req).valid = valid;
    return next();
  };
}

module.exports = validate;
