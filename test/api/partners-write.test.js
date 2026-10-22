'use strict';

/**
 * Partner Master write (V030): duplicate search with the owner (BR-PT-02), create with the
 * minimum fields (BR-PT-01), per-section save with optimistic lock, completeness (BR-PT-04),
 * signed agreement rule (BR-PT-07), owner rules, export. V042: duplicate confirmation, required
 * address / industry, agreement and GTM documents, customer codes.
 * Fixture: pm and pm2 are unrelated partner managers; head has ALL scope; exec has no partner.create.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, pm, pm2, head, exec;
const ids = /** @type {Record<string, number>} */ ({});
const PDF = Buffer.from('%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n');

/** Upload a PDF of the given type to a partner; answers the document id. */
async function uploadDoc(token, partnerId, documentTypeCode) {
  const res = await api()
    .post('/api/v1/documents')
    .set(bearer(token))
    .field('entityType', 'PARTNER')
    .field('entityId', String(partnerId))
    .field('documentTypeCode', documentTypeCode)
    .field('sharedWith', 'INTERNAL')
    .attach('files', PDF, `${documentTypeCode.toLowerCase()}.pdf`);
  expect(res.status).toBe(201);
  return res.body.data[0].id;
}

beforeAll(async () => {
  admin = await adminSession();
  pm = await createActiveUser(admin.token, { email: 'pw.pm@test.local', roles: ['PARTNER_MGR'] });
  pm2 = await createActiveUser(admin.token, { email: 'pw.pm2@test.local', roles: ['PARTNER_MGR'] });
  head = await createActiveUser(admin.token, {
    email: 'pw.head@test.local',
    roles: ['SALES_HEAD'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'pw.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  const c = await dba();
  const [types] = await c.query(`SELECT id, code FROM partner_type WHERE code IN ('MSP', 'SI')`);
  for (const t of /** @type {any[]} */ (types)) ids[t.code] = t.id;
  const [[cert]] = await c.query('SELECT id FROM certification_type ORDER BY id LIMIT 1');
  ids.cert = cert.id;
  const [[ind]] = await c.query(`SELECT id FROM industry WHERE code = 'BFSI'`);
  ids.bfsi = ind.id;
});

afterAll(closeAll);

const create = (token, body) => api().post('/api/v1/partners').set(bearer(token)).send(body);
const save = (token, id, body) =>
  api().patch(`/api/v1/partners/${id}`).set(bearer(token)).send(body);
const edit = (token, id) => api().get(`/api/v1/partners/${id}/edit`).set(bearer(token));

describe('POST /partners and duplicates', () => {
  test('pm creates with the minimum fields; PTR number, owner = creator, some completeness', async () => {
    const res = await create(pm.token, {
      legalName: 'Write Networks Pvt Ltd',
      shortName: 'Write Networks',
      typeIds: [ids.MSP],
      website: 'https://www.write-networks.test/',
    });
    expect(res.status).toBe(201);
    expect(res.body.data.partnerNo).toMatch(/^PTR-\d{4,}$/);
    ids.p = res.body.data.id;

    const e = await edit(pm.token, ids.p);
    expect(e.status).toBe(200);
    expect(e.body.data).toMatchObject({
      country: 'India',
      relationshipOwnerUserId: pm.id,
      typeIds: [ids.MSP],
      rowVersion: 1,
    });
    expect(e.body.data.completenessPct).toBeGreaterThan(0);
  });

  test('without a type → 422; exec has no partner.create → 403', async () => {
    expect((await create(pm.token, { legalName: 'No Type', typeIds: [] })).status).toBe(422);
    expect((await create(exec.token, { legalName: 'X', typeIds: [ids.MSP] })).status).toBe(403);
  });

  test('another partner manager finds it by website and sees the owner', async () => {
    const res = await api()
      .get('/api/v1/partners/duplicates?website=write-networks.test')
      .set(bearer(pm2.token));
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual([
      expect.objectContaining({ id: ids.p, matchedOn: 'website', ownerName: expect.any(String) }),
    ]);
  });

  test('the same name again → 409 unless confirmed (BR-PT-02); email, phone, currency kept', async () => {
    const body = {
      legalName: 'write networks pvt ltd',
      typeIds: [ids.SI],
      email: 'hello@write-two.test',
      phone: '+91 20 1234 5678',
      currency: 'usd',
    };
    const dup = await create(pm2.token, body);
    expect(dup.status).toBe(409);
    expect(dup.body.error.details).toEqual([
      expect.objectContaining({ field: 'confirmDuplicate' }),
    ]);
    const ok = await create(pm2.token, { ...body, confirmDuplicate: true });
    expect(ok.status).toBe(201);
    const e = (await edit(pm2.token, ok.body.data.id)).body.data;
    expect(e).toMatchObject({
      email: 'hello@write-two.test',
      phone: '+91 20 1234 5678',
      currency: 'USD',
    });
  });

  test('a website that is not one → 422', async () => {
    const res = await create(pm.token, {
      legalName: 'Bad Site',
      typeIds: [ids.MSP],
      website: 'not a site',
    });
    expect(res.status).toBe(422);
  });
});

describe('PATCH /partners/:id sections', () => {
  test('ENTITY: address required; a signed agreement needs its date and document (BR-PT-07)', async () => {
    const entity = {
      section: 'ENTITY',
      rowVersion: 1,
      legalName: 'Write Networks Pvt Ltd',
      country: 'India',
      address: 'Plot 7, Hinjewadi Phase 1',
      city: 'Pune',
      email: 'sales@write-networks.test',
      gstNo: '27aapcw1234b1z5',
      financialStatus: 'STRONG',
      revenueFy: '2025-26',
      employeeCount: 250,
      agreementStatus: 'SIGNED',
    };
    const noAddress = await save(pm.token, ids.p, { ...entity, address: '' });
    expect(noAddress.status).toBe(422);
    expect((await save(pm.token, ids.p, entity)).status).toBe(422);
    const noDoc = await save(pm.token, ids.p, { ...entity, agreementValidTill: '2099-03-31' });
    expect(noDoc.status).toBe(422);
    expect(noDoc.body.error.details).toEqual([
      expect.objectContaining({ field: 'agreementDocumentId' }),
    ]);
    // a document of another type is not the agreement
    const other = await uploadDoc(pm.token, ids.p, 'GTM_PLAN');
    expect(
      (
        await save(pm.token, ids.p, {
          ...entity,
          agreementValidTill: '2099-03-31',
          agreementDocumentId: other,
        })
      ).status,
    ).toBe(422);
    ids.agreementDoc = await uploadDoc(pm.token, ids.p, 'AGREEMENT');
    const res = await save(pm.token, ids.p, {
      ...entity,
      agreementValidTill: '2099-03-31',
      agreementDocumentId: ids.agreementDoc,
    });
    expect(res.status).toBe(200);
    expect(res.body.data.rowVersion).toBe(2);
    const before = (await edit(pm.token, ids.p)).body.data;
    expect(before).toMatchObject({
      gstNo: '27AAPCW1234B1Z5',
      agreementDocumentId: ids.agreementDoc,
      financialStatus: 'STRONG',
      employeeCount: 250,
    });
    expect(res.body.data.completenessPct).toBe(before.completenessPct);
  });

  test('ENTITY: an unknown financial status or fiscal year → 422', async () => {
    const base = {
      section: 'ENTITY',
      rowVersion: 2,
      legalName: 'Write Networks Pvt Ltd',
      country: 'India',
      address: 'Plot 7',
      agreementStatus: 'NONE',
    };
    expect((await save(pm.token, ids.p, { ...base, financialStatus: 'Great' })).status).toBe(422);
    expect((await save(pm.token, ids.p, { ...base, revenueFy: 'FY26' })).status).toBe(422);
  });

  test('stale rowVersion → 409; an unrelated partner manager → 403', async () => {
    const body = { section: 'TYPE', rowVersion: 1, typeIds: [ids.SI], certificationTypeIds: [] };
    expect((await save(pm.token, ids.p, body)).status).toBe(409);
    expect((await save(pm2.token, ids.p, { ...body, rowVersion: 2 })).status).toBe(403);
  });

  test('TYPE and INDUSTRY replace their lists; audited per section', async () => {
    const t = await save(pm.token, ids.p, {
      section: 'TYPE',
      rowVersion: 2,
      typeIds: [ids.MSP, ids.SI],
      tier: 'GROWTH',
      certificationTypeIds: [ids.cert],
      otherCertifications: ['Fortinet NSE4'],
    });
    expect(t.status).toBe(200);
    const none = await save(pm.token, ids.p, {
      section: 'INDUSTRY',
      rowVersion: 3,
      industryIds: [],
    });
    expect(none.status).toBe(422);
    const mars = await save(pm.token, ids.p, {
      section: 'INDUSTRY',
      rowVersion: 3,
      industryIds: [ids.bfsi],
      regions: ['MARS'],
    });
    expect(mars.status).toBe(422);
    const i = await save(pm.token, ids.p, {
      section: 'INDUSTRY',
      rowVersion: 3,
      industryIds: [ids.bfsi],
      canRunPoc: true,
      dmuImpact: 'HIGH',
      regions: ['WEST', 'SOUTH', 'WEST'],
    });
    expect(i.status).toBe(200);
    const e = (await edit(pm.token, ids.p)).body.data;
    expect(e).toMatchObject({
      typeIds: [ids.MSP, ids.SI].sort((a, b) => a - b),
      tier: 'GROWTH',
      certificationTypeIds: [ids.cert],
      otherCertifications: ['Fortinet NSE4'],
      industryIds: [ids.bfsi],
      canRunPoc: true,
      regions: ['WEST', 'SOUTH'],
      rowVersion: 4,
    });
    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log WHERE entity_type = 'partner' AND entity_id = ? AND action = 'PARTNER_UPDATE'`,
      [ids.p],
    );
    expect(log.n).toBe(3);
  });

  test('TYPE: parent partner (hierarchy): not itself, no loop; the parent lists its sub-partners', async () => {
    const typeBody = (rowVersion, parentPartnerId) => ({
      section: 'TYPE',
      rowVersion,
      typeIds: [ids.MSP],
      certificationTypeIds: [],
      parentPartnerId,
    });
    expect((await save(pm.token, ids.p, typeBody(4, ids.p))).status).toBe(422);
    const child = await create(pm.token, { legalName: 'Write Reseller', typeIds: [ids.MSP] });
    expect(child.status).toBe(201);
    ids.child = child.body.data.id;
    const link = await save(pm.token, ids.child, typeBody(1, ids.p));
    expect(link.status).toBe(200);
    // ids.p above its child: making the child its parent would be a loop
    const loop = await save(pm.token, ids.p, typeBody(4, ids.child));
    expect(loop.status).toBe(422);
    expect(loop.body.error.details).toEqual([
      expect.objectContaining({ field: 'parentPartnerId' }),
    ]);
    const e = (await edit(pm.token, ids.child)).body.data;
    // the ENTITY save above sent no short name, so the legal name shows
    expect(e).toMatchObject({
      parentPartnerId: ids.p,
      parentPartnerName: 'Write Networks Pvt Ltd',
    });
    const w = (await api().get(`/api/v1/partners/${ids.p}`).set(bearer(pm.token))).body.data;
    expect(w.subPartners).toEqual([
      expect.objectContaining({ id: ids.child, name: 'Write Reseller' }),
    ]);
    expect(w.partner).toMatchObject({ employeeCount: 250, regions: ['WEST', 'SOUTH'] });
  });

  test('ENGAGEMENT: pm cannot hand the partner to someone outside the team; head can', async () => {
    const body = { section: 'ENGAGEMENT', rowVersion: 4, relationshipOwnerUserId: pm2.id };
    expect((await save(pm.token, ids.p, body)).status).toBe(403);
    const gtmDoc = await uploadDoc(pm.token, ids.p, 'GTM_PLAN');
    // the agreement is not a GTM plan
    expect(
      (await save(head.token, ids.p, { ...body, gtmDocumentId: ids.agreementDoc })).status,
    ).toBe(422);
    const res = await save(head.token, ids.p, {
      ...body,
      topManagement: 'CEO: A. Rao',
      techOnboardingStatus: 'TRAINED',
      gtmPlanStatus: 'AGREED',
      gtmDocumentId: gtmDoc,
    });
    expect(res.status).toBe(200);
    expect((await edit(head.token, ids.p)).body.data).toMatchObject({
      relationshipOwnerUserId: pm2.id,
      techOnboardingStatus: 'TRAINED',
      gtmDocumentId: gtmDoc,
    });
    const w = (await api().get(`/api/v1/partners/${ids.p}`).set(bearer(head.token))).body.data;
    expect(w.partner).toMatchObject({
      agreementDocumentId: ids.agreementDoc,
      agreementFileName: 'agreement.pdf',
      gtmDocumentId: gtmDoc,
    });
  });
});

describe('partner code at customers (V042)', () => {
  // the ENGAGEMENT test above handed the partner to pm2
  const url = () => `/api/v1/partners/${ids.p}/customer-codes`;

  test('owner adds a code for a named customer; same customer again → 422; others → 403', async () => {
    const add = await api()
      .post(url())
      .set(bearer(pm2.token))
      .send({ customerName: 'State Bank', code: 'WN-OEM-12' });
    expect(add.status).toBe(201);
    ids.code = add.body.data.id;
    const again = await api()
      .post(url())
      .set(bearer(pm2.token))
      .send({ customerName: 'state bank', code: 'X' });
    expect(again.status).toBe(422);
    const neither = await api().post(url()).set(bearer(pm2.token)).send({ code: 'X' });
    expect(neither.status).toBe(422);
    const other = await api()
      .post(url())
      .set(bearer(pm.token))
      .send({ customerName: 'Other Co', code: 'X' });
    expect(other.status).toBe(403);
  });

  test('change, shown in the workspace with its id, remove', async () => {
    const upd = await api()
      .patch(`${url()}/${ids.code}`)
      .set(bearer(pm2.token))
      .send({ customerName: 'State Bank', code: 'WN-OEM-14' });
    expect(upd.status).toBe(200);
    const w = (await api().get(`/api/v1/partners/${ids.p}`).set(bearer(pm2.token))).body.data;
    expect(w.customerCodes).toEqual([
      expect.objectContaining({ id: ids.code, customer: 'State Bank', code: 'WN-OEM-14' }),
    ]);
    const e = (await edit(pm2.token, ids.p)).body.data;
    expect(e.customerCodes).toEqual([
      expect.objectContaining({ id: ids.code, customerName: 'State Bank', accountId: null }),
    ]);
    expect((await api().delete(`${url()}/${ids.code}`).set(bearer(pm2.token))).status).toBe(204);
    expect((await api().delete(`${url()}/${ids.code}`).set(bearer(pm2.token))).status).toBe(404);
  });
});

describe('GET /partners/export', () => {
  test('xlsx for a user with report.export; logged', async () => {
    const res = await api().get('/api/v1/partners/export?search=Write').set(bearer(head.token));
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/spreadsheetml/);
    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM record_access_log WHERE user_id = ? AND entity_type = 'PARTNER' AND access_type = 'EXPORT'`,
      [head.id],
    );
    expect(log.n).toBe(1);
  });
});

describe('engagements and account map (V031)', () => {
  // the ENGAGEMENT test above handed the partner to pm2
  const today = new Date(Date.now() + 330 * 60000).toISOString().slice(0, 10);
  const log = (token, body, engagementId) =>
    (engagementId
      ? api().patch(`/api/v1/partners/${ids.p}/engagements/${engagementId}`)
      : api().post(`/api/v1/partners/${ids.p}/engagements`)
    )
      .set(bearer(token))
      .send(body);

  test('a logged engagement with a next action plans ONE open task for the owner (BR-PT-05)', async () => {
    const first = await log(pm2.token, {
      engagementType: 'MEETING',
      engagementOn: today,
      withWhom: 'CEO',
      nextAction: 'QBR with the sales team',
      nextActionOn: '2099-05-10',
    });
    expect(first.status).toBe(201);
    ids.eng = first.body.data.id;
    const again = await log(pm2.token, {
      engagementType: 'CALL',
      engagementOn: today,
      nextAction: 'Joint visit to Acme',
      nextActionOn: '2099-06-01',
    });
    expect(again.status).toBe(201);

    const c = await dba();
    const [tasks] = await c.query(
      `SELECT owner_user_id AS o, status AS s, DATE_FORMAT(due_at, '%Y-%m-%d') AS d, description AS t
         FROM task WHERE source_ref = ?`,
      [`ENG:${ids.p}`],
    );
    expect(tasks).toEqual([{ o: pm2.id, s: 'OPEN', d: '2099-06-01', t: 'Joint visit to Acme' }]);
    const [[p]] = await c.query(
      `SELECT DATE_FORMAT(last_engagement_on, '%Y-%m-%d') AS l, DATE_FORMAT(next_engagement_on, '%Y-%m-%d') AS n
         FROM partner WHERE id = ?`,
      [ids.p],
    );
    expect(p).toEqual({ l: today, n: '2099-06-01' });
  });

  test('future engagement, a next date without an action → 422; edit own → 200; no access → 404', async () => {
    expect(
      (await log(pm2.token, { engagementType: 'CALL', engagementOn: '2099-01-01' })).status,
    ).toBe(422);
    expect(
      (
        await log(pm2.token, {
          engagementType: 'CALL',
          engagementOn: today,
          nextActionOn: '2099-01-01',
        })
      ).status,
    ).toBe(422);
    const edit = await log(
      pm2.token,
      { engagementType: 'QBR', engagementOn: today, outcome: 'Good' },
      ids.eng,
    );
    expect(edit.status).toBe(200);
    expect((await log(pm.token, { engagementType: 'CALL', engagementOn: today })).status).toBe(404);
  });

  test('account map: add, no duplicate per period, change, remove; others → 403', async () => {
    const c = await dba();
    const [res] = await c.query(
      `INSERT INTO account (account_no, name, owner_user_id) VALUES ('PW-ACC-1', 'Map Corp', ?)`,
      [pm2.id],
    );
    const accountId = /** @type {any} */ (res).insertId;
    const url = `/api/v1/partners/${ids.p}/account-map`;
    const add = await api()
      .post(url)
      .set(bearer(pm2.token))
      .send({ accountId, planPeriod: '2099-h1' });
    expect(add.status).toBe(201);
    const rowId = add.body.data.id;
    expect(
      (await api().post(url).set(bearer(pm2.token)).send({ accountId, planPeriod: '2099-H1' }))
        .status,
    ).toBe(422);
    expect(
      (await api().post(url).set(bearer(pm.token)).send({ accountId, planPeriod: '2099-H2' }))
        .status,
    ).toBe(403);
    const upd = await api()
      .patch(`${url}/${rowId}`)
      .set(bearer(pm2.token))
      .send({ accountId, planPeriod: '2099-H1', status: 'OPPORTUNITY' });
    expect(upd.status).toBe(200);
    const [[row]] = await c.query('SELECT status FROM partner_account_map WHERE id = ?', [rowId]);
    expect(row.status).toBe('OPPORTUNITY');
    expect((await api().delete(`${url}/${rowId}`).set(bearer(head.token))).status).toBe(204);
  });
});

describe('POST /partner-performance/recompute (V033)', () => {
  test('admin recomputes: an open snapshot for this quarter and current values on the partner', async () => {
    const res = await api().post('/api/v1/partner-performance/recompute').set(bearer(admin.token));
    expect(res.status).toBe(200);
    expect(res.body.data.partners).toBeGreaterThan(0);
    const c = await dba();
    const [[snap]] = await c.query(
      'SELECT COUNT(*) AS n, MIN(is_frozen) AS f FROM partner_performance_snapshot WHERE partner_id = ? AND is_frozen = 0',
      [ids.p],
    );
    expect(snap.n).toBe(1);
    const [[p]] = await c.query('SELECT perf_computed_at AS at FROM partner WHERE id = ?', [ids.p]);
    expect(p.at).not.toBeNull();
    // the previous quarter is frozen once and kept on the next run
    const [[frozen]] = await c.query(
      'SELECT id, computed_at AS at FROM partner_performance_snapshot WHERE partner_id = ? AND is_frozen = 1',
      [ids.p],
    );
    await api().post('/api/v1/partner-performance/recompute').set(bearer(admin.token));
    const [[again]] = await c.query(
      'SELECT id, computed_at AS at FROM partner_performance_snapshot WHERE id = ?',
      [frozen.id],
    );
    expect(again.at).toEqual(frozen.at);
  });

  test('a partner manager cannot recompute → 403', async () => {
    const res = await api().post('/api/v1/partner-performance/recompute').set(bearer(pm.token));
    expect(res.status).toBe(403);
  });
});

describe('quarterly report PDF (V034)', () => {
  const ist = new Date(Date.now() + 330 * 60000);
  const m = ist.getUTCMonth() + 1;
  const fiscalYear = m >= 4 ? ist.getUTCFullYear() : ist.getUTCFullYear() - 1;
  const quarter = Math.floor(((m - 4 + 12) % 12) / 3) + 1;
  const url = () => `/api/v1/partners/${ids.p}/quarterly-reports`;

  test('the owner generates it; stored as a partner document; same period → next version', async () => {
    const res = await api().post(url()).set(bearer(pm2.token)).send({ fiscalYear, quarter });
    expect(res.status).toBe(201);
    expect(res.body.data).toMatchObject({
      versionNo: 1,
      fileName: expect.stringMatching(/\.pdf$/),
    });
    const file = await api()
      .get(`/api/v1/documents/${res.body.data.documentId}/download`)
      .set(bearer(pm2.token))
      .buffer(true)
      .parse((r, cb) => {
        const chunks = [];
        r.on('data', (ch) => chunks.push(ch));
        r.on('end', () => cb(null, Buffer.concat(chunks)));
      });
    expect(file.status).toBe(200);
    expect(file.body.subarray(0, 5).toString()).toBe('%PDF-');

    const again = await api().post(url()).set(bearer(pm2.token)).send({ fiscalYear, quarter });
    expect(again.body.data.versionNo).toBe(2);
    const list = await api().get(url()).set(bearer(pm2.token));
    expect(list.body.data).toHaveLength(2);
  });

  test('a partner the user cannot see → 404', async () => {
    const res = await api().post(url()).set(bearer(pm.token)).send({ fiscalYear, quarter });
    expect(res.status).toBe(404);
  });
});
