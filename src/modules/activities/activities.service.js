// @ts-check
'use strict';

const repo = require('./activities.repository');

module.exports = {
  /**
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  create: (body, meta) => repo.create(body, meta),

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny  true when actor has ALL scope
   */
  update: (id, body, meta, allowAny) => repo.update(id, body, meta, allowAny),

  /**
   * @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  delete: (id, meta, allowAny) => repo.delete(id, meta, allowAny),
};
