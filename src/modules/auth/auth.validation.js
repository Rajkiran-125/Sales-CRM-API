// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

module.exports = {
  login: {
    body: z.strictObject({
      email: z.string().trim().toLowerCase().min(1, 'Required.').max(150),
      password: schemas.password,
    }),
  },
  changePassword: {
    body: z.strictObject({ currentPassword: schemas.password, newPassword: schemas.password }),
  },
  forgotPassword: { body: z.strictObject({ email: schemas.email }) },
  checkToken: { body: z.strictObject({ token: schemas.token }) },
  useToken: { body: z.strictObject({ token: schemas.token, newPassword: schemas.password }) },
  sessionParam: { params: z.object({ id: z.uuid() }) },
};
