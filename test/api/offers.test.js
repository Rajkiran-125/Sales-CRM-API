'use strict';

/**
 * Offers write side (V018): create, submit, approve, send, respond, revise.
 * Fixture: exec owns the deal; head has ALL scope + offer.approve; presales has no offer.create.
 * Approval thresholds (settings defaults): discount > 15% or value > 10,000,000.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, head, presales;
let oppId, accountId, industryId;

const FUTURE = new Date(Date.now() + 330 * 60000 + 60 * 24 * 3600000).toISOString().slice(0, 10);

let seq = 0;

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'off.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  head = await createActiveUser(admin.token, {
    email: 'off.head@test.local',
    roles: ['SALES_HEAD'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'off.presales@test.local',
    roles: ['PRESALES'],
  });

  const c = await dba();
  industryId = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI' LIMIT 1`))[0][0].id;

  accountId = (
    await c.query(
      `INSERT INTO account (account_no, name, industry_id, owner_user_id) VALUES (?,?,?,?)`,
      [`OFF-ACC-${++seq}`, 'Offer Test Corp', industryId, exec.id],
    )
  )[0].insertId;

  oppId = (
    await c.query(
      `INSERT INTO opportunity
         (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
          expected_close_date, owner_user_id)
       VALUES (?, 'Offer Test Deal', ?, 'DIRECT', 'PROPOSAL', 5000000, 2500000, '2099-01-01', ?)`,
      [`OFF-OPP-${++seq}`, accountId, exec.id],
    )
  )[0].insertId;
});

afterAll(closeAll);

// ---------------------------------------------------------------------------
describe('POST /offers (create)', () => {
  test('exec creates an offer below thresholds → 201, approvalRequired false', async () => {
    const res = await api().post('/api/v1/offers').set(bearer(exec.token)).send({
      opportunityId: oppId,
      offerValue: '4000000',
      discountPct: 10,
      paymentTerms: 'Net 30',
      validTill: FUTURE,
    });
    expect(res.status).toBe(201);
    expect(res.body.data.approvalRequired).toBe(0);
    expect(res.body.data.offerNo).toMatch(/\/v1$/);
  });

  test('exec creates an offer with discount > 15% → 201, approvalRequired true', async () => {
    const res = await api().post('/api/v1/offers').set(bearer(exec.token)).send({
      opportunityId: oppId,
      offerValue: '3000000',
      discountPct: 20,
      validTill: FUTURE,
    });
    expect(res.status).toBe(201);
    expect(res.body.data.approvalRequired).toBe(1);
  });

  test('exec creates an offer above value limit → 201, approvalRequired true', async () => {
    const res = await api().post('/api/v1/offers').set(bearer(exec.token)).send({
      opportunityId: oppId,
      offerValue: '12000000',
      validTill: FUTURE,
    });
    expect(res.status).toBe(201);
    expect(res.body.data.approvalRequired).toBe(1);
  });

  test('validTill in the past → 422', async () => {
    const res = await api().post('/api/v1/offers').set(bearer(exec.token)).send({
      opportunityId: oppId,
      offerValue: '2000000',
      validTill: '2020-01-01',
    });
    expect(res.status).toBe(422);
  });

  test('presales (no offer.create) → 403', async () => {
    const res = await api().post('/api/v1/offers').set(bearer(presales.token)).send({
      opportunityId: oppId,
      offerValue: '2000000',
      validTill: FUTURE,
    });
    expect(res.status).toBe(403);
  });

  test('unauthenticated → 401', async () => {
    const res = await api()
      .post('/api/v1/offers')
      .send({ opportunityId: oppId, offerValue: '2000000', validTill: FUTURE });
    expect(res.status).toBe(401);
  });
});

// ---------------------------------------------------------------------------
describe('POST /offers/:id/submit', () => {
  let noApprovalOfferId, approvalOfferId;

  beforeAll(async () => {
    // create below threshold (no approval needed)
    const r1 = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '1000000', discountPct: 5, validTill: FUTURE });
    noApprovalOfferId = r1.body.data.id;

    // create above threshold (approval needed)
    const r2 = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '1000000', discountPct: 18, validTill: FUTURE });
    approvalOfferId = r2.body.data.id;
  });

  test('submit offer not needing approval → 200, status APPROVED', async () => {
    const res = await api()
      .post(`/api/v1/offers/${noApprovalOfferId}/submit`)
      .set(bearer(exec.token))
      .send({});
    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('APPROVED');
  });

  test('submit offer needing approval → 200, status PENDING_APPROVAL', async () => {
    const res = await api()
      .post(`/api/v1/offers/${approvalOfferId}/submit`)
      .set(bearer(exec.token))
      .send({});
    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('PENDING_APPROVAL');
  });

  test('submit an already-submitted offer → 422', async () => {
    const res = await api()
      .post(`/api/v1/offers/${noApprovalOfferId}/submit`)
      .set(bearer(exec.token))
      .send({});
    expect(res.status).toBe(422);
  });

  test('non-existent offer → 404', async () => {
    const res = await api().post('/api/v1/offers/99999999/submit').set(bearer(exec.token)).send({});
    expect(res.status).toBe(404);
  });
});

// ---------------------------------------------------------------------------
describe('POST /offers/:id/approve', () => {
  let pendingId, pendingIdForReject;

  beforeAll(async () => {
    const r1 = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '1000000', discountPct: 25, validTill: FUTURE });
    pendingId = r1.body.data.id;
    await api().post(`/api/v1/offers/${pendingId}/submit`).set(bearer(exec.token)).send({});

    const r2 = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '1000000', discountPct: 25, validTill: FUTURE });
    pendingIdForReject = r2.body.data.id;
    await api()
      .post(`/api/v1/offers/${pendingIdForReject}/submit`)
      .set(bearer(exec.token))
      .send({});
  });

  test('head approves pending offer → 200, status APPROVED', async () => {
    const res = await api()
      .post(`/api/v1/offers/${pendingId}/approve`)
      .set(bearer(head.token))
      .send({ approved: true });
    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('APPROVED');
  });

  test('head rejects pending offer → 200, status REJECTED', async () => {
    const res = await api()
      .post(`/api/v1/offers/${pendingIdForReject}/approve`)
      .set(bearer(head.token))
      .send({ approved: false, approvalRemark: 'Discount too high for this client tier.' });
    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('REJECTED');
  });

  test('reject without remark → 422', async () => {
    const r = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '1000000', discountPct: 25, validTill: FUTURE });
    const id = r.body.data.id;
    await api().post(`/api/v1/offers/${id}/submit`).set(bearer(exec.token)).send({});

    const res = await api()
      .post(`/api/v1/offers/${id}/approve`)
      .set(bearer(head.token))
      .send({ approved: false });
    expect(res.status).toBe(422);
  });

  test('exec (no offer.approve) → 403', async () => {
    const r = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '1000000', discountPct: 25, validTill: FUTURE });
    const id = r.body.data.id;
    await api().post(`/api/v1/offers/${id}/submit`).set(bearer(exec.token)).send({});

    const res = await api()
      .post(`/api/v1/offers/${id}/approve`)
      .set(bearer(exec.token))
      .send({ approved: true });
    expect(res.status).toBe(403);
  });

  test('approve a non-pending offer → 422', async () => {
    // pendingId is now APPROVED, try again
    const res = await api()
      .post(`/api/v1/offers/${pendingId}/approve`)
      .set(bearer(head.token))
      .send({ approved: true });
    expect(res.status).toBe(422);
  });
});

// ---------------------------------------------------------------------------
describe('POST /offers/:id/send and respond', () => {
  let approvedId, sentId;

  beforeAll(async () => {
    // create + submit (no approval needed) → APPROVED
    const r1 = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '900000', discountPct: 5, validTill: FUTURE });
    approvedId = r1.body.data.id;
    await api().post(`/api/v1/offers/${approvedId}/submit`).set(bearer(exec.token)).send({});

    // separate offer for respond tests
    const r2 = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '800000', discountPct: 5, validTill: FUTURE });
    sentId = r2.body.data.id;
    await api().post(`/api/v1/offers/${sentId}/submit`).set(bearer(exec.token)).send({});
    await api()
      .post(`/api/v1/offers/${sentId}/send`)
      .set(bearer(exec.token))
      .send({ sentTo: 'cto@customer.test' });
  });

  test('exec sends approved offer → 200, status SENT', async () => {
    const res = await api()
      .post(`/api/v1/offers/${approvedId}/send`)
      .set(bearer(exec.token))
      .send({ sentTo: 'cto@customer.test' });
    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('SENT');
  });

  test('send a non-approved offer → 422', async () => {
    // approvedId is now SENT
    const res = await api()
      .post(`/api/v1/offers/${approvedId}/send`)
      .set(bearer(exec.token))
      .send({});
    expect(res.status).toBe(422);
  });

  test('exec records customer acceptance → 200, status ACCEPTED', async () => {
    const res = await api()
      .post(`/api/v1/offers/${sentId}/respond`)
      .set(bearer(exec.token))
      .send({ accepted: true, customerResponse: 'Confirmed PO will follow.' });
    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('ACCEPTED');
  });

  test('respond on a non-sent offer → 422', async () => {
    // sentId is now ACCEPTED
    const res = await api()
      .post(`/api/v1/offers/${sentId}/respond`)
      .set(bearer(exec.token))
      .send({ accepted: false });
    expect(res.status).toBe(422);
  });
});

// ---------------------------------------------------------------------------
describe('POST /offers/:id/revise', () => {
  let sentIdForRevise;

  beforeAll(async () => {
    const r = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '750000', discountPct: 5, validTill: FUTURE });
    sentIdForRevise = r.body.data.id;
    await api().post(`/api/v1/offers/${sentIdForRevise}/submit`).set(bearer(exec.token)).send({});
    await api().post(`/api/v1/offers/${sentIdForRevise}/send`).set(bearer(exec.token)).send({});
  });

  test('exec revises sent offer → 201, new DRAFT, old SUPERSEDED', async () => {
    const res = await api()
      .post(`/api/v1/offers/${sentIdForRevise}/revise`)
      .set(bearer(exec.token))
      .send({});
    expect(res.status).toBe(201);
    expect(res.body.data.offerNo).toMatch(/\/v\d+$/);

    const c = await dba();
    const [[old]] = await c.query(`SELECT status FROM offer WHERE id = ?`, [sentIdForRevise]);
    expect(old.status).toBe('SUPERSEDED');
  });

  test('revise a SUPERSEDED offer → 422', async () => {
    const res = await api()
      .post(`/api/v1/offers/${sentIdForRevise}/revise`)
      .set(bearer(exec.token))
      .send({});
    expect(res.status).toBe(422);
  });
});

describe('PATCH /offers/:id (V029)', () => {
  let draftId;

  beforeAll(async () => {
    const r = await api()
      .post('/api/v1/offers')
      .set(bearer(exec.token))
      .send({ opportunityId: oppId, offerValue: '900000', discountPct: 5, validTill: FUTURE });
    draftId = r.body.data.id;
  });

  test('exec edits a draft; a discount above 15% now needs approval; audited', async () => {
    const res = await api().patch(`/api/v1/offers/${draftId}`).set(bearer(exec.token)).send({
      offerValue: '850000',
      listValue: '1000000',
      discountPct: 15.5,
      valueAdds: 'Two years AMC',
      paymentTerms: 'Net 45',
      validTill: FUTURE,
    });
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({ id: draftId, approvalRequired: 1 });

    const c = await dba();
    const [[row]] = await c.query(
      `SELECT offer_value AS v, payment_terms AS t, approval_required AS a FROM offer WHERE id = ?`,
      [draftId],
    );
    expect(row).toEqual({ v: '850000.00', t: 'Net 45', a: 1 });
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log WHERE entity_type = 'offer' AND entity_id = ? AND action = 'OFFER_UPDATE'`,
      [draftId],
    );
    expect(log.n).toBe(1);
  });

  test('a submitted offer cannot be edited → 422; presales → 403', async () => {
    await api().post(`/api/v1/offers/${draftId}/submit`).set(bearer(exec.token)).send({});
    const body = { offerValue: '1', validTill: FUTURE };
    expect(
      (await api().patch(`/api/v1/offers/${draftId}`).set(bearer(exec.token)).send(body)).status,
    ).toBe(422);
    expect(
      (await api().patch(`/api/v1/offers/${draftId}`).set(bearer(presales.token)).send(body))
        .status,
    ).toBe(403);
  });
});
