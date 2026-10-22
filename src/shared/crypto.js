// @ts-check
'use strict';

const crypto = require('crypto');

/** 256-bit random opaque token, URL-safe (refresh tokens, reset / invitation links). */
function randomToken() {
  return crypto.randomBytes(32).toString('base64url');
}

/** SHA-256 hex digest: only this reaches the database, never the token itself. */
function sha256(/** @type {string} */ value) {
  return crypto.createHash('sha256').update(value, 'utf8').digest('hex');
}

function uuid() {
  return crypto.randomUUID();
}

module.exports = { randomToken, sha256, uuid };
