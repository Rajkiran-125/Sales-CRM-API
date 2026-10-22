// @ts-check
'use strict';

const repo = require('./weekly-status.repository');

/** @param {any} b @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny */
const upsert = (b, meta, allowAny) => repo.upsert(b, meta, allowAny);
/** @param {number} id @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny */
const del = (id, meta, allowAny) => repo.del(id, meta, allowAny);

module.exports = { upsert, del };
