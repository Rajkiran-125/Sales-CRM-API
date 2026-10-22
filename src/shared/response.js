// @ts-check
'use strict';

/**
 * Response helpers for the single envelope of tech doc 8.8:
 *   { success: true,  data, meta?, requestId }
 *   { success: false, error: { code, message, details? }, requestId }
 */

/** @param {import('express').Request} req */
function requestIdOf(req) {
  return /** @type {any} */ (req).requestId;
}

/**
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {unknown} data
 * @param {number} [status]
 */
function sendData(req, res, data, status = 200) {
  return res.status(status).json({ success: true, data, requestId: requestIdOf(req) });
}

/**
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {unknown[]} rows
 * @param {{ page: number, pageSize: number, total: number, sort?: string | null }} meta
 */
function sendList(req, res, rows, meta) {
  return res.status(200).json({ success: true, data: rows, meta, requestId: requestIdOf(req) });
}

/** @param {import('express').Response} res */
function sendNoContent(res) {
  return res.status(204).end();
}

/**
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {number} status
 * @param {string} code
 * @param {string} message
 * @param {unknown[]} [details]
 */
function sendError(req, res, status, code, message, details) {
  return res.status(status).json({
    success: false,
    error: { code, message, ...(details && details.length ? { details } : {}) },
    requestId: requestIdOf(req),
  });
}

module.exports = { sendData, sendList, sendNoContent, sendError };
