'use strict';

/**
 * Stage gates (16.3, V026): GET /gate, one step forward with the gate met, overrides with a
 * reason, WON only from CONTRACT_SIGNED, POC save, and PATCH changing only the sent fields.
 * Fixture: exec owns the deals; head has stage_override; contacts at the account.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, head;
const ids = /** @type {Record<string, number>} */ ({});
let seq = 0;

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'gate.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  head = await createActiveUser(admin.token, {
    email: 'gate.head@test.local',
    roles: ['SALES_HEAD'],
  });
  const c = await dba();
  const one = async (sql) => (await c.query(sql))[0][0].id;
  const ins = async (sql, args) => /** @type {any} */ ((await c.query(sql, args))[0]).insertId;
  ids.solution = await one('SELECT id FROM solution WHERE is_active = 1 ORDER BY id LIMIT 1');
  ids.product = await one('SELECT id FROM product WHERE is_active = 1 ORDER BY id LIMIT 1');
  ids.procurement = await one(
    'SELECT id FROM procurement_type WHERE is_active = 1 ORDER BY id LIMIT 1',
  );
  ids.acc = await ins(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('GATE-ACC-1', 'Gate Corp', ?)`,
    [exec.id],
  );
  ids.otherAcc = await ins(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('GATE-ACC-2', 'Other Corp', ?)`,
    [exec.id],
  );
  for (const n of ['tech', 'comm', 'infl'])
    ids[n] = await ins(`INSERT INTO contact (account_id, name) VALUES (?, ?)`, [
      ids.acc,
      `Gate ${n}`,
    ]);
  ids.stranger = await ins(`INSERT INTO contact (account_id, name) VALUES (?, 'Stranger')`, [
    ids.otherAcc,
  ]);
});

afterAll(closeAll);

/** A deal owned by exec in the given stage; returns its id. */
async function deal(stage = 'QUALIFIED') {
  const c = await dba();
  const [res] = await c.query(
    `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
       weighted_value, expected_close_date, owner_user_id)
     VALUES (?, 'Gate Deal', ?, 'DIRECT', ?, 1000000, 200000, '2099-01-01', ?)`,
    [`GATE-OPP-${++seq}`, ids.acc, stage, exec.id],
  );
  return /** @type {any} */ (res).insertId;
}

const rowVersion = async (id) => {
  const c = await dba();
  return Number(
    (await c.query('SELECT row_version AS v FROM opportunity WHERE id = ?', [id]))[0][0].v,
  );
};

const move = async (token, id, body) =>
  api()
    .post(`/api/v1/opportunities/${id}/move-stage`)
    .set(bearer(token))
    .send({ rowVersion: await rowVersion(id), ...body });

/** Everything the QUALIFIED gate asks for (BR-LD-05 facts + validation). */
async function meetQualifiedGate(id) {
  const c = await dba();
  await c.query(
    `UPDATE opportunity SET validation_status = 'VALID', problem_statement = 'Slow branch network',
       solution_id = ?, commercial_window_value = 900000, procurement_type_id = ? WHERE id = ?`,
    [ids.solution, ids.procurement, id],
  );
  await c.query(
    'INSERT INTO opportunity_product (opportunity_id, product_id, is_primary) VALUES (?, ?, 1)',
    [id, ids.product],
  );
  for (const [k, role] of [
    ['tech', 'TECH_BUYER'],
    ['comm', 'COMM_BUYER'],
  ])
    await c.query(
      `INSERT INTO opportunity_dmu (opportunity_id, contact_id, dmu_role, stand) VALUES (?, ?, ?, 'UNKNOWN')`,
      [id, ids[k], role],
    );
}

describe('PATCH changes only the sent fields (D-42)', () => {
  test('a title-only edit keeps the problem statement, no-competition and products', async () => {
    const id = await deal();
    await meetQualifiedGate(id);
    const c = await dba();
    await c.query('UPDATE opportunity SET no_competition = 1, partner_tbm = 1 WHERE id = ?', [id]);
    const res = await api()
      .patch(`/api/v1/opportunities/${id}`)
      .set(bearer(exec.token))
      .send({ rowVersion: await rowVersion(id), title: 'Renamed deal' });
    expect(res.status).toBe(200);
    const [[o]] = await c.query(
      `SELECT title, problem_statement AS p, solution_id AS s, no_competition AS nc, partner_tbm AS tbm,
              commercial_window_value AS cw, procurement_type_id AS pt,
              (SELECT COUNT(*) FROM opportunity_product WHERE opportunity_id = o.id) AS products
         FROM opportunity o WHERE id = ?`,
      [id],
    );
    expect(o).toMatchObject({
      title: 'Renamed deal',
      p: 'Slow branch network',
      s: ids.solution,
      nc: 1,
      tbm: 1,
      pt: ids.procurement,
      products: 1,
    });
    expect(Number(o.cw)).toBe(900000);
  });

  test('a sent null clears that field', async () => {
    const id = await deal();
    await meetQualifiedGate(id);
    const res = await api()
      .patch(`/api/v1/opportunities/${id}`)
      .set(bearer(exec.token))
      .send({ rowVersion: await rowVersion(id), title: 'Gate Deal', problemStatement: null });
    expect(res.status).toBe(200);
    const c = await dba();
    const [[o]] = await c.query('SELECT problem_statement AS p FROM opportunity WHERE id = ?', [
      id,
    ]);
    expect(o.p).toBeNull();
  });
});

describe('gate and one-step moves (BR-OP-01/02/03)', () => {
  test('GET /gate lists what is missing to leave QUALIFIED', async () => {
    const id = await deal();
    const res = await api().get(`/api/v1/opportunities/${id}/gate`).set(bearer(exec.token));
    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      stageCode: 'QUALIFIED',
      nextStage: 'TECH_ENGAGEMENT',
      allowed: false,
    });
    expect(res.body.data.missing).toEqual([
      'The deal is validated (VALID)',
      'Problem statement',
      'Product and solution',
      'Commercial window value',
      'DMU: a technical buyer',
      'DMU: a commercial buyer',
      'Procurement process',
    ]);
  });

  test('with the gate met the owner moves one stage forward; skipping a stage is refused', async () => {
    const id = await deal();
    await meetQualifiedGate(id);
    const gate = await api().get(`/api/v1/opportunities/${id}/gate`).set(bearer(exec.token));
    expect(gate.body.data).toMatchObject({ allowed: true, missing: [] });

    const ok = await move(exec.token, id, { toStage: 'TECH_ENGAGEMENT' });
    expect(ok.status).toBe(200);
    expect(ok.body.data.overridden).toBe(false);

    const skip = await move(exec.token, id, { toStage: 'PROPOSAL' });
    expect(skip.status).toBe(403);
  });

  test('POC needs the commercial window accepted; only stage_override can override, with a reason', async () => {
    const id = await deal('TECH_ENGAGEMENT');
    const c = await dba();
    await c.query(
      `UPDATE opportunity SET presales_owner_user_id = ?, technical_requirement = 'SD-WAN', no_competition = 1
        WHERE id = ?`,
      [exec.id, id],
    );
    const blocked = await move(exec.token, id, { toStage: 'POC' });
    expect(blocked.status).toBe(422);
    expect(blocked.body.error.details.map((d) => d.message)).toEqual([
      'Commercial window accepted by the customer',
    ]);

    expect(
      (await move(exec.token, id, { toStage: 'POC', override: true, reason: 'x' })).status,
    ).toBe(403);
    expect((await move(head.token, id, { toStage: 'POC', override: true })).status).toBe(422);

    const forced = await move(head.token, id, {
      toStage: 'POC',
      override: true,
      reason: 'Customer agreed on the call',
    });
    expect(forced.status).toBe(200);
    expect(forced.body.data.overridden).toBe(true);
    const [[h]] = await c.query(
      `SELECT reason, was_override AS o FROM stage_history WHERE entity_type = 'OPP' AND entity_id = ? ORDER BY id DESC LIMIT 1`,
      [id],
    );
    expect(h).toEqual({ reason: 'Customer agreed on the call', o: 1 });
  });

  test('WON only from CONTRACT_SIGNED', async () => {
    const id = await deal('NEGOTIATION');
    const res = await api()
      .post(`/api/v1/opportunities/${id}/close`)
      .set(bearer(exec.token))
      .send({
        rowVersion: await rowVersion(id),
        outcome: 'WON',
        finalValue: 1000000,
        poNumber: 'PO-1',
        poValue: 1000000,
        poDate: '2026-01-01',
      });
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('GATE_NOT_MET');
  });

  test('PROPOSAL gate: an offer response with no remark counts (V041)', async () => {
    const id = await deal('PROPOSAL');
    const c = await dba();
    const [ins] = await c.query(
      `INSERT INTO offer (opportunity_id, version_no, offer_no, offer_value, valid_till, status, sent_at)
       VALUES (?, 1, ?, 500000, '2099-01-01', 'SENT', UTC_TIMESTAMP(3))`,
      [id, `GATE-OFFER-${id}`],
    );
    const res = await api()
      .post(`/api/v1/offers/${/** @type {any} */ (ins).insertId}/respond`)
      .set(bearer(exec.token))
      .send({ accepted: true });
    expect(res.status).toBe(200);
    const gate = await api().get(`/api/v1/opportunities/${id}/gate`).set(bearer(exec.token));
    expect(gate.body.data.missing).toEqual([]);
  });
});

describe('PUT /opportunities/:id/poc (12.5.4)', () => {
  const put = (id, body) =>
    api().put(`/api/v1/opportunities/${id}/poc`).set(bearer(exec.token)).send(body);

  test('skipping needs a reason; a skipped POC meets the POC gate item', async () => {
    const id = await deal('POC');
    expect((await put(id, { skipped: true })).status).toBe(422);
    expect(
      (await put(id, { skipped: true, skipReason: 'Reference customer, no POC needed' })).status,
    ).toBe(200);
    const gate = await api().get(`/api/v1/opportunities/${id}/gate`).set(bearer(exec.token));
    expect(gate.body.data.missing).toEqual(['An offer sent to the customer']);
  });

  test('rules: result needs COMPLETED, dates in order, customer lead from the account', async () => {
    const id = await deal('POC');
    expect((await put(id, { status: 'IN_PROGRESS', result: 'SUCCESS' })).status).toBe(422);
    expect((await put(id, { startDate: '2026-10-10', endDate: '2026-10-01' })).status).toBe(422);
    const stranger = await put(id, { customerLeadContactId: ids.stranger });
    expect(stranger.status).toBe(422);
    expect(stranger.body.error.details[0].field).toBe('customerLeadContactId');
  });

  test('a full POC is saved once per deal and shown in the workspace', async () => {
    const id = await deal('POC');
    const body = {
      status: 'COMPLETED',
      startDate: '2026-09-01',
      endDate: '2026-09-20',
      successCriteria: 'Failover under 3 s',
      exitCriteria: 'Two weeks of stable traffic',
      customerLeadContactId: ids.tech,
      cnergeeLeadUserId: exec.id,
      result: 'SUCCESS',
      customerValidated: true,
    };
    expect((await put(id, body)).status).toBe(200);
    expect((await put(id, { ...body, notes: 'Readout done' })).status).toBe(200);
    const c = await dba();
    const [[n]] = await c.query(
      'SELECT COUNT(*) AS n FROM opportunity_poc WHERE opportunity_id = ?',
      [id],
    );
    expect(n.n).toBe(1);
    const ws = await api().get(`/api/v1/opportunities/${id}`).set(bearer(exec.token));
    expect(ws.body.data.poc).toMatchObject({
      status: 'COMPLETED',
      result: 'SUCCESS',
      notes: 'Readout done',
    });
    const edit = await api().get(`/api/v1/opportunities/${id}/poc`).set(bearer(exec.token));
    expect(edit.body.data).toMatchObject({
      customerLeadContactId: ids.tech,
      cnergeeLeadUserId: exec.id,
    });
  });
});
