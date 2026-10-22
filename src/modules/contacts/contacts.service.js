// @ts-check
'use strict';

/** Contacts write side (12.6, V017). */
const repo = require('./contacts.repository');

module.exports = {
  /** @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta */
  create: (body, meta) => repo.create(body, meta),
  /** @param {number} id @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta */
  update: (id, body, meta) => repo.update(id, body, meta),
  /** @param {number} id @param {import('../../shared/requestMeta').RequestMeta} meta */
  deactivate: (id, meta) => repo.deactivate(id, meta),
};
