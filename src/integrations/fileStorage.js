// @ts-check
'use strict';

/**
 * File storage (8.11, 17.9): files live under FILE_DIR with random, non-guessable keys; the
 * original name is metadata only. Swap this module for object storage later (OD-18).
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const config = require('../config');

/** Keys are 64 hex characters, so a key can never escape the folder. */
const KEY = /^[a-f0-9]{64}$/;

/** @param {string} key */
function fullPath(key) {
  if (!KEY.test(key)) throw new Error('Invalid storage key');
  return path.join(config.files.dir, key.slice(0, 2), key);
}

module.exports = {
  /**
   * Store a buffer; returns its key and SHA-256.
   * @param {Buffer} data
   */
  async save(data) {
    const key = crypto.randomBytes(32).toString('hex');
    const file = fullPath(key);
    await fs.promises.mkdir(path.dirname(file), { recursive: true });
    await fs.promises.writeFile(file, data, { flag: 'wx' });
    return { key, sha256: crypto.createHash('sha256').update(data).digest('hex') };
  },

  /** @param {string} key */
  stream: (key) => fs.createReadStream(fullPath(key)),

  /** @param {string} key */
  remove: (key) => fs.promises.rm(fullPath(key), { force: true }),
};
