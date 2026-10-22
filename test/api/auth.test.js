'use strict';

/** Authentication (21.1 "Authentication" row, 21.2 journeys 6 and 7, 10.14 token separation). */
const jwt = require('jsonwebtoken');
const config = require('../../src/config');
const {
  api,
  dba,
  closeAll,
  lastMail,
  tokenFromMail,
  refreshCookie,
  login,
  adminSession,
  createActiveUser,
  bearer,
  STRONG,
  ADMIN,
} = require('../helpers');

let admin;
beforeAll(async () => {
  admin = await adminSession();
});
afterAll(closeAll);

describe('login', () => {
  test('success returns an access token and a hardened refresh cookie', async () => {
    const res = await api()
      .post('/api/v1/auth/login')
      .send({ email: ADMIN.email.toUpperCase(), password: ADMIN.password });
    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      tokenType: 'Bearer',
      expiresIn: 900,
      mustChangePassword: false,
    });
    const cookie = res.headers['set-cookie'].find((c) => c.startsWith('crm_refresh='));
    expect(cookie).toMatch(/HttpOnly/);
    expect(cookie).toMatch(/Secure/);
    expect(cookie).toMatch(/SameSite=Strict/);
    expect(cookie).toMatch(/Path=\/api\/v1\/auth/);
    const decoded = jwt.decode(res.body.data.accessToken, { complete: true });
    expect(decoded.header).toMatchObject({ alg: 'HS512', kid: config.auth.keys[0].kid });
    expect(decoded.payload).toMatchObject({ iss: 'sales-crm-api', aud: 'sales-crm-ui' });
    expect(Object.keys(decoded.payload).sort()).toEqual([
      'aud',
      'exp',
      'iat',
      'iss',
      'jti',
      'sub',
      'tv',
    ]);
  });

  test('wrong password and unknown email give the same generic 401', async () => {
    const wrong = await api()
      .post('/api/v1/auth/login')
      .send({ email: ADMIN.email, password: 'nope-nope-nope' });
    const unknown = await api()
      .post('/api/v1/auth/login')
      .send({ email: 'ghost@test.local', password: 'nope-nope-nope' });
    for (const res of [wrong, unknown]) {
      expect(res.status).toBe(401);
      expect(res.body.error).toEqual({
        code: 'INVALID_CREDENTIALS',
        message: 'Invalid email or password.',
      });
    }
  });

  test('unknown body fields are rejected (no mass assignment)', async () => {
    const res = await api()
      .post('/api/v1/auth/login')
      .send({ email: ADMIN.email, password: 'x', isAdmin: true });
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
  });

  test('5 failures lock the account; correct password stays generic; lock email; admin unlock', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'lock.me@test.local',
      roles: ['SALES_EXEC'],
    });
    for (let i = 0; i < 5; i += 1) {
      await api().post('/api/v1/auth/login').send({ email: u.email, password: 'wrong-password-x' });
    }
    const locked = await api()
      .post('/api/v1/auth/login')
      .send({ email: u.email, password: u.password });
    expect(locked.status).toBe(401);
    expect(locked.body.error.code).toBe('INVALID_CREDENTIALS');

    const mail = await lastMail(u.email, 'ACCOUNT_LOCKED');
    expect(mail.subject).toContain('temporarily locked');
    expect(mail.html).toContain('5 unsuccessful sign-in attempts');

    const detail = await api().get(`/api/v1/users/${u.id}`).set(bearer(admin.token));
    expect(detail.body.data.status).toBe('LOCKED');

    const unlock = await api().post(`/api/v1/users/${u.id}/unlock`).set(bearer(admin.token));
    expect(unlock.status).toBe(200);
    expect(unlock.body.data.status).toBe('ACTIVE');
    await login(u.email, u.password);
  });

  test('the lock ends by itself after the lock period', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'autounlock@test.local',
      roles: ['SALES_EXEC'],
    });
    for (let i = 0; i < 5; i += 1) {
      await api().post('/api/v1/auth/login').send({ email: u.email, password: 'wrong-password-x' });
    }
    const conn = await dba();
    await conn.query(
      'UPDATE `user` SET locked_until = UTC_TIMESTAMP(3) - INTERVAL 1 MINUTE WHERE email = ?',
      [u.email],
    );
    await login(u.email, u.password);
  });
});

describe('me', () => {
  test('returns profile, roles, permissions, scope and session policy', async () => {
    const res = await api().get('/api/v1/auth/me').set(bearer(admin.token));
    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      email: ADMIN.email,
      roles: [expect.objectContaining({ code: 'CRM_ADMIN', dataScope: 'ALL' })],
      dataScope: expect.objectContaining({ widest: 'ALL' }),
      sessionPolicy: { idleTimeoutMinutes: 30, accessTokenMinutes: 15 },
    });
    expect(res.body.data.permissions).toEqual(
      expect.arrayContaining(['user.manage', 'role.manage', 'audit.view']),
    );
    expect(res.body.data).not.toHaveProperty('passwordHash');
  });
});

describe('refresh rotation', () => {
  test('rotates the cookie; a just-rotated cookie is a RACE; an old one burns the family', async () => {
    const s = await createActiveUser(admin.token, {
      email: 'rotate@test.local',
      roles: ['SALES_EXEC'],
    });

    const r1 = await api().post('/api/v1/auth/refresh').set('Cookie', s.cookie);
    expect(r1.status).toBe(200);
    const c1 = refreshCookie(r1);
    expect(c1).not.toEqual(s.cookie);

    const race = await api().post('/api/v1/auth/refresh').set('Cookie', s.cookie);
    expect(race.status).toBe(409);

    const conn = await dba();
    await conn.query(
      "UPDATE refresh_token SET revoked_at = UTC_TIMESTAMP(3) - INTERVAL 1 MINUTE WHERE revoked_reason = 'ROTATED' AND user_id = ?",
      [s.id],
    );
    const reused = await api().post('/api/v1/auth/refresh').set('Cookie', s.cookie);
    expect(reused.status).toBe(401);

    const afterTheft = await api().post('/api/v1/auth/refresh').set('Cookie', c1);
    expect(afterTheft.status).toBe(401);

    const [events] = await conn.query(
      "SELECT COUNT(*) AS n FROM security_event_log WHERE event_code = 'REFRESH_TOKEN_REUSE' AND user_id = ?",
      [s.id],
    );
    expect(events[0].n).toBe(1);
  });

  test('no cookie -> 401; foreign Origin -> 403', async () => {
    expect((await api().post('/api/v1/auth/refresh')).status).toBe(401);
    const s = await login(ADMIN.email, ADMIN.password);
    const res = await api()
      .post('/api/v1/auth/refresh')
      .set('Cookie', s.cookie)
      .set('Origin', 'https://evil.example');
    expect(res.status).toBe(403);
  });
});

describe('logout', () => {
  test('logout ends the session: its refresh cookie stops working', async () => {
    const s = await login(ADMIN.email, ADMIN.password);
    const out = await api()
      .post('/api/v1/auth/logout')
      .set(bearer(s.token))
      .set('Cookie', s.cookie);
    expect(out.status).toBe(204);
    expect((await api().post('/api/v1/auth/refresh').set('Cookie', s.cookie)).status).toBe(401);
  });

  test('logout-all rejects existing access tokens at once (token version)', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'logoutall@test.local',
      roles: ['SALES_EXEC'],
    });
    const other = await login(u.email, u.password);
    expect((await api().post('/api/v1/auth/logout-all').set(bearer(u.token))).status).toBe(204);
    expect((await api().get('/api/v1/auth/me').set(bearer(u.token))).status).toBe(401);
    expect((await api().get('/api/v1/auth/me').set(bearer(other.token))).status).toBe(401);
    expect((await api().post('/api/v1/auth/refresh').set('Cookie', other.cookie)).status).toBe(401);
  });
});

describe('change password', () => {
  test('checks current password, policy and reuse; keeps this session, ends the others', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'changer@test.local',
      fullName: 'Chandra Changer',
      roles: ['SALES_EXEC'],
    });
    const other = await login(u.email, u.password);
    const url = '/api/v1/auth/password/change';

    const wrongCurrent = await api()
      .post(url)
      .set(bearer(u.token))
      .set('Cookie', u.cookie)
      .send({ currentPassword: 'not-it-at-all', newPassword: 'Fresh-Valid-Pass-9' });
    expect(wrongCurrent.status).toBe(401);
    expect(wrongCurrent.body.error.details[0].field).toBe('currentPassword');

    const weak = await api()
      .post(url)
      .set(bearer(u.token))
      .set('Cookie', u.cookie)
      .send({ currentPassword: u.password, newPassword: 'short1A' });
    expect(weak.status).toBe(422);

    const personal = await api()
      .post(url)
      .set(bearer(u.token))
      .set('Cookie', u.cookie)
      .send({ currentPassword: u.password, newPassword: 'Chandra-Rocks-2026' });
    expect(personal.status).toBe(422);

    const same = await api()
      .post(url)
      .set(bearer(u.token))
      .set('Cookie', u.cookie)
      .send({ currentPassword: u.password, newPassword: u.password });
    expect(same.status).toBe(422);
    expect(same.body.error.details[0].message).toMatch(/recently/);

    const ok = await api()
      .post(url)
      .set(bearer(u.token))
      .set('Cookie', u.cookie)
      .send({ currentPassword: u.password, newPassword: 'Fresh-Valid-Pass-9' });
    expect(ok.status).toBe(204);

    expect((await api().get('/api/v1/auth/me').set(bearer(u.token))).status).toBe(401);
    expect((await api().post('/api/v1/auth/refresh').set('Cookie', u.cookie)).status).toBe(200);
    expect((await api().post('/api/v1/auth/refresh').set('Cookie', other.cookie)).status).toBe(401);
    expect((await lastMail(u.email, 'PASSWORD_CHANGED')).subject).toContain('password was changed');
    await login(u.email, 'Fresh-Valid-Pass-9');
  });
});

describe('forgot / reset password', () => {
  test('always 202; unknown email sends nothing', async () => {
    const res = await api()
      .post('/api/v1/auth/password/forgot')
      .send({ email: 'nobody@test.local' });
    expect(res.status).toBe(202);
    expect(await lastMail('nobody@test.local')).toBeNull();
  });

  test('reset link: check, policy, single use, signs out everywhere, confirmation email', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'forgetful@test.local',
      roles: ['SALES_EXEC'],
    });
    expect((await api().post('/api/v1/auth/password/forgot').send({ email: u.email })).status).toBe(
      202,
    );
    const token = tokenFromMail((await lastMail(u.email, 'PASSWORD_RESET')).html);

    const check = await api().post('/api/v1/auth/password/reset/check').send({ token });
    expect(check.status).toBe(200);
    expect(check.body.data.email).toBe(u.email);

    const wrongPurpose = await api().post('/api/v1/auth/invitations/check').send({ token });
    expect(wrongPurpose.status).toBe(422);

    const weak = await api()
      .post('/api/v1/auth/password/reset')
      .send({ token, newPassword: 'abc' });
    expect(weak.status).toBe(422);

    const reused = await api()
      .post('/api/v1/auth/password/reset')
      .send({ token, newPassword: u.password });
    expect(reused.status).toBe(422);

    const ok = await api()
      .post('/api/v1/auth/password/reset')
      .send({ token, newPassword: 'Brand-New-Secret-7' });
    expect(ok.status).toBe(204);

    const again = await api()
      .post('/api/v1/auth/password/reset')
      .send({ token, newPassword: 'Another-New-Secret-8' });
    expect(again.status).toBe(422);
    expect((await api().get('/api/v1/auth/me').set(bearer(u.token))).status).toBe(401);
    expect((await api().post('/api/v1/auth/refresh').set('Cookie', u.cookie)).status).toBe(401);
    expect((await lastMail(u.email, 'PASSWORD_RESET_CONFIRMATION')).subject).toContain('was reset');
    await login(u.email, 'Brand-New-Secret-7');
  });

  test('an expired link is refused', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'slowreader@test.local',
      roles: ['SALES_EXEC'],
    });
    await api().post('/api/v1/auth/password/forgot').send({ email: u.email });
    const token = tokenFromMail((await lastMail(u.email, 'PASSWORD_RESET')).html);
    const conn = await dba();
    await conn.query(
      "UPDATE password_reset_token t JOIN `user` u ON u.id = t.user_id SET t.expires_at = UTC_TIMESTAMP(3) - INTERVAL 1 MINUTE WHERE u.email = ? AND t.purpose = 'RESET'",
      [u.email],
    );
    const res = await api()
      .post('/api/v1/auth/password/reset')
      .send({ token, newPassword: 'Late-But-Valid-11' });
    expect(res.status).toBe(422);
  });
});

describe('sessions', () => {
  test('lists my sessions with the current one marked, and revokes another', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'multi@test.local',
      roles: ['SALES_EXEC'],
    });
    const second = await login(u.email, u.password);
    const list = await api()
      .get('/api/v1/auth/sessions')
      .set(bearer(u.token))
      .set('Cookie', u.cookie);
    expect(list.status).toBe(200);
    expect(list.body.data).toHaveLength(2);
    expect(list.body.data.filter((s) => s.isCurrent)).toHaveLength(1);

    const other = list.body.data.find((s) => !s.isCurrent);
    expect(
      (await api().delete(`/api/v1/auth/sessions/${other.id}`).set(bearer(u.token))).status,
    ).toBe(204);
    expect((await api().post('/api/v1/auth/refresh').set('Cookie', second.cookie)).status).toBe(
      401,
    );
    expect(
      (await api().delete(`/api/v1/auth/sessions/${other.id}`).set(bearer(u.token))).status,
    ).toBe(404);
  });
});

describe('token separation (10.14) and token checks', () => {
  const sign = (secret, opts) =>
    jwt.sign({ tv: 1 }, secret, { algorithm: 'HS512', subject: '1', expiresIn: 300, ...opts });

  test.each([
    [
      'foreign secret',
      () =>
        sign('x'.repeat(80), {
          keyid: config.auth.keys[0].kid,
          issuer: 'sales-crm-api',
          audience: 'sales-crm-ui',
        }),
    ],
    [
      'Orchestrator issuer / audience',
      () =>
        sign(config.auth.keys[0].secret, {
          keyid: config.auth.keys[0].kid,
          issuer: 'ugwebapplicationapi',
          audience: 'ugwebapplicationapi-clients',
        }),
    ],
    [
      'unknown key id',
      () =>
        sign(config.auth.keys[0].secret, {
          keyid: 'other-kid',
          issuer: 'sales-crm-api',
          audience: 'sales-crm-ui',
        }),
    ],
    [
      'HS256 algorithm',
      () =>
        jwt.sign({ tv: 1 }, config.auth.keys[0].secret, {
          algorithm: 'HS256',
          keyid: config.auth.keys[0].kid,
          subject: '1',
          issuer: 'sales-crm-api',
          audience: 'sales-crm-ui',
        }),
    ],
    [
      'alg none',
      () =>
        `${Buffer.from('{"alg":"none","typ":"JWT"}').toString('base64url')}.${Buffer.from('{"sub":"1","tv":1}').toString('base64url')}.`,
    ],
  ])('%s -> 401', async (_name, make) => {
    const res = await api().get('/api/v1/auth/me').set(bearer(make()));
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('UNAUTHENTICATED');
  });

  test('expired token -> 401 TOKEN_EXPIRED', async () => {
    const token = jwt.sign({ tv: 1 }, config.auth.keys[0].secret, {
      algorithm: 'HS512',
      keyid: config.auth.keys[0].kid,
      subject: '1',
      issuer: 'sales-crm-api',
      audience: 'sales-crm-ui',
      expiresIn: -10,
    });
    const res = await api().get('/api/v1/auth/me').set(bearer(token));
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_EXPIRED');
  });
});

describe('invitation', () => {
  test('policy is enforced on the first password and the link works once', async () => {
    const ids = (await api().get('/api/v1/roles').set(bearer(admin.token))).body.data;
    const exec = ids.find((r) => r.code === 'SALES_EXEC').id;
    const created = await api()
      .post('/api/v1/users')
      .set(bearer(admin.token))
      .send({ email: 'newbie@test.local', fullName: 'New Bie', roleIds: [exec] });
    expect(created.status).toBe(201);
    expect(created.body.data.status).toBe('INVITED');

    const invited = await api()
      .post('/api/v1/auth/login')
      .send({ email: 'newbie@test.local', password: STRONG });
    expect(invited.status).toBe(401);

    const token = tokenFromMail((await lastMail('newbie@test.local', 'USER_INVITATION')).html);
    expect(
      (await api().post('/api/v1/auth/invitations/check').send({ token })).body.data.fullName,
    ).toBe('New Bie');
    expect(
      (
        await api()
          .post('/api/v1/auth/invitations/accept')
          .send({ token, newPassword: 'password123' })
      ).status,
    ).toBe(422);
    expect(
      (await api().post('/api/v1/auth/invitations/accept').send({ token, newPassword: STRONG }))
        .status,
    ).toBe(204);
    expect(
      (await api().post('/api/v1/auth/invitations/accept').send({ token, newPassword: STRONG }))
        .status,
    ).toBe(422);
    await login('newbie@test.local', STRONG);
  });
});
