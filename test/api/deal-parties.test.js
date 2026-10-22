'use strict';

/**
 * Partners on deals, competitors, partner commercial (V022).
 * Fixture: exec owns the deal; other = unrelated exec; pm = partner manager and relationship
 * owner of the partner; head = ALL scope.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, other, pm, head;
const ids = /** @type {Record<string, number>} */ ({});

const url = (path) => `/api/v1/opportunities/${ids.opp}${path}`;

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'dp.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  other = await createActiveUser(admin.token, {
    email: 'dp.other@test.local',
    roles: ['SALES_EXEC'],
  });
  pm = await createActiveUser(admin.token, { email: 'dp.pm@test.local', roles: ['PARTNER_MGR'] });
  head = await createActiveUser(admin.token, {
    email: 'dp.head@test.local',
    roles: ['SALES_HEAD'],
  });

  const c = await dba();
  const ins = async (sql, args) => /** @type {any} */ ((await c.query(sql, args))[0]).insertId;
  ids.acc = await ins(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('DP-ACC-1', 'DP Corp', ?)`,
    [exec.id],
  );
  ids.opp = await ins(
    `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
       weighted_value, expected_close_date, owner_user_id, partner_tbm, no_competition)
     VALUES ('DP-OPP-1', 'DP Deal', ?, 'DIRECT', 'QUALIFIED', 1000000, 200000, '2099-01-01', ?, 1, 1)`,
    [ids.acc, exec.id],
  );
  const partner = (no) =>
    ins(
      `INSERT INTO partner (partner_no, legal_name, short_name, country, relationship_owner_user_id)
       VALUES (?, ?, ?, 'India', ?)`,
      [no, `${no} Pvt Ltd`, no, pm.id],
    );
  ids.p1 = await partner('DP-PTR-1');
  ids.p2 = await partner('DP-PTR-2');
  ids.p1Contact = await ins(`INSERT INTO contact (partner_id, name) VALUES (?, 'Ravi P1')`, [
    ids.p1,
  ]);
  ids.p2Contact = await ins(`INSERT INTO contact (partner_id, name) VALUES (?, 'Sana P2')`, [
    ids.p2,
  ]);
  ids.comp1 = await ins(`INSERT INTO competitor (name) VALUES ('DP Rival One')`, []);
  ids.comp2 = await ins(`INSERT INTO competitor (name, is_active) VALUES ('DP Rival Gone', 0)`, []);
});

afterAll(async () => {
  // later suites count the partners an ALL-scope user sees
  const c = await dba();
  await c.query('UPDATE partner SET is_active = 0 WHERE id IN (?, ?)', [ids.p1, ids.p2]);
  await closeAll();
});

const flags = async () => {
  const c = await dba();
  const [[r]] = await c.query(
    'SELECT partner_tbm AS tbm, no_competition AS nc FROM opportunity WHERE id = ?',
    [ids.opp],
  );
  return r;
};

describe('partners on a deal', () => {
  test('owner maps a primary partner → 201; TBM flag cleared', async () => {
    const res = await api().post(url('/partners')).set(bearer(exec.token)).send({
      partnerId: ids.p1,
      partnerRole: 'SOURCED',
      partnerContactId: ids.p1Contact,
      engagementLevel: 'HIGH',
      isPrimary: true,
    });
    expect(res.status).toBe(201);
    ids.row1 = res.body.data.id;
    expect((await flags()).tbm).toBe(0);
  });

  test('same partner + role twice → 409', async () => {
    const res = await api()
      .post(url('/partners'))
      .set(bearer(exec.token))
      .send({ partnerId: ids.p1, partnerRole: 'SOURCED' });
    expect(res.status).toBe(409);
  });

  test('a second primary → 422 on isPrimary', async () => {
    const res = await api()
      .post(url('/partners'))
      .set(bearer(exec.token))
      .send({ partnerId: ids.p2, partnerRole: 'FULFILMENT', isPrimary: true });
    expect(res.status).toBe(422);
    expect(res.body.error.details[0].field).toBe('isPrimary');
  });

  test('a contact of another partner → 422', async () => {
    const res = await api()
      .post(url('/partners'))
      .set(bearer(exec.token))
      .send({ partnerId: ids.p2, partnerRole: 'FULFILMENT', partnerContactId: ids.p1Contact });
    expect(res.status).toBe(422);
    expect(res.body.error.details[0].field).toBe('partnerContactId');
  });

  test('second partner, then update its role and contact', async () => {
    const add = await api()
      .post(url('/partners'))
      .set(bearer(exec.token))
      .send({ partnerId: ids.p2, partnerRole: 'FULFILMENT' });
    expect(add.status).toBe(201);
    ids.row2 = add.body.data.id;

    const upd = await api()
      .patch(url(`/partners/${ids.row2}`))
      .set(bearer(exec.token))
      .send({ partnerRole: 'SERVICE', partnerContactId: ids.p2Contact, engagementLevel: 'LOW' });
    expect(upd.status).toBe(200);

    const ws = await api().get(`/api/v1/opportunities/${ids.opp}`).set(bearer(exec.token));
    const row = ws.body.data.partners.find((p) => p.id === ids.row2);
    expect(row).toMatchObject({
      partnerRole: 'SERVICE',
      partnerContactId: ids.p2Contact,
      partnerContactName: 'Sana P2',
    });
  });

  test('an unrelated exec cannot edit → 403', async () => {
    const res = await api()
      .post(url('/partners'))
      .set(bearer(other.token))
      .send({ partnerId: ids.p2, partnerRole: 'INFLUENCED' });
    expect(res.status).toBe(403);
  });

  test('ALL-scope head may edit; unknown row → 404', async () => {
    const res = await api()
      .patch(url('/partners/999999'))
      .set(bearer(head.token))
      .send({ partnerRole: 'SERVICE' });
    expect(res.status).toBe(404);
  });
});

describe('partner commercial', () => {
  const body = (over = {}) => ({
    partnerId: ids.p1,
    partnerRole: 'SOURCED',
    dealSizeBasis: 'Full deal value',
    priceToPartner: 800000,
    partnerMarginPct: 20,
    paymentTerms: '30 days after customer payment',
    ...over,
  });

  test('owner records v1, partner manager records v2 (BR-OP-13)', async () => {
    const v1 = await api().post(url('/partner-commercials')).set(bearer(exec.token)).send(body());
    expect(v1.status).toBe(201);
    expect(v1.body.data.versionNo).toBe(1);

    const v2 = await api()
      .post(url('/partner-commercials'))
      .set(bearer(pm.token))
      .send(body({ priceToPartner: 750000 }));
    expect(v2.status).toBe(201);
    expect(v2.body.data.versionNo).toBe(2);

    const c = await dba();
    const [rows] = await c.query(
      'SELECT version_no AS v, price_to_partner AS p, account_id AS a FROM partner_commercial WHERE opportunity_id = ? ORDER BY version_no',
      [ids.opp],
    );
    expect(rows.map((r) => [r.v, Number(r.p), r.a])).toEqual([
      [1, 800000, ids.acc],
      [2, 750000, ids.acc],
    ]);
  });

  test('partner not mapped with that role → 422', async () => {
    const res = await api()
      .post(url('/partner-commercials'))
      .set(bearer(exec.token))
      .send(body({ partnerRole: 'INFLUENCED' }));
    expect(res.status).toBe(422);
  });

  test('price must be above zero → 422', async () => {
    const res = await api()
      .post(url('/partner-commercials'))
      .set(bearer(exec.token))
      .send(body({ priceToPartner: 0 }));
    expect(res.status).toBe(422);
  });

  test('workspace lists versions with partnerId', async () => {
    const ws = await api().get(`/api/v1/opportunities/${ids.opp}`).set(bearer(exec.token));
    expect(ws.status).toBe(200);
    expect(ws.body.data.partnerCommercials[0]).toMatchObject({ partnerId: ids.p1, versionNo: 2 });
  });

  test('a partner with commercials cannot be removed → 409', async () => {
    const res = await api()
      .delete(url(`/partners/${ids.row1}`))
      .set(bearer(exec.token));
    expect(res.status).toBe(409);
  });

  test('a partner without commercials can be removed → 204', async () => {
    const res = await api()
      .delete(url(`/partners/${ids.row2}`))
      .set(bearer(exec.token));
    expect(res.status).toBe(204);
  });
});

describe('competitors', () => {
  test('add → 201 and clears "no competition"', async () => {
    const res = await api()
      .post(url('/competitors'))
      .set(bearer(exec.token))
      .send({ competitorId: ids.comp1, theirPrice: 900000, theirStrength: 'Cheaper' });
    expect(res.status).toBe(201);
    ids.cRow = res.body.data.id;
    expect((await flags()).nc).toBe(0);
  });

  test('duplicate → 409; inactive competitor → 422', async () => {
    const dup = await api()
      .post(url('/competitors'))
      .set(bearer(exec.token))
      .send({ competitorId: ids.comp1 });
    expect(dup.status).toBe(409);
    const gone = await api()
      .post(url('/competitors'))
      .set(bearer(exec.token))
      .send({ competitorId: ids.comp2 });
    expect(gone.status).toBe(422);
  });

  test('update, workspace shows competitorId, then remove', async () => {
    const upd = await api()
      .patch(url(`/competitors/${ids.cRow}`))
      .set(bearer(exec.token))
      .send({ theirPrice: 850000, ourDifferentiator: 'Local support' });
    expect(upd.status).toBe(200);

    const ws = await api().get(`/api/v1/opportunities/${ids.opp}`).set(bearer(exec.token));
    expect(ws.body.data.competitors[0]).toMatchObject({
      competitorId: ids.comp1,
      ourDifferentiator: 'Local support',
    });

    const del = await api()
      .delete(url(`/competitors/${ids.cRow}`))
      .set(bearer(exec.token));
    expect(del.status).toBe(204);
  });

  test('closed deal cannot be edited → 422', async () => {
    const c = await dba();
    await c.query(`UPDATE opportunity SET stage_code = 'LOST' WHERE id = ?`, [ids.opp]);
    const res = await api()
      .post(url('/competitors'))
      .set(bearer(exec.token))
      .send({ competitorId: ids.comp1 });
    expect(res.status).toBe(422);
    await c.query(`UPDATE opportunity SET stage_code = 'QUALIFIED' WHERE id = ?`, [ids.opp]);
  });
});
