'use strict';

/** User, role and permission administration (11.4, 21.1 role/permission rows, 21.2 journey 6). */
const {
  api,
  dba,
  closeAll,
  lastMail,
  tokenFromMail,
  login,
  adminSession,
  createActiveUser,
  roleIds,
  bearer,
  STRONG,
} = require('../helpers');

let admin;
let roles;
beforeAll(async () => {
  admin = await adminSession();
  roles = await roleIds(admin.token);
});
afterAll(closeAll);

describe('permission enforcement', () => {
  test('a Sales Executive cannot use the administration endpoints (403) and the denial is logged', async () => {
    const exec = await createActiveUser(admin.token, {
      email: 'exec.denied@test.local',
      roles: ['SALES_EXEC'],
    });
    for (const [method, url] of [
      ['get', '/api/v1/users'],
      ['get', '/api/v1/roles'],
      ['get', '/api/v1/permissions'],
      ['get', '/api/v1/audit-logs'],
      ['get', '/api/v1/settings'],
      ['get', '/api/v1/email-templates'],
      ['post', '/api/v1/masters/industries'],
    ]) {
      const res = await api()[method](url).set(bearer(exec.token)).send({});
      expect([method, url, res.status]).toEqual([method, url, 403]);
      expect(res.body.error.code).toBe('FORBIDDEN');
    }
    const conn = await dba();
    const [rows] = await conn.query(
      "SELECT COUNT(*) AS n FROM security_event_log WHERE event_code = 'ACCESS_DENIED' AND user_id = ?",
      [exec.id],
    );
    expect(rows[0].n).toBe(7);
  });

  test('every signed-in user can use the user lookup and read masters', async () => {
    const exec = await createActiveUser(admin.token, {
      email: 'exec.lookup@test.local',
      roles: ['SALES_EXEC'],
    });
    const lookup = await api().get('/api/v1/users/lookup?search=admin').set(bearer(exec.token));
    expect(lookup.status).toBe(200);
    expect(lookup.body.data[0]).toEqual(
      expect.objectContaining({ email: 'admin@test.local', fullName: 'Test Admin' }),
    );
    expect(lookup.body.data[0]).not.toHaveProperty('passwordHash');
    const industries = await api().get('/api/v1/masters/industries').set(bearer(exec.token));
    expect(industries.status).toBe(200);
    expect(industries.body.data.map((i) => i.code)).toContain('BFSI');
  });
});

describe('users', () => {
  test('create validates input: email format, unknown fields, missing roles, duplicates', async () => {
    const url = '/api/v1/users';
    const bad = await api()
      .post(url)
      .set(bearer(admin.token))
      .send({ email: 'not-an-email', fullName: 'X', roleIds: [roles.SALES_EXEC] });
    expect(bad.status).toBe(422);
    expect(bad.body.error.details[0].field).toBe('email');

    const extra = await api()
      .post(url)
      .set(bearer(admin.token))
      .send({
        email: 'extra@test.local',
        fullName: 'Extra',
        roleIds: [roles.SALES_EXEC],
        status: 'ACTIVE',
      });
    expect(extra.status).toBe(422);

    const noRole = await api()
      .post(url)
      .set(bearer(admin.token))
      .send({ email: 'norole@test.local', fullName: 'No Role', roleIds: [] });
    expect(noRole.status).toBe(422);

    const unknownRole = await api()
      .post(url)
      .set(bearer(admin.token))
      .send({ email: 'ghostrole@test.local', fullName: 'Ghost', roleIds: [999999] });
    expect(unknownRole.status).toBe(422);
    expect(unknownRole.body.error.details[0].field).toBe('roleIds');

    const first = await api()
      .post(url)
      .set(bearer(admin.token))
      .send({ email: 'dupe@test.local', fullName: 'Dupe', roleIds: [roles.SALES_EXEC] });
    expect(first.status).toBe(201);
    const dupe = await api()
      .post(url)
      .set(bearer(admin.token))
      .send({ email: 'DUPE@test.local', fullName: 'Dupe 2', roleIds: [roles.SALES_EXEC] });
    expect(dupe.status).toBe(409);
    expect(dupe.body.error.code).toBe('DUPLICATE');
  });

  test('list supports search, status filter, sort and paging', async () => {
    const res = await api()
      .get('/api/v1/users?search=dupe&status=INVITED&sort=-name&page=1&pageSize=5')
      .set(bearer(admin.token));
    expect(res.status).toBe(200);
    expect(res.body.meta).toEqual({ page: 1, pageSize: 5, total: 1, sort: '-name' });
    expect(res.body.data[0]).toMatchObject({
      email: 'dupe@test.local',
      status: 'INVITED',
      roles: [expect.objectContaining({ code: 'SALES_EXEC' })],
    });

    const badSort = await api().get('/api/v1/users?sort=password').set(bearer(admin.token));
    expect(badSort.status).toBe(422);
  });

  test('update: optimistic locking, reporting-line loops, audit trail', async () => {
    const head = await createActiveUser(admin.token, {
      email: 'head@test.local',
      fullName: 'Head Person',
      roles: ['SALES_HEAD'],
    });
    const exec = await createActiveUser(admin.token, {
      email: 'teamexec@test.local',
      fullName: 'Team Exec',
      roles: ['SALES_EXEC'],
      reportingToUserId: head.id,
    });
    const current = (await api().get(`/api/v1/users/${exec.id}`).set(bearer(admin.token))).body
      .data;
    expect(current.reportingToName).toBe('Head Person');

    const ok = await api().patch(`/api/v1/users/${exec.id}`).set(bearer(admin.token)).send({
      rowVersion: current.rowVersion,
      designation: 'Senior Executive',
      mobile: '+919876543210',
    });
    expect(ok.status).toBe(200);
    expect(ok.body.data).toMatchObject({
      designation: 'Senior Executive',
      mobile: '+919876543210',
      rowVersion: current.rowVersion + 1,
    });

    const stale = await api()
      .patch(`/api/v1/users/${exec.id}`)
      .set(bearer(admin.token))
      .send({ rowVersion: current.rowVersion, designation: 'Stale' });
    expect(stale.status).toBe(409);
    expect(stale.body.error.code).toBe('CONFLICT');

    const headNow = (await api().get(`/api/v1/users/${head.id}`).set(bearer(admin.token))).body
      .data;
    const loop = await api()
      .patch(`/api/v1/users/${head.id}`)
      .set(bearer(admin.token))
      .send({ rowVersion: headNow.rowVersion, reportingToUserId: exec.id });
    expect(loop.status).toBe(422);
    expect(loop.body.error.details[0]).toMatchObject({ field: 'reportingToUserId' });

    const audit = await api()
      .get(`/api/v1/audit-logs?entityType=USER&entityId=${exec.id}&action=UPDATE`)
      .set(bearer(admin.token));
    expect(audit.body.data[0].changes).toMatchObject({ designation: { to: 'Senior Executive' } });
  });

  test('the last active CRM Admin cannot lose the role or be deactivated', async () => {
    const me = (await api().get('/api/v1/auth/me').set(bearer(admin.token))).body.data;
    const detail = (await api().get(`/api/v1/users/${me.id}`).set(bearer(admin.token))).body.data;
    const res = await api()
      .patch(`/api/v1/users/${me.id}`)
      .set(bearer(admin.token))
      .send({ rowVersion: detail.rowVersion, roleIds: [roles.SALES_HEAD] });
    expect(res.status).toBe(422);
    expect(res.body.error.message).toMatch(/CRM Admin must remain/);

    const self = await api()
      .post(`/api/v1/users/${me.id}/status`)
      .set(bearer(admin.token))
      .send({ status: 'INACTIVE', reason: 'test' });
    expect(self.status).toBe(422);
  });

  test('deactivation signs the user out at once; reactivation restores access', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'leaver@test.local',
      roles: ['SALES_EXEC'],
    });
    const noReason = await api()
      .post(`/api/v1/users/${u.id}/status`)
      .set(bearer(admin.token))
      .send({ status: 'INACTIVE', reason: '' });
    expect(noReason.status).toBe(422);

    const off = await api()
      .post(`/api/v1/users/${u.id}/status`)
      .set(bearer(admin.token))
      .send({ status: 'INACTIVE', reason: 'Left the company' });
    expect(off.status).toBe(200);
    expect(off.body.data).toMatchObject({
      status: 'INACTIVE',
      deactivationReason: 'Left the company',
    });
    expect((await api().get('/api/v1/auth/me').set(bearer(u.token))).status).toBe(401);
    expect((await api().post('/api/v1/auth/refresh').set('Cookie', u.cookie)).status).toBe(401);
    expect(
      (await api().post('/api/v1/auth/login').send({ email: u.email, password: u.password }))
        .status,
    ).toBe(401);

    const on = await api()
      .post(`/api/v1/users/${u.id}/status`)
      .set(bearer(admin.token))
      .send({ status: 'ACTIVE', reason: 'Rejoined' });
    expect(on.body.data.status).toBe('ACTIVE');
    await login(u.email, u.password);
  });

  test('admin password reset sends a link; resend invitation works only for invited users', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'adminreset@test.local',
      roles: ['SALES_EXEC'],
    });
    expect(
      (await api().post(`/api/v1/users/${u.id}/password-reset`).set(bearer(admin.token))).status,
    ).toBe(204);
    const token = tokenFromMail((await lastMail(u.email, 'PASSWORD_RESET')).html);
    expect(
      (
        await api()
          .post('/api/v1/auth/password/reset')
          .send({ token, newPassword: 'Admin-Set-Not!42x' })
      ).status,
    ).toBe(204);

    const resendActive = await api()
      .post(`/api/v1/users/${u.id}/invitation`)
      .set(bearer(admin.token));
    expect(resendActive.status).toBe(422);

    const invited = await api()
      .post('/api/v1/users')
      .set(bearer(admin.token))
      .send({ email: 'resend@test.local', fullName: 'Resend Me', roleIds: [roles.PRESALES] });
    const firstToken = tokenFromMail((await lastMail('resend@test.local', 'USER_INVITATION')).html);
    expect(
      (
        await api()
          .post(`/api/v1/users/${invited.body.data.id}/invitation`)
          .set(bearer(admin.token))
      ).status,
    ).toBe(204);
    const secondToken = tokenFromMail(
      (await lastMail('resend@test.local', 'USER_INVITATION')).html,
    );
    expect(secondToken).not.toBe(firstToken);
    expect(
      (await api().post('/api/v1/auth/invitations/check').send({ token: firstToken })).status,
    ).toBe(422);
    expect(
      (
        await api()
          .post('/api/v1/auth/invitations/accept')
          .send({ token: secondToken, newPassword: STRONG })
      ).status,
    ).toBe(204);
  });

  test('revoke sessions signs the user out everywhere', async () => {
    const u = await createActiveUser(admin.token, {
      email: 'revokee@test.local',
      roles: ['SALES_EXEC'],
    });
    expect(
      (await api().post(`/api/v1/users/${u.id}/sessions/revoke`).set(bearer(admin.token))).status,
    ).toBe(204);
    expect((await api().get('/api/v1/auth/me').set(bearer(u.token))).status).toBe(401);
    expect((await api().post('/api/v1/auth/refresh').set('Cookie', u.cookie)).status).toBe(401);
  });

  test('unknown user -> 404', async () => {
    expect((await api().get('/api/v1/users/987654').set(bearer(admin.token))).status).toBe(404);
    expect((await api().post('/api/v1/users/987654/unlock').set(bearer(admin.token))).status).toBe(
      404,
    );
  });
});

describe('roles and the permission matrix', () => {
  test('seven system roles with the seeded data scopes; catalogue grouped by module', async () => {
    const list = (await api().get('/api/v1/roles').set(bearer(admin.token))).body.data;
    expect(list.filter((r) => r.isSystem).map((r) => [r.code, r.dataScope])).toEqual(
      expect.arrayContaining([
        ['SALES_EXEC', 'OWN_AND_TEAM'],
        ['PRESALES', 'ASSIGNED_AND_TEAM'],
        ['PARTNER_MGR', 'PARTNER_OWNED'],
        ['SALES_HEAD', 'ALL'],
        ['MANAGEMENT', 'ALL'],
        ['FINANCE', 'MODULE_LIMITED'],
        ['CRM_ADMIN', 'ALL'],
      ]),
    );
    const catalogue = (await api().get('/api/v1/permissions').set(bearer(admin.token))).body.data;
    expect(catalogue.map((g) => g.module)).toEqual(
      expect.arrayContaining(['LEADS', 'OPPORTUNITIES', 'ADMINISTRATION']),
    );
    expect(catalogue.flatMap((g) => g.permissions)).toHaveLength(69);

    const finance = (await api().get(`/api/v1/roles/${roles.FINANCE}`).set(bearer(admin.token)))
      .body.data;
    expect(finance.moduleScopes).toEqual(['ORDERS']);
    expect(finance.permissionCodes).toContain('order.finance');
    expect(finance.permissionCodes).not.toContain('lead.view');
  });

  test('a new role and a permission change apply to the next request', async () => {
    const created = await api()
      .post('/api/v1/roles')
      .set(bearer(admin.token))
      .send({
        code: 'auditor_lite',
        name: 'Auditor Lite',
        description: 'Reads users',
        dataScope: 'ALL',
        permissionCodes: ['dashboard.view'],
      });
    expect(created.status).toBe(201);
    expect(created.body.data).toMatchObject({
      code: 'AUDITOR_LITE',
      isSystem: false,
      permissionCodes: ['dashboard.view'],
    });

    const ids = await roleIds(admin.token);
    const res = await api()
      .post('/api/v1/users')
      .set(bearer(admin.token))
      .send({ email: 'auditor@test.local', fullName: 'Audrey Tor', roleIds: [ids.AUDITOR_LITE] });
    expect(res.status).toBe(201);
    const token = tokenFromMail((await lastMail('auditor@test.local', 'USER_INVITATION')).html);
    await api().post('/api/v1/auth/invitations/accept').send({ token, newPassword: STRONG });
    const s = await login('auditor@test.local', STRONG);
    expect((await api().get('/api/v1/users').set(bearer(s.token))).status).toBe(403);

    const upd = await api()
      .patch(`/api/v1/roles/${ids.AUDITOR_LITE}`)
      .set(bearer(admin.token))
      .send({ rowVersion: 1, permissionCodes: ['dashboard.view', 'user.view'] });
    expect(upd.status).toBe(200);
    expect(upd.body.data.permissionCodes).toEqual(['dashboard.view', 'user.view']);
    expect((await api().get('/api/v1/users').set(bearer(s.token))).status).toBe(200);
  });

  test('role rules: unknown permission, system role deactivation, CRM Admin lock-out, module scope', async () => {
    const unknown = await api()
      .post('/api/v1/roles')
      .set(bearer(admin.token))
      .send({
        code: 'BAD_ROLE',
        name: 'Bad Role',
        dataScope: 'ALL',
        permissionCodes: ['nope.view'],
      });
    expect(unknown.status).toBe(422);

    const execRole = (await api().get(`/api/v1/roles/${roles.SALES_EXEC}`).set(bearer(admin.token)))
      .body.data;
    const deactivate = await api()
      .patch(`/api/v1/roles/${roles.SALES_EXEC}`)
      .set(bearer(admin.token))
      .send({ rowVersion: execRole.rowVersion, isActive: false });
    expect(deactivate.status).toBe(422);

    const adminRole = (await api().get(`/api/v1/roles/${roles.CRM_ADMIN}`).set(bearer(admin.token)))
      .body.data;
    const lockout = await api()
      .patch(`/api/v1/roles/${roles.CRM_ADMIN}`)
      .set(bearer(admin.token))
      .send({
        rowVersion: adminRole.rowVersion,
        permissionCodes: adminRole.permissionCodes.filter((c) => c !== 'role.manage'),
      });
    expect(lockout.status).toBe(422);

    const noModules = await api()
      .post('/api/v1/roles')
      .set(bearer(admin.token))
      .send({
        code: 'FIN_LITE',
        name: 'Finance Lite',
        dataScope: 'MODULE_LIMITED',
        permissionCodes: ['order.view'],
        moduleScopes: [],
      });
    expect(noModules.status).toBe(422);

    const dup = await api()
      .post('/api/v1/roles')
      .set(bearer(admin.token))
      .send({ code: 'SALES_EXEC', name: 'Another', dataScope: 'ALL', permissionCodes: [] });
    expect(dup.status).toBe(409);
  });

  test('matrix spot checks (11.3)', async () => {
    const checks = [
      ['MANAGEMENT', 'opportunity.validate', true],
      ['MANAGEMENT', 'lead.create', false],
      ['PRESALES', 'partner_commercial.view', false],
      ['SALES_HEAD', 'offer.approve', true],
      ['SALES_EXEC', 'offer.approve', false],
      ['CRM_ADMIN', 'opportunity.validate', false],
      ['FINANCE', 'order.finance', true],
      ['PARTNER_MGR', 'partner.engagement.manage', true],
    ];
    for (const [code, perm, expected] of checks) {
      const role = (await api().get(`/api/v1/roles/${roles[code]}`).set(bearer(admin.token))).body
        .data;
      expect([code, perm, role.permissionCodes.includes(perm)]).toEqual([code, perm, expected]);
    }
  });
});
