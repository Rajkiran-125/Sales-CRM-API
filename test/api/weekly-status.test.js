'use strict';

/**
 * Weekly status write side (V015): upsert and delete.
 * Fixture: exec owns a deal; head has ALL scope.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, head;
let oppId, accountId, industryId;

// next Monday from a given date
function nextMonday(from = new Date()) {
  const d = new Date(from);
  d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7));
  return d.toISOString().slice(0, 10);
}

const THIS_MONDAY = nextMonday();

const BASE_BODY = () => ({
  opportunityId: oppId,
  weekStart: THIS_MONDAY,
  status: 'ON_TRACK',
  thisWeek: 'Had a productive call with the CTO.',
  nextStep: 'Send proposal by Friday.',
});

let seq = 0;

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'ws.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  head = await createActiveUser(admin.token, {
    email: 'ws.head@test.local',
    roles: ['SALES_HEAD'],
  });

  const c = await dba();
  industryId = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI' LIMIT 1`))[0][0].id;

  accountId = (
    await c.query(
      `INSERT INTO account (account_no, name, industry_id, owner_user_id) VALUES (?,?,?,?)`,
      [`WS-ACC-${++seq}`, 'Weekly Status Corp', industryId, exec.id],
    )
  )[0].insertId;

  oppId = (
    await c.query(
      `INSERT INTO opportunity
         (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
          expected_close_date, owner_user_id)
       VALUES (?, 'Weekly Status Deal', ?, 'DIRECT', 'QUALIFIED', 1000000, 200000, '2099-01-01', ?)`,
      [`WS-OPP-${++seq}`, accountId, exec.id],
    )
  )[0].insertId;
});

afterAll(closeAll);

// ---------------------------------------------------------------------------
describe('POST /weekly-status (upsert)', () => {
  test('exec submits status for own deal → 200', async () => {
    const res = await api().post('/api/v1/weekly-status').set(bearer(exec.token)).send(BASE_BODY());
    expect(res.status).toBe(200);
    expect(res.body.data.id).toBeGreaterThan(0);
  });

  test('upsert same week updates the existing row → 200', async () => {
    const first = await api()
      .post('/api/v1/weekly-status')
      .set(bearer(exec.token))
      .send(BASE_BODY());
    const firstId = first.body.data.id;

    const second = await api()
      .post('/api/v1/weekly-status')
      .set(bearer(exec.token))
      .send({ ...BASE_BODY(), status: 'AT_RISK', thisWeek: 'Updated summary.' });
    expect(second.status).toBe(200);
    expect(second.body.data.id).toBe(firstId); // same row

    const c = await dba();
    const [[row]] = await c.query(`SELECT status FROM weekly_status WHERE id = ?`, [firstId]);
    expect(row.status).toBe('AT_RISK');
  });

  test('weekStart on a non-Monday → 422', async () => {
    const tuesday = new Date(THIS_MONDAY);
    tuesday.setUTCDate(tuesday.getUTCDate() + 1);
    const res = await api()
      .post('/api/v1/weekly-status')
      .set(bearer(exec.token))
      .send({ ...BASE_BODY(), weekStart: tuesday.toISOString().slice(0, 10) });
    expect(res.status).toBe(422);
  });

  test('head (ALL scope) can submit for any deal → 200', async () => {
    const res = await api()
      .post('/api/v1/weekly-status')
      .set(bearer(head.token))
      .send({ ...BASE_BODY(), weekStart: nextMonday(new Date(THIS_MONDAY + 'T00:00:00Z')) });
    expect(res.status).toBe(200);
  });

  test('another exec cannot submit for a deal they do not own → 403', async () => {
    const other = await createActiveUser(admin.token, {
      email: `ws.other.${++seq}@test.local`,
      roles: ['SALES_EXEC'],
    });
    const mon = nextMonday(
      new Date(new Date(THIS_MONDAY + 'T00:00:00Z').getTime() + 14 * 86400000),
    );
    const res = await api()
      .post('/api/v1/weekly-status')
      .set(bearer(other.token))
      .send({ ...BASE_BODY(), weekStart: mon });
    expect(res.status).toBe(403);
  });

  test('unauthenticated → 401', async () => {
    const res = await api().post('/api/v1/weekly-status').send(BASE_BODY());
    expect(res.status).toBe(401);
  });
});

// ---------------------------------------------------------------------------
describe('DELETE /weekly-status/:id', () => {
  test('owner can delete their own entry → 200', async () => {
    const mon = nextMonday(
      new Date(new Date(THIS_MONDAY + 'T00:00:00Z').getTime() + 21 * 86400000),
    );
    const create = await api()
      .post('/api/v1/weekly-status')
      .set(bearer(exec.token))
      .send({ ...BASE_BODY(), weekStart: mon });
    const id = create.body.data.id;

    const res = await api().delete(`/api/v1/weekly-status/${id}`).set(bearer(exec.token));
    expect(res.status).toBe(200);

    const c = await dba();
    const [[row]] = await c.query(`SELECT id FROM weekly_status WHERE id = ?`, [id]);
    expect(row).toBeUndefined(); // hard delete
  });

  test('non-owner gets 403', async () => {
    const mon = nextMonday(
      new Date(new Date(THIS_MONDAY + 'T00:00:00Z').getTime() + 28 * 86400000),
    );
    const create = await api()
      .post('/api/v1/weekly-status')
      .set(bearer(exec.token))
      .send({ ...BASE_BODY(), weekStart: mon });
    const id = create.body.data.id;

    const other = await createActiveUser(admin.token, {
      email: `ws.del.${++seq}@test.local`,
      roles: ['SALES_EXEC'],
    });
    const res = await api().delete(`/api/v1/weekly-status/${id}`).set(bearer(other.token));
    expect(res.status).toBe(403);
  });
});
