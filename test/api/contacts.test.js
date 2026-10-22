'use strict';

/**
 * DMU write (V017): contacts CRUD + opportunity DMU add/remove.
 * Fixtures: exec owns the account+opportunity; head has ALL scope.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, head;
let accountId, oppId, industryId;
let seq = 0;

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'dmu.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  head = await createActiveUser(admin.token, {
    email: 'dmu.head@test.local',
    roles: ['SALES_HEAD'],
  });

  const c = await dba();
  industryId = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI' LIMIT 1`))[0][0].id;

  accountId = (
    await c.query(
      `INSERT INTO account (account_no, name, industry_id, owner_user_id) VALUES (?,?,?,?)`,
      [`DMU-ACC-${++seq}`, 'DMU Test Corp', industryId, exec.id],
    )
  )[0].insertId;

  oppId = (
    await c.query(
      `INSERT INTO opportunity
         (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
          expected_close_date, owner_user_id)
       VALUES (?, 'DMU Test Deal', ?, 'DIRECT', 'QUALIFIED', 1000000, 200000, '2099-01-01', ?)`,
      [`DMU-OPP-${++seq}`, accountId, exec.id],
    )
  )[0].insertId;
});

afterAll(closeAll);

// ---------------------------------------------------------------------------
describe('POST /contacts (create)', () => {
  test('exec creates a contact on own account → 201', async () => {
    const res = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      name: 'Arjun Mehta',
      designation: 'CTO',
      stand: 'CHAMPION',
      influenceLevel: 5,
    });
    expect(res.status).toBe(201);
    expect(res.body.data.id).toBeGreaterThan(0);
  });

  test('both accountId and partnerId → 422', async () => {
    const res = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      partnerId: 1,
      name: 'Should fail',
      stand: 'UNKNOWN',
    });
    expect(res.status).toBe(422);
  });

  test('neither accountId nor partnerId → 422', async () => {
    const res = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      name: 'Should fail',
      stand: 'UNKNOWN',
    });
    expect(res.status).toBe(422);
  });

  test('missing name → 422', async () => {
    const res = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      stand: 'UNKNOWN',
    });
    expect(res.status).toBe(422);
  });

  test('unauthenticated → 401', async () => {
    const res = await api()
      .post('/api/v1/contacts')
      .send({ accountId, name: 'x', stand: 'UNKNOWN' });
    expect(res.status).toBe(401);
  });
});

// ---------------------------------------------------------------------------
describe('PATCH /contacts/:id (update)', () => {
  let contactId;

  beforeAll(async () => {
    const res = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      name: 'To Update',
      stand: 'NEUTRAL',
    });
    contactId = res.body.data.id;
  });

  test('exec updates contact → 200', async () => {
    const res = await api().patch(`/api/v1/contacts/${contactId}`).set(bearer(exec.token)).send({
      name: 'Updated Name',
      designation: 'VP Sales',
      stand: 'CHAMPION',
      influenceLevel: 4,
    });
    expect(res.status).toBe(200);

    const c = await dba();
    const [[row]] = await c.query(`SELECT name, stand FROM contact WHERE id = ?`, [contactId]);
    expect(row.name).toBe('Updated Name');
    expect(row.stand).toBe('CHAMPION');
  });

  test('non-existent contact → 404', async () => {
    const res = await api().patch('/api/v1/contacts/99999999').set(bearer(exec.token)).send({
      name: 'Ghost',
      stand: 'UNKNOWN',
    });
    expect(res.status).toBe(404);
  });
});

// ---------------------------------------------------------------------------
describe('DELETE /contacts/:id (deactivate)', () => {
  test('exec deactivates a contact → 200', async () => {
    const created = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      name: 'To Delete',
      stand: 'UNKNOWN',
    });
    const id = created.body.data.id;

    const res = await api().delete(`/api/v1/contacts/${id}`).set(bearer(exec.token));
    expect(res.status).toBe(200);

    const c = await dba();
    const [[row]] = await c.query(`SELECT is_active FROM contact WHERE id = ?`, [id]);
    expect(row.is_active).toBe(0);
  });

  test('deactivate already-deactivated → 404', async () => {
    const created = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      name: 'Double Delete',
      stand: 'UNKNOWN',
    });
    const id = created.body.data.id;
    await api().delete(`/api/v1/contacts/${id}`).set(bearer(exec.token));

    const res = await api().delete(`/api/v1/contacts/${id}`).set(bearer(exec.token));
    expect(res.status).toBe(404);
  });
});

// ---------------------------------------------------------------------------
describe('POST /opportunities/:id/dmu (upsert DMU)', () => {
  let contactId;

  beforeAll(async () => {
    const res = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      name: 'Priya Rajan',
      designation: 'CIO',
      stand: 'NEUTRAL',
    });
    contactId = res.body.data.id;
  });

  test('exec adds contact to own deal DMU → 200', async () => {
    const res = await api()
      .post(`/api/v1/opportunities/${oppId}/dmu`)
      .set(bearer(exec.token))
      .send({ contactId, dmuRole: 'TECH_BUYER', stand: 'CHAMPION', influenceLevel: 4 });
    expect(res.status).toBe(200);
    expect(res.body.data.id).toBeGreaterThan(0);
  });

  test('upsert same contact+role updates in place (idempotent) → 200', async () => {
    const r1 = await api()
      .post(`/api/v1/opportunities/${oppId}/dmu`)
      .set(bearer(exec.token))
      .send({ contactId, dmuRole: 'TECH_BUYER', stand: 'BLOCKER', notes: 'Updated' });
    const r2 = await api()
      .post(`/api/v1/opportunities/${oppId}/dmu`)
      .set(bearer(exec.token))
      .send({ contactId, dmuRole: 'TECH_BUYER', stand: 'NEUTRAL' });
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    expect(r1.body.data.id).toBe(r2.body.data.id);
  });

  test('contact from a different account → 422', async () => {
    const c = await dba();
    const otherAccId = (
      await c.query(
        `INSERT INTO account (account_no, name, industry_id, owner_user_id) VALUES (?,?,?,?)`,
        [`DMU-ACC2-${++seq}`, 'Other Corp', industryId, exec.id],
      )
    )[0].insertId;
    const foreignContact = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId: otherAccId,
      name: 'Foreign Contact',
      stand: 'UNKNOWN',
    });
    const res = await api()
      .post(`/api/v1/opportunities/${oppId}/dmu`)
      .set(bearer(exec.token))
      .send({ contactId: foreignContact.body.data.id, dmuRole: 'SPONSOR', stand: 'UNKNOWN' });
    expect(res.status).toBe(422);
  });

  test("non-owner cannot add DMU on another exec's deal → 403", async () => {
    const other = await createActiveUser(admin.token, {
      email: `dmu.other.${++seq}@test.local`,
      roles: ['SALES_EXEC'],
    });
    const res = await api()
      .post(`/api/v1/opportunities/${oppId}/dmu`)
      .set(bearer(other.token))
      .send({ contactId, dmuRole: 'COMM_BUYER', stand: 'UNKNOWN' });
    expect(res.status).toBe(403);
  });

  test('head (ALL scope) can add DMU on any deal → 200', async () => {
    const res = await api()
      .post(`/api/v1/opportunities/${oppId}/dmu`)
      .set(bearer(head.token))
      .send({ contactId, dmuRole: 'COMM_BUYER', stand: 'NEUTRAL' });
    expect(res.status).toBe(200);
  });
});

// ---------------------------------------------------------------------------
describe('DELETE /opportunities/:id/dmu/:dmuId (remove DMU)', () => {
  let dmuId, contactId;

  beforeAll(async () => {
    const cr = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      name: 'To Remove',
      stand: 'UNKNOWN',
    });
    contactId = cr.body.data.id;

    const dr = await api()
      .post(`/api/v1/opportunities/${oppId}/dmu`)
      .set(bearer(exec.token))
      .send({ contactId, dmuRole: 'INFLUENCER_INT', stand: 'UNKNOWN' });
    dmuId = dr.body.data.id;
  });

  test('exec removes DMU entry from own deal → 200', async () => {
    const res = await api()
      .delete(`/api/v1/opportunities/${oppId}/dmu/${dmuId}`)
      .set(bearer(exec.token));
    expect(res.status).toBe(200);
  });

  test('already-removed entry → 404', async () => {
    const res = await api()
      .delete(`/api/v1/opportunities/${oppId}/dmu/${dmuId}`)
      .set(bearer(exec.token));
    expect(res.status).toBe(404);
  });

  test("non-owner cannot remove DMU from another exec's deal → 403", async () => {
    const cr = await api().post('/api/v1/contacts').set(bearer(exec.token)).send({
      accountId,
      name: 'Block Attempt',
      stand: 'UNKNOWN',
    });
    const dr = await api()
      .post(`/api/v1/opportunities/${oppId}/dmu`)
      .set(bearer(exec.token))
      .send({ contactId: cr.body.data.id, dmuRole: 'INFLUENCER_EXT', stand: 'UNKNOWN' });
    const newDmuId = dr.body.data.id;

    const other = await createActiveUser(admin.token, {
      email: `dmu.block.${++seq}@test.local`,
      roles: ['SALES_EXEC'],
    });
    const res = await api()
      .delete(`/api/v1/opportunities/${oppId}/dmu/${newDmuId}`)
      .set(bearer(other.token));
    expect(res.status).toBe(403);
  });
});
