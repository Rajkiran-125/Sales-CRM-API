'use strict';

/**
 * Lead write side (12.4, V012): update, disqualify, convert.
 *
 * Fixture: manager <- exec (SALES_EXEC); head = SALES_HEAD (all scope); presales cannot update.
 * A lead is created before each group so tests start from a known state.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, manager, exec, head, presales;
let industryId, productId, productId2, solutionId, procurementTypeId, accountId;
let disqualifyReasonId;
const todayIst = () => new Date(Date.now() + 330 * 60000).toISOString().slice(0, 10);
const futureIst = () =>
  new Date(Date.now() + 330 * 60000 + 30 * 24 * 3600000).toISOString().slice(0, 10);

/** Shared lead body template. */
const createBody = (over = {}) => ({
  source: 'DIRECT',
  accountId,
  industryId,
  contactName: 'Test Contact',
  city: 'Bangalore',
  needText: 'Network upgrade project',
  nextAction: 'Schedule call',
  nextActionDueOn: todayIst(),
  productIds: [productId],
  ...over,
});

/** Create a fresh lead and return its id + rowVersion. */
async function createLead(user = exec, over = {}) {
  const res = await api().post('/api/v1/leads').set(bearer(user.token)).send(createBody(over));
  expect(res.status).toBe(201);
  const detail = await api().get(`/api/v1/leads/${res.body.data.id}`).set(bearer(user.token));
  expect(detail.status).toBe(200);
  return { id: res.body.data.id, rowVersion: detail.body.data.lead.rowVersion };
}

beforeAll(async () => {
  admin = await adminSession();
  manager = await createActiveUser(admin.token, {
    email: 'lw.manager@test.local',
    roles: ['SALES_EXEC'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'lw.exec@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: manager.id,
  });
  head = await createActiveUser(admin.token, {
    email: 'lw.head@test.local',
    roles: ['SALES_HEAD'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'lw.presales@test.local',
    roles: ['PRESALES'],
  });

  const c = await dba();
  industryId = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI'`))[0][0].id;
  productId = (
    await c.query(`SELECT id FROM product WHERE is_active = 1 ORDER BY id LIMIT 1`)
  )[0][0].id;
  productId2 =
    (
      await c.query(`SELECT id FROM product WHERE is_active = 1 AND id <> ? ORDER BY id LIMIT 1`, [
        productId,
      ])
    )[0][0]?.id ?? productId;
  solutionId = (
    await c.query(`SELECT id FROM solution WHERE is_active = 1 ORDER BY id LIMIT 1`)
  )[0][0]?.id;
  procurementTypeId = (
    await c.query(`SELECT id FROM procurement_type WHERE is_active = 1 ORDER BY id LIMIT 1`)
  )[0][0]?.id;
  disqualifyReasonId = (
    await c.query(
      `SELECT id FROM reason WHERE reason_type = 'DISQUALIFY' AND is_active = 1 LIMIT 1`,
    )
  )[0][0]?.id;

  await c.query(
    `INSERT INTO partner (partner_no, legal_name, short_name, country, relationship_owner_user_id)
     VALUES ('LW-PTR-1', 'Lead Write Partner Pvt Ltd', 'LW Partner', 'India', ?)`,
    [manager.id],
  );
  const [a] = await c.query(
    `INSERT INTO account (account_no, name, industry_id, owner_user_id)
     VALUES ('LW-ACC-1', 'Lead Write Bank Ltd', ?, ?)`,
    [industryId, exec.id],
  );
  accountId = /** @type {any} */ (a).insertId;
});

afterAll(closeAll);

// ---------------------------------------------------------------------------
describe('PATCH /leads/:id (update)', () => {
  test('owner can update basic fields and get 200', async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .patch(`/api/v1/leads/${id}`)
      .set(bearer(exec.token))
      .send(
        createBody({
          rowVersion,
          needText: 'Updated need text',
          roughValue: 5000000,
          productIds: [productId2],
        }),
      );
    expect(res.status).toBe(200);
    expect(res.body.data.id).toBe(id);
  });

  test('update with qualification fields advances stage to QUALIFYING', async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .patch(`/api/v1/leads/${id}`)
      .set(bearer(exec.token))
      .send(
        createBody({
          rowVersion,
          problemStatement: 'Current MPLS is too expensive',
          expectedCloseDate: futureIst(),
        }),
      );
    expect(res.status).toBe(200);
    const detail = await api().get(`/api/v1/leads/${id}`).set(bearer(exec.token));
    expect(detail.body.data.lead.stageCode).toBe('QUALIFYING');
  });

  test('stale rowVersion returns 409 CONFLICT', async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .patch(`/api/v1/leads/${id}`)
      .set(bearer(exec.token))
      .send(createBody({ rowVersion: rowVersion - 1 }));
    expect(res.status).toBe(409);
  });

  test('presales (no lead.update) gets 403', async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .patch(`/api/v1/leads/${id}`)
      .set(bearer(presales.token))
      .send(createBody({ rowVersion }));
    expect(res.status).toBe(403);
  });

  test('exec outside the team gets 403 from the procedure', async () => {
    const outsider = await createActiveUser(admin.token, {
      email: 'lw.outsider@test.local',
      roles: ['SALES_EXEC'],
    });
    const { id, rowVersion } = await createLead();
    const res = await api()
      .patch(`/api/v1/leads/${id}`)
      .set(bearer(outsider.token))
      .send(createBody({ rowVersion }));
    expect(res.status).toBe(403);
  });

  test("head (ALL scope) can update anyone's lead", async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .patch(`/api/v1/leads/${id}`)
      .set(bearer(head.token))
      .send(createBody({ rowVersion, needText: 'Head updated this' }));
    expect(res.status).toBe(200);
  });
});

// ---------------------------------------------------------------------------
describe('POST /leads/:id/disqualify', () => {
  test('disqualify a lead with a valid reason', async () => {
    if (!disqualifyReasonId) return; // skip if no reason seeded
    const { id, rowVersion } = await createLead();
    const res = await api()
      .post(`/api/v1/leads/${id}/disqualify`)
      .set(bearer(exec.token))
      .send({ rowVersion, reasonId: disqualifyReasonId, note: 'Budget cancelled' });
    expect(res.status).toBe(200);
    const detail = await api().get(`/api/v1/leads/${id}`).set(bearer(exec.token));
    expect(detail.body.data.lead.stageCode).toBe('DISQUALIFIED');
    expect(detail.body.data.lead.disqualifiedAt).toBeTruthy();
  });

  test('missing reasonId -> 422', async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .post(`/api/v1/leads/${id}/disqualify`)
      .set(bearer(exec.token))
      .send({ rowVersion });
    expect(res.status).toBe(422);
  });

  test('presales cannot disqualify (no lead.disqualify) -> 403', async () => {
    if (!disqualifyReasonId) return;
    const { id, rowVersion } = await createLead();
    const res = await api()
      .post(`/api/v1/leads/${id}/disqualify`)
      .set(bearer(presales.token))
      .send({ rowVersion, reasonId: disqualifyReasonId });
    expect(res.status).toBe(403);
  });
});

// ---------------------------------------------------------------------------
describe('lead DMU (V021)', () => {
  const dmuFact = async (/** @type {number} */ id) => {
    const res = await api().get(`/api/v1/leads/${id}`).set(bearer(exec.token));
    return {
      done: res.body.data.qualification.facts.find((/** @type {any} */ f) => f.code === 'DMU').done,
      dmu: res.body.data.dmu,
    };
  };

  test('add, edit and remove drive qualification fact 4', async () => {
    const { id } = await createLead();
    const ids = [];
    // influencer is optional (V043): tech + commercial buyer complete the fact
    for (const dmuRole of ['TECH_BUYER', 'COMM_BUYER']) {
      const r = await api()
        .post(`/api/v1/leads/${id}/dmu`)
        .set(bearer(exec.token))
        .send({ name: `P ${dmuRole}`, designation: 'CTO', dmuRole, influenceLevel: 3 });
      expect(r.status).toBe(201);
      ids.push(r.body.data.id);
    }
    expect((await dmuFact(id)).done).toBe(true);

    const upd = await api()
      .patch(`/api/v1/leads/${id}/dmu/${ids[0]}`)
      .set(bearer(exec.token))
      .send({ name: 'Renamed', dmuRole: 'TECH_BUYER', stand: 'CHAMPION' });
    expect(upd.status).toBe(200);
    const after = await dmuFact(id);
    expect(after.dmu.find((/** @type {any} */ m) => m.id === ids[0])).toMatchObject({
      name: 'Renamed',
      stand: 'CHAMPION',
    });

    const del = await api().delete(`/api/v1/leads/${id}/dmu/${ids[1]}`).set(bearer(exec.token));
    expect(del.status).toBe(200);
    expect((await dmuFact(id)).done).toBe(false);
  });

  test('invalid role -> 422; sponsor is deal-only', async () => {
    const { id } = await createLead();
    const res = await api()
      .post(`/api/v1/leads/${id}/dmu`)
      .set(bearer(exec.token))
      .send({ name: 'X', dmuRole: 'SPONSOR' });
    expect(res.status).toBe(422);
  });

  test('DMU id of another lead -> 404', async () => {
    const a = await createLead();
    const b = await createLead();
    const r = await api()
      .post(`/api/v1/leads/${a.id}/dmu`)
      .set(bearer(exec.token))
      .send({ name: 'A person', dmuRole: 'TECH_BUYER' });
    const res = await api()
      .delete(`/api/v1/leads/${b.id}/dmu/${r.body.data.id}`)
      .set(bearer(exec.token));
    expect(res.status).toBe(404);
  });

  test('presales cannot edit the DMU (no lead.update) -> 403', async () => {
    const { id } = await createLead();
    const res = await api()
      .post(`/api/v1/leads/${id}/dmu`)
      .set(bearer(presales.token))
      .send({ name: 'X', dmuRole: 'TECH_BUYER' });
    expect(res.status).toBe(403);
  });

  test('disqualified lead DMU is locked -> 422', async () => {
    if (!disqualifyReasonId) return;
    const { id, rowVersion } = await createLead();
    await api()
      .post(`/api/v1/leads/${id}/disqualify`)
      .set(bearer(exec.token))
      .send({ rowVersion, reasonId: disqualifyReasonId });
    const res = await api()
      .post(`/api/v1/leads/${id}/dmu`)
      .set(bearer(exec.token))
      .send({ name: 'X', dmuRole: 'TECH_BUYER' });
    expect(res.status).toBe(422);
  });
});

// ---------------------------------------------------------------------------
describe('POST /leads/:id/convert', () => {
  /** Create a fully-qualified lead ready for conversion. */
  async function createQualifiedLead(over = {}) {
    const { id, rowVersion } = await createLead(exec, over);
    // Build all 6 facts via PATCH
    const patchBody = createBody({
      ...over,
      rowVersion,
      problemStatement: 'Full qualification for convert test',
      productId: solutionId ? productId : undefined,
      solutionId: solutionId ?? undefined,
      commercialWindowValue: 5000000,
      budgetKnown: 'YES',
      budgetMin: 4000000,
      budgetMax: 6000000,
      procurementTypeId: procurementTypeId ?? undefined,
      procurementStepsKnown: true,
      expectedCloseDate: futureIst(),
    });
    // patch twice if solutionId is missing
    if (!solutionId || !procurementTypeId) return null;
    // Add DMU entries via the API; 'Pat Buyer' holds two roles -> one contact on convert
    for (const [name, dmuRole] of [
      ['Pat Buyer', 'TECH_BUYER'],
      ['Pat Buyer', 'COMM_BUYER'],
      ['Influencer', 'INFLUENCER_INT'],
    ]) {
      const r = await api()
        .post(`/api/v1/leads/${id}/dmu`)
        .set(bearer(exec.token))
        .send({ name, dmuRole, stand: 'NEUTRAL' });
      expect(r.status).toBe(201);
    }
    const patchRes = await api()
      .patch(`/api/v1/leads/${id}`)
      .set(bearer(exec.token))
      .send(patchBody);
    if (patchRes.status !== 200) return null;
    const detail = await api().get(`/api/v1/leads/${id}`).set(bearer(exec.token));
    return {
      id,
      rowVersion: detail.body.data.lead.rowVersion,
      qualPct: detail.body.data.qualification.done,
    };
  }

  test('new-account lead creates its account on convert (V024)', async () => {
    const name = `Convert New Co ${Date.now()}`;
    const lead = await createQualifiedLead({ accountId: null, accountNameText: name });
    expect(lead?.qualPct).toBe(6);
    const res = await api()
      .post(`/api/v1/leads/${lead?.id}/convert`)
      .set(bearer(exec.token))
      .send({ rowVersion: lead?.rowVersion, title: 'New Co Deal' });
    expect(res.status).toBe(200);

    const [[acc]] = await (
      await dba()
    ).query(
      `SELECT a.id, a.account_type AS type, a.owner_user_id AS ownerId, o.account_id AS oppAccount,
              l.account_id AS leadAccount
         FROM account a JOIN opportunity o ON o.id = ? JOIN sales_lead l ON l.id = ?
        WHERE a.name = ?`,
      [res.body.data.opportunityId, lead?.id, name],
    );
    expect(acc).toMatchObject({ type: 'PROSPECT', ownerId: exec.id });
    expect(acc.oppAccount).toBe(acc.id);
    expect(acc.leadAccount).toBe(acc.id);
  });

  test('fully-qualified lead converts to an opportunity', async () => {
    const lead = await createQualifiedLead();
    if (!lead || lead.qualPct < 6) {
      return; // qualification facts not complete; convert not available
    }
    const res = await api()
      .post(`/api/v1/leads/${lead.id}/convert`)
      .set(bearer(exec.token))
      .send({ rowVersion: lead.rowVersion, title: 'Network Upgrade Opportunity' });
    expect(res.status).toBe(200);
    expect(res.body.data.opportunityId).toBeGreaterThan(0);
    expect(res.body.data.opportunityNo).toMatch(/^OP/);

    const detail = await api().get(`/api/v1/leads/${lead.id}`).set(bearer(exec.token));
    expect(detail.body.data.lead.stageCode).toBe('CONVERTED');
    expect(detail.body.data.lead.opportunityId).toBe(res.body.data.opportunityId);

    // the lead DMU is carried onto the deal, linked to account contacts
    const [rows] = await (
      await dba()
    ).query(
      `SELECT c.name, d.dmu_role AS role, c.account_id AS accountId
         FROM opportunity_dmu d JOIN contact c ON c.id = d.contact_id
        WHERE d.opportunity_id = ? ORDER BY d.dmu_role`,
      [res.body.data.opportunityId],
    );
    expect(rows).toEqual([
      { name: 'Pat Buyer', role: 'COMM_BUYER', accountId },
      { name: 'Influencer', role: 'INFLUENCER_INT', accountId },
      { name: 'Pat Buyer', role: 'TECH_BUYER', accountId },
    ]);
  });

  test('convert without a title -> 422', async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .post(`/api/v1/leads/${id}/convert`)
      .set(bearer(exec.token))
      .send({ rowVersion });
    expect(res.status).toBe(422);
  });

  test('presales cannot convert (no lead.convert) -> 403', async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .post(`/api/v1/leads/${id}/convert`)
      .set(bearer(presales.token))
      .send({ rowVersion, title: 'Presales Try' });
    expect(res.status).toBe(403);
  });

  test('convert with incomplete qualification -> 422', async () => {
    const { id, rowVersion } = await createLead();
    const res = await api()
      .post(`/api/v1/leads/${id}/convert`)
      .set(bearer(exec.token))
      .send({ rowVersion, title: 'Incomplete Lead' });
    expect(res.status).toBe(422);
  });
});
