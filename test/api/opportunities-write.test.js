'use strict';

/**
 * Opportunity write side (12.5, V013): update, move-stage, validate, close.
 *
 * Fixture: manager <- exec (SALES_EXEC, owner of the test deal); head = SALES_HEAD
 * (validate + stage_override); validator = MANAGEMENT (validate only); presales = PRESALES.
 * A fresh opportunity is inserted before each group so tests start from a clean state.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, head, validator, presales;
let industryId, productId, lossReasonId, dormantReasonId;

const todayIst = () => new Date(Date.now() + 330 * 60000).toISOString().slice(0, 10);
const futureIst = () =>
  new Date(Date.now() + 330 * 60000 + 60 * 24 * 3600000).toISOString().slice(0, 10);

let oppSeq = 0;

/** Insert a fresh open opportunity owned by exec; returns { id, rowVersion }. */
async function createOpp(stage = 'QUALIFIED') {
  const no = `OW-OPP-${++oppSeq}`;
  const c = await dba();
  const [res] = await c.query(
    `INSERT INTO opportunity
       (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
        expected_close_date, owner_user_id, validation_status)
     VALUES (?, 'Write Test Deal', ?, 'DIRECT', ?, 3000000, 1500000, ?, ?, 'PENDING')`,
    [no, ids.accId, stage, futureIst(), exec.id],
  );
  const id = /** @type {any} */ (res).insertId;
  const [[row]] = await c.query(`SELECT row_version FROM opportunity WHERE id = ?`, [id]);
  return { id, rowVersion: Number(row.row_version) };
}

const ids = /** @type {Record<string, number>} */ ({});

beforeAll(async () => {
  admin = await adminSession();
  const manager = await createActiveUser(admin.token, {
    email: 'ow.manager@test.local',
    roles: ['SALES_EXEC'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'ow.exec@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: manager.id,
  });
  head = await createActiveUser(admin.token, {
    email: 'ow.head@test.local',
    roles: ['SALES_HEAD'],
  });
  validator = await createActiveUser(admin.token, {
    email: 'ow.mgmt@test.local',
    roles: ['MANAGEMENT'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'ow.presales@test.local',
    roles: ['PRESALES'],
  });

  const c = await dba();
  industryId = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI'`))[0][0].id;
  productId = (
    await c.query(`SELECT id FROM product WHERE is_active = 1 ORDER BY id LIMIT 1`)
  )[0][0].id;
  lossReasonId = (
    await c.query(`SELECT id FROM reason WHERE reason_type = 'LOSS' AND is_active = 1 LIMIT 1`)
  )[0][0]?.id;
  dormantReasonId = (
    await c.query(`SELECT id FROM reason WHERE reason_type = 'DORMANT' AND is_active = 1 LIMIT 1`)
  )[0][0]?.id;
  ids.accId = (
    await c.query(
      `INSERT INTO account (account_no, name, industry_id, owner_user_id)
       VALUES ('OW-ACC-1', 'Write Test Corp', ?, ?)`,
      [industryId, exec.id],
    )
  )[0].insertId;
});

afterAll(closeAll);

// ---------------------------------------------------------------------------
describe('PATCH /opportunities/:id (update)', () => {
  test('owner can update title and products and get 200', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .patch(`/api/v1/opportunities/${id}`)
      .set(bearer(exec.token))
      .send({
        rowVersion,
        title: 'Updated Deal Title',
        expectedCloseDate: futureIst(),
        productIds: [{ productId, isPrimary: true }],
      });
    expect(res.status).toBe(200);
    expect(res.body.data.id).toBe(id);
  });

  test('head (ALL scope) can update any deal', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .patch(`/api/v1/opportunities/${id}`)
      .set(bearer(head.token))
      .send({ rowVersion, title: 'Head Updated' });
    expect(res.status).toBe(200);
  });

  test('presales can update their own deal', async () => {
    // Insert a deal owned by presales (scope check: v_owner = actor passes)
    const c = await dba();
    const [res] = await c.query(
      `INSERT INTO opportunity
         (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
          expected_close_date, owner_user_id)
       VALUES (?, 'Presales Deal', ?, 'DIRECT', 'QUALIFIED', 1000000, 500000, ?, ?)`,
      [`OW-OPP-${++oppSeq}`, ids.accId, futureIst(), presales.id],
    );
    const id = /** @type {any} */ (res).insertId;
    const [[row]] = await c.query(`SELECT row_version FROM opportunity WHERE id = ?`, [id]);
    const rv = Number(row.row_version);

    const update = await api()
      .patch(`/api/v1/opportunities/${id}`)
      .set(bearer(presales.token))
      .send({ rowVersion: rv, title: 'Presales Updated Own Deal' });
    expect(update.status).toBe(200);
  });

  test('stale rowVersion returns 409', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .patch(`/api/v1/opportunities/${id}`)
      .set(bearer(exec.token))
      .send({ rowVersion: rowVersion - 1, title: 'Stale' });
    expect(res.status).toBe(409);
  });

  test('outsider (not in team, not ALL scope) gets 403', async () => {
    const outsider = await createActiveUser(admin.token, {
      email: 'ow.outsider@test.local',
      roles: ['SALES_EXEC'],
    });
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .patch(`/api/v1/opportunities/${id}`)
      .set(bearer(outsider.token))
      .send({ rowVersion, title: 'Outsider' });
    expect(res.status).toBe(403);
  });

  test('validator (MANAGEMENT, no opportunity.update) gets 403', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .patch(`/api/v1/opportunities/${id}`)
      .set(bearer(validator.token))
      .send({ rowVersion, title: 'Mgmt update' });
    expect(res.status).toBe(403);
  });
});

// ---------------------------------------------------------------------------
describe('POST /opportunities/:id/move-stage', () => {
  test('owner moving forward with the gate unmet gets GATE_NOT_MET with the missing items', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/move-stage`)
      .set(bearer(exec.token))
      .send({ rowVersion, toStage: 'TECH_ENGAGEMENT' });
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('GATE_NOT_MET');
    expect(res.body.error.details.map((d) => d.message)).toContain('Problem statement');
  });

  test('exec (no stage_override) cannot move backward', async () => {
    // Create a deal already in PROPOSAL
    const c = await dba();
    const [res] = await c.query(
      `INSERT INTO opportunity
         (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
          expected_close_date, owner_user_id)
       VALUES (?, 'Backward Test', ?, 'DIRECT', 'PROPOSAL', 1000000, 300000, ?, ?)`,
      [`OW-OPP-${++oppSeq}`, ids.accId, futureIst(), exec.id],
    );
    const oppId = /** @type {any} */ (res).insertId;
    const [[row]] = await c.query(`SELECT row_version FROM opportunity WHERE id = ?`, [oppId]);
    const rv = Number(row.row_version);

    const back = await api()
      .post(`/api/v1/opportunities/${oppId}/move-stage`)
      .set(bearer(exec.token))
      .send({ rowVersion: rv, toStage: 'QUALIFIED' });
    expect(back.status).toBe(403);
  });

  test('head (stage_override) can move backward', async () => {
    const c = await dba();
    const [res] = await c.query(
      `INSERT INTO opportunity
         (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
          expected_close_date, owner_user_id)
       VALUES (?, 'Head Backward', ?, 'DIRECT', 'PROPOSAL', 1000000, 300000, ?, ?)`,
      [`OW-OPP-${++oppSeq}`, ids.accId, futureIst(), exec.id],
    );
    const oppId = /** @type {any} */ (res).insertId;
    const [[row]] = await c.query(`SELECT row_version FROM opportunity WHERE id = ?`, [oppId]);

    const back = await api()
      .post(`/api/v1/opportunities/${oppId}/move-stage`)
      .set(bearer(head.token))
      .send({ rowVersion: Number(row.row_version), toStage: 'QUALIFIED' });
    expect(back.status).toBe(422); // a reason is required
    const withReason = await api()
      .post(`/api/v1/opportunities/${oppId}/move-stage`)
      .set(bearer(head.token))
      .send({
        rowVersion: Number(row.row_version),
        toStage: 'QUALIFIED',
        reason: 'Customer re-scoped',
      });
    expect(withReason.status).toBe(200);
  });

  test('cannot move to a closed stage (WON)', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/move-stage`)
      .set(bearer(exec.token))
      .send({ rowVersion, toStage: 'WON' });
    expect(res.status).toBe(422);
  });

  test('validator (no move_stage) gets 403', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/move-stage`)
      .set(bearer(validator.token))
      .send({ rowVersion, toStage: 'TECH_ENGAGEMENT' });
    expect(res.status).toBe(403);
  });
});

// ---------------------------------------------------------------------------
describe('POST /opportunities/:id/validate', () => {
  test('head can mark VALID', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/validate`)
      .set(bearer(head.token))
      .send({ rowVersion, status: 'VALID', remark: 'Looks good' });
    expect(res.status).toBe(200);
    expect(res.body.data.id).toBe(id);
  });

  test('management can mark NOT_VALID', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/validate`)
      .set(bearer(validator.token))
      .send({ rowVersion, status: 'NOT_VALID', remark: 'Missing budget details' });
    expect(res.status).toBe(200);
  });

  test('exec (no opportunity.validate) gets 403', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/validate`)
      .set(bearer(exec.token))
      .send({ rowVersion, status: 'VALID' });
    expect(res.status).toBe(403);
  });

  test('invalid status value returns 422', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/validate`)
      .set(bearer(head.token))
      .send({ rowVersion, status: 'MAYBE' });
    expect(res.status).toBe(422);
  });
});

// ---------------------------------------------------------------------------
describe('POST /opportunities/:id/close (WON)', () => {
  test('exec can close as WON with PO details', async () => {
    const { id, rowVersion } = await createOpp('CONTRACT_SIGNED');
    const res = await api().post(`/api/v1/opportunities/${id}/close`).set(bearer(exec.token)).send({
      rowVersion,
      outcome: 'WON',
      finalValue: 3000000,
      poNumber: 'PO-2026-001',
      poValue: 3000000,
      poDate: todayIst(),
    });
    expect(res.status).toBe(200);
    expect(res.body.data.id).toBe(id);
  });

  test('missing PO details returns 422', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/close`)
      .set(bearer(exec.token))
      .send({ rowVersion, outcome: 'WON' });
    expect(res.status).toBe(422);
  });

  test('presales (no opportunity.close) gets 403', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/close`)
      .set(bearer(presales.token))
      .send({
        rowVersion,
        outcome: 'WON',
        finalValue: 1000000,
        poNumber: 'PO-X',
        poValue: 1000000,
        poDate: todayIst(),
      });
    expect(res.status).toBe(403);
  });
});

// ---------------------------------------------------------------------------
describe('POST /opportunities/:id/close (LOST)', () => {
  test('exec can close as LOST with a reason', async () => {
    if (!lossReasonId) return;
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/close`)
      .set(bearer(exec.token))
      .send({
        rowVersion,
        outcome: 'LOST',
        lossReasonIds: [lossReasonId],
      });
    expect(res.status).toBe(200);
  });

  test('missing loss reasons returns 422', async () => {
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/close`)
      .set(bearer(exec.token))
      .send({ rowVersion, outcome: 'LOST', lossReasonIds: [] });
    expect(res.status).toBe(422);
  });
});

// ---------------------------------------------------------------------------
describe('POST /opportunities/:id/close (DORMANT)', () => {
  test('exec can mark as DORMANT', async () => {
    if (!dormantReasonId) return;
    const { id, rowVersion } = await createOpp();
    const res = await api().post(`/api/v1/opportunities/${id}/close`).set(bearer(exec.token)).send({
      rowVersion,
      outcome: 'DORMANT',
      dormantReasonId,
      wakeUpDate: futureIst(),
      dormantNote: 'Budget frozen until next FY',
    });
    expect(res.status).toBe(200);
  });

  test('missing wakeUpDate returns 422', async () => {
    if (!dormantReasonId) return;
    const { id, rowVersion } = await createOpp();
    const res = await api()
      .post(`/api/v1/opportunities/${id}/close`)
      .set(bearer(exec.token))
      .send({ rowVersion, outcome: 'DORMANT', dormantReasonId });
    expect(res.status).toBe(422);
  });
});
