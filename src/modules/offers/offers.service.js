// @ts-check
'use strict';

const repo = require('./offers.repository');

module.exports = {
  /** @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny */
  create: (body, meta, allowAny) => repo.create(body, meta, allowAny),

  /** @param {number} id @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny */
  update: (id, body, meta, allowAny) => repo.update(id, body, meta, allowAny),

  /** @param {number} id @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny */
  submit: (id, meta, allowAny) => repo.submit(id, meta, allowAny),

  /** @param {number} id @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta */
  approve: (id, body, meta) => repo.approve(id, body, meta),

  /** @param {number} id @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny */
  send: (id, body, meta, allowAny) => repo.send(id, body, meta, allowAny),

  /** @param {number} id @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny */
  respond: (id, body, meta, allowAny) => repo.respond(id, body, meta, allowAny),

  /** @param {number} id @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny */
  revise: (id, meta, allowAny) => repo.revise(id, meta, allowAny),
};
