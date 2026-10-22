'use strict';

/** Argon2id PHC hashes verify whatever order the m/t/p parameters were written in. */
const { hashPassword, verifyPassword } = require('../../src/auth/passwords');

describe('verifyPassword', () => {
  test('accepts its own hashes and the old argon2 package order (m,p,t)', async () => {
    const hash = await hashPassword('Demo-Team-2026!');
    const oldOrder = hash.replace('m=19456,t=2,p=1', 'm=19456,p=1,t=2');
    expect(oldOrder).not.toBe(hash);
    expect(await verifyPassword(hash, 'Demo-Team-2026!')).toBe(true);
    expect(await verifyPassword(oldOrder, 'Demo-Team-2026!')).toBe(true);
    expect(await verifyPassword(oldOrder, 'wrong')).toBe(false);
    expect(await verifyPassword(hash.replace(',p=1', ''), 'Demo-Team-2026!')).toBe(false);
  });
});
