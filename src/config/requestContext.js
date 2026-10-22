// @ts-check
'use strict';

/**
 * Per-request context (request id, user id) carried through async calls, so every
 * log line can include them without passing them around (8.9, 18.3).
 */
const { AsyncLocalStorage } = require('async_hooks');

/** @typedef {{ requestId: string, userId?: number }} RequestStore */

/** @type {AsyncLocalStorage<RequestStore>} */
const storage = new AsyncLocalStorage();

/** @returns {RequestStore | undefined} */
function current() {
  return storage.getStore();
}

module.exports = { storage, current };
