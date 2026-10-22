// @ts-check
'use strict';

/**
 * Correlation id (7.10): accept a well-formed X-Request-Id from the client or create one,
 * echo it in the response header and in every error body, and make it available to the
 * logger for the whole request.
 */
const { uuid } = require('../shared/crypto');
const requestContext = require('../config/requestContext');

const VALID = /^[A-Za-z0-9._-]{8,64}$/;

/** @type {import('../shared/types').Handler} */
function requestId(req, res, next) {
  const incoming = req.get('x-request-id');
  const id = incoming && VALID.test(incoming) ? incoming : uuid();
  /** @type {any} */ (req).requestId = id;
  res.setHeader('X-Request-Id', id);
  requestContext.storage.run({ requestId: id }, () => next());
}

module.exports = requestId;
