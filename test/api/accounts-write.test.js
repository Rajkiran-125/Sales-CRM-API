'use strict';

/**
 * Accounts write (V020): create with duplicate check (BR-AC-02), edit with owner rules and
 * optimistic lock (BR-AC-01). Fixtures: two unrelated execs, a head with ALL scope, pre-sales.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, exec2, head, presales;

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'acc.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  exec2 = await createActiveUser(admin.token, {
    email: 'acc.exec2@test.local',
    roles: ['SALES_EXEC'],
  });
  head = await createActiveUser(admin.token, {
    email: 'acc.head@test.local',
    roles: ['SALES_HEAD'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'acc.presales@test.local',
    roles: ['PRESALES'],
  });
});

afterAll(closeAll);

const create = (token, body) => api().post('/api/v1/accounts').set(bearer(token)).send(body);

describe('POST /accounts', () => {
  let firstId;

  test('exec creates an account; owner defaults to the creator', async () => {
    const res = await create(exec.token, {
      name: 'Acme Write Ltd',
      gstNo: '27aapca1234b1z5',
      website: 'https://www.acme-write.test/',
      backupOwnerUserId: exec2.id,
    });
    expect(res.status).toBe(201);
    expect(res.body.data.accountNo).toMatch(/^ACC-\d{4,}$/);
    firstId = res.body.data.id;

    const c = await dba();
    const [[row]] = await c.query(
      'SELECT owner_user_id AS o, backup_owner_user_id AS b, gst_no AS g, account_type AS t FROM account WHERE id = ?',
      [firstId],
    );
    expect(row).toEqual({ o: exec.id, b: exec2.id, g: '27AAPCA1234B1Z5', t: 'PROSPECT' });
    const [[audit]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log WHERE entity_type = 'account' AND entity_id = ? AND action = 'ACCOUNT_CREATE'`,
      [firstId],
    );
    expect(audit.n).toBe(1);
  });

  test.each([
    ['name', { name: 'Acme Write Ltd' }],
    ['gstNo', { name: 'Other Name 1', gstNo: '27AAPCA1234B1Z5' }],
    ['website', { name: 'Other Name 2', website: 'acme-write.test' }],
  ])('duplicate by %s → 409 DUPLICATE', async (field, body) => {
    const res = await create(exec.token, body);
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('DUPLICATE');
    expect(res.body.error.details[0].field).toBe(field);
  });

  test('ignoreDuplicates saves anyway', async () => {
    const res = await create(exec.token, { name: 'Acme Write Ltd', ignoreDuplicates: true });
    expect(res.status).toBe(201);
  });

  test('invalid GST → 422', async () => {
    const res = await create(exec.token, { name: 'Bad GST Co', gstNo: 'ABC' });
    expect(res.status).toBe(422);
    expect(res.body.error.details[0].field).toBe('gstNo');
  });

  test('exec cannot make someone outside the team the owner → 403', async () => {
    const res = await create(exec.token, { name: 'Not Mine Co', ownerUserId: exec2.id });
    expect(res.status).toBe(403);
  });

  test('backup equal to owner → 422', async () => {
    const res = await create(exec.token, { name: 'Same Person Co', backupOwnerUserId: exec.id });
    expect(res.status).toBe(422);
  });

  test('ALL-scope head may assign any owner', async () => {
    const res = await create(head.token, { name: 'Assigned Co', ownerUserId: exec2.id });
    expect(res.status).toBe(201);
  });

  test('pre-sales has no account.create → 403', async () => {
    const res = await create(presales.token, { name: 'No Right Co' });
    expect(res.status).toBe(403);
  });

  describe('PATCH /accounts/:id', () => {
    const patch = (token, id, body) =>
      api().patch(`/api/v1/accounts/${id}`).set(bearer(token)).send(body);

    test('360 returns the edit fields', async () => {
      const res = await api().get(`/api/v1/accounts/${firstId}/360`).set(bearer(exec.token));
      expect(res.status).toBe(200);
      expect(res.body.data.account).toMatchObject({
        ownerUserId: exec.id,
        backupOwnerUserId: exec2.id,
        rowVersion: 1,
      });
    });

    test('owner edits; null owner keeps the current owner; version bumps', async () => {
      const res = await patch(exec.token, firstId, {
        name: 'Acme Write Ltd',
        accountType: 'CUSTOMER',
        city: 'Pune',
        rowVersion: 1,
        backupOwnerUserId: exec2.id,
        ignoreDuplicates: true,
      });
      expect(res.status).toBe(200);
      expect(res.body.data.rowVersion).toBe(2);
      const c = await dba();
      const [[row]] = await c.query('SELECT owner_user_id AS o, city FROM account WHERE id = ?', [
        firstId,
      ]);
      expect(row).toEqual({ o: exec.id, city: 'Pune' });
    });

    test('stale rowVersion → 409 CONFLICT', async () => {
      const res = await patch(exec.token, firstId, {
        name: 'Acme Write Ltd',
        rowVersion: 1,
        ignoreDuplicates: true,
      });
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('CONFLICT');
    });

    test('a user who is neither owner, backup nor their manager → 403', async () => {
      const other = await createActiveUser(admin.token, {
        email: 'acc.exec3@test.local',
        roles: ['SALES_EXEC'],
      });
      const res = await patch(other.token, firstId, {
        name: 'Acme Write Ltd',
        rowVersion: 2,
        ignoreDuplicates: true,
      });
      expect(res.status).toBe(403);
    });

    test('backup owner may edit', async () => {
      const res = await patch(exec2.token, firstId, {
        name: 'Acme Write Ltd',
        accountType: 'CUSTOMER',
        rowVersion: 2,
        backupOwnerUserId: exec2.id,
        ignoreDuplicates: true,
      });
      expect(res.status).toBe(200);
    });

    test('head reassigns the owner; history in audit_log (BR-AC-01)', async () => {
      const res = await patch(head.token, firstId, {
        name: 'Acme Write Ltd',
        accountType: 'CUSTOMER',
        ownerUserId: exec2.id,
        backupOwnerUserId: exec.id,
        rowVersion: 3,
        ignoreDuplicates: true,
      });
      expect(res.status).toBe(200);
      const c = await dba();
      const [[a]] = await c.query(
        `SELECT JSON_EXTRACT(changed_fields_json, '$.ownerUserId') AS o FROM audit_log
          WHERE entity_type = 'account' AND entity_id = ? AND action = 'ACCOUNT_UPDATE'
          ORDER BY id DESC LIMIT 1`,
        [firstId],
      );
      const o = typeof a.o === 'string' ? JSON.parse(a.o) : a.o;
      expect(o).toEqual({ from: exec.id, to: exec2.id });
    });

    test('unknown account → 404', async () => {
      const res = await patch(head.token, 999999999, { name: 'X', rowVersion: 1 });
      expect(res.status).toBe(404);
    });
  });
});

describe('POST /accounts/:id/merge (V028)', () => {
  let keep, dup;

  beforeAll(async () => {
    keep = (await create(exec.token, { name: 'Merge Keep Ltd' })).body.data.id;
    dup = (await create(exec.token, { name: 'Merge Keep Limited', ignoreDuplicates: true })).body
      .data.id;
    const c = await dba();
    await c.query(`INSERT INTO contact (account_id, name) VALUES (?, 'Dup Contact')`, [dup]);
    await c.query(
      `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
         weighted_value, expected_close_date, owner_user_id)
       VALUES ('MRG-OPP-1', 'Merge Deal', ?, 'DIRECT', 'QUALIFIED', 1000, 200, '2099-01-01', ?)`,
      [dup, exec.id],
    );
    await c.query(
      `UPDATE account SET account_type = 'CUSTOMER', first_won_on = '2025-04-01' WHERE id = ?`,
      [dup],
    );
  });

  test('without account.merge → 403; into itself → 422', async () => {
    const send = (token, id, survivor) =>
      api()
        .post(`/api/v1/accounts/${id}/merge`)
        .set(bearer(token))
        .send({ survivorAccountId: survivor });
    expect((await send(exec.token, dup, keep)).status).toBe(403);
    expect((await send(admin.token, dup, dup)).status).toBe(422);
  });

  test('admin merges: records move, the duplicate is retired, both audited', async () => {
    const res = await api()
      .post(`/api/v1/accounts/${dup}/merge`)
      .set(bearer(admin.token))
      .send({ survivorAccountId: keep });
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({
      id: keep,
      moved: expect.objectContaining({ contacts: 1, opportunities: 1 }),
    });

    const c = await dba();
    const [[d]] = await c.query(
      'SELECT is_active AS a, merged_into_account_id AS m FROM account WHERE id = ?',
      [dup],
    );
    expect(d).toEqual({ a: 0, m: keep });
    const [[k]] = await c.query(
      `SELECT account_type AS t, DATE_FORMAT(first_won_on, '%Y-%m-%d') AS f,
              (SELECT COUNT(*) FROM opportunity WHERE account_id = ?) AS opps
         FROM account WHERE id = ?`,
      [keep, keep],
    );
    expect(k).toEqual({ t: 'CUSTOMER', f: '2025-04-01', opps: 1 });
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log WHERE action = 'ACCOUNT_MERGE' AND entity_id IN (?, ?)`,
      [dup, keep],
    );
    expect(log.n).toBe(2);

    // retired: no longer visible, so it cannot be merged again
    const again = await api()
      .post(`/api/v1/accounts/${dup}/merge`)
      .set(bearer(admin.token))
      .send({ survivorAccountId: keep });
    expect(again.status).toBe(404);
  });
});

describe('GET /accounts/export', () => {
  test('xlsx of the visible accounts only; logged as EXPORT', async () => {
    const res = await api()
      .get('/api/v1/accounts/export?search=Merge')
      .set(bearer(exec.token))
      .buffer(true)
      .parse((r, cb) => {
        const chunks = [];
        r.on('data', (ch) => chunks.push(ch));
        r.on('end', () => cb(null, Buffer.concat(chunks)));
      });
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/spreadsheetml/);
    const ExcelJS = require('exceljs');
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(res.body);
    const names = wb.worksheets[0].getColumn(2).values.slice(2);
    expect(names).toEqual(['Merge Keep Ltd']);

    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM record_access_log
        WHERE user_id = ? AND entity_type = 'ACCOUNT' AND access_type = 'EXPORT'`,
      [exec.id],
    );
    expect(log.n).toBe(1);
  });

  test('pre-sales has account.view but no report.export → 403', async () => {
    const res = await api().get('/api/v1/accounts/export').set(bearer(presales.token));
    expect(res.status).toBe(403);
  });
});
