// @ts-check
'use strict';

/**
 * My day (12.3; D-27): the user's open tasks (overdue, today, the next 7 days), their own open
 * deals that need something, deals waiting for validation (holders of opportunity.validate)
 * and offers waiting for approval (holders of offer.approve).
 */
const repo = require('./tasks.repository');
const { shapeAll } = require('../../shared/readModel');

module.exports = {
  /**
   * @param {number} userId
   * @param {Set<string>} permissions
   */
  async myDay(userId, permissions) {
    const canValidate = permissions.has('opportunity.validate');
    const canApprove = permissions.has('offer.approve');
    const [[summary], tasks, attention, validations, offers] = await repo.myDay(
      userId,
      canValidate,
      canApprove,
    );
    return {
      summary,
      tasks,
      attention: shapeAll(attention, { bools: ['closeDatePassed', 'statusPending'] }),
      validations: canValidate ? validations : null,
      offers: canApprove ? shapeAll(offers, { numbers: ['discountPct'] }) : null,
    };
  },

  /**
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  create: (body, meta) => repo.create(body, meta),

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  update: (id, body, meta, allowAny) => repo.update(id, body, meta, allowAny),
};
