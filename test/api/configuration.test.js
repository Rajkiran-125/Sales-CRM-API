'use strict';

/** Masters, stages, settings, email templates (12.14) and the audit viewer with export (18.5). */
const ExcelJS = require('exceljs');
const {
  api,
  dba,
  closeAll,
  lastMail,
  adminSession,
  createActiveUser,
  bearer,
} = require('../helpers');

let admin;
beforeAll(async () => {
  admin = await adminSession();
});
afterAll(closeAll);

describe('masters', () => {
  test('the master type list and the seeded values from the User Manual', async () => {
    const types = (await api().get('/api/v1/masters').set(bearer(admin.token))).body.data;
    expect(types.map((t) => t.type)).toEqual(
      expect.arrayContaining(['industries', 'reasons', 'stages', 'solutions']),
    );

    const partnerTypes = (await api().get('/api/v1/masters/partner-types').set(bearer(admin.token)))
      .body.data;
    expect(partnerTypes.map((p) => p.name)).toEqual([
      'MSP',
      'Telco',
      'Reseller',
      'VAD',
      'SI',
      'Consultant',
      'Govt/PSU partner',
    ]);

    const loss = (
      await api().get('/api/v1/masters/reasons?reasonType=LOSS').set(bearer(admin.token))
    ).body.data;
    expect(loss.find((r) => r.code === 'NO_DECISION').competitorRequired).toBe(false);
    expect(loss.find((r) => r.code === 'PRICE').competitorRequired).toBe(true);

    const opp = (await api().get('/api/v1/masters/stages?entity=OPP').set(bearer(admin.token))).body
      .data;
    expect(opp.map((s) => [s.code, s.defaultConfidencePct])).toEqual([
      ['QUALIFIED', '20.00'],
      ['TECH_ENGAGEMENT', '30.00'],
      ['POC', '40.00'],
      ['PROPOSAL', '50.00'],
      ['NEGOTIATION', '70.00'],
      ['COMMERCIAL_CLOSED', '85.00'],
      ['CONTRACT_SIGNED', '90.00'],
      ['WON', '100.00'],
      ['LOST', '0.00'],
      ['DORMANT', null],
    ]);
  });

  test('create, duplicate, deactivate; inactive entries hidden from normal users', async () => {
    const created = await api()
      .post('/api/v1/masters/industries')
      .set(bearer(admin.token))
      .send({ code: 'manufacturing', name: 'Manufacturing', sortOrder: 7 });
    expect(created.status).toBe(201);
    expect(created.body.data).toMatchObject({ code: 'MANUFACTURING', isActive: true });

    const dup = await api()
      .post('/api/v1/masters/industries')
      .set(bearer(admin.token))
      .send({ code: 'MANUFACTURING', name: 'Again' });
    expect(dup.status).toBe(409);

    const off = await api()
      .patch(`/api/v1/masters/industries/${created.body.data.id}`)
      .set(bearer(admin.token))
      .send({ name: 'Manufacturing', sortOrder: 7, isActive: false });
    expect(off.body.data.isActive).toBe(false);

    const exec = await createActiveUser(admin.token, {
      email: 'masters.reader@test.local',
      roles: ['SALES_EXEC'],
    });
    const asExec = (
      await api().get('/api/v1/masters/industries?includeInactive=true').set(bearer(exec.token))
    ).body.data;
    expect(asExec.map((i) => i.code)).not.toContain('MANUFACTURING');
    const asAdmin = (
      await api().get('/api/v1/masters/industries?includeInactive=true').set(bearer(admin.token))
    ).body.data;
    expect(asAdmin.map((i) => i.code)).toContain('MANUFACTURING');
  });

  test('solutions, reasons, competitors and procurement steps', async () => {
    const products = (await api().get('/api/v1/masters/products').set(bearer(admin.token))).body
      .data;
    const firewall = products.find((p) => p.code === 'FIREWALL');
    const sol = await api()
      .post('/api/v1/masters/solutions')
      .set(bearer(admin.token))
      .send({ productId: firewall.id, name: 'NGFW with SD-WAN', description: 'Branch firewall' });
    expect(sol.status).toBe(201);
    expect(sol.body.data.productName).toBe('Firewall');

    const reason = await api().post('/api/v1/masters/reasons').set(bearer(admin.token)).send({
      reasonType: 'LOSS',
      code: 'compliance',
      name: 'Compliance gap',
      competitorRequired: true,
    });
    expect(reason.status).toBe(201);
    expect(reason.body.data).toMatchObject({ code: 'COMPLIANCE', competitorRequired: true });

    const comp = await api()
      .post('/api/v1/masters/competitors')
      .set(bearer(admin.token))
      .send({ name: 'Palo Alto' });
    expect(comp.status).toBe(201);

    const types = (await api().get('/api/v1/masters/procurement-types').set(bearer(admin.token)))
      .body.data;
    const rate = types.find((t) => t.code === 'RATE_CONTRACT');
    const step = await api()
      .post('/api/v1/masters/procurement-steps')
      .set(bearer(admin.token))
      .send({
        procurementTypeId: rate.id,
        sequenceNo: 1,
        name: 'Empanelment',
        hintConfidencePct: 25,
      });
    expect(step.status).toBe(201);
    const dupStep = await api()
      .post('/api/v1/masters/procurement-steps')
      .set(bearer(admin.token))
      .send({ procurementTypeId: rate.id, sequenceNo: 1, name: 'Again' });
    expect(dupStep.status).toBe(409);
  });

  test('stage edits: open-stage confidence editable, Won fixed, non-opportunity stages have none', async () => {
    const opp = (await api().get('/api/v1/masters/stages?entity=OPP').set(bearer(admin.token))).body
      .data;
    const poc = opp.find((s) => s.code === 'POC');
    const won = opp.find((s) => s.code === 'WON');

    const ok = await api()
      .patch(`/api/v1/masters/stages/${poc.id}`)
      .set(bearer(admin.token))
      .send({ name: 'POC', defaultConfidencePct: 45, slaDays: 45, colourToken: 'info' });
    expect(ok.status).toBe(200);
    expect(ok.body.data.find((s) => s.code === 'POC').defaultConfidencePct).toBe('45.00');

    const fixed = await api()
      .patch(`/api/v1/masters/stages/${won.id}`)
      .set(bearer(admin.token))
      .send({ name: 'Won', defaultConfidencePct: 95, slaDays: null, colourToken: 'success' });
    expect(fixed.status).toBe(422);

    const lead = (await api().get('/api/v1/masters/stages?entity=LEAD').set(bearer(admin.token)))
      .body.data[0];
    const leadPct = await api()
      .patch(`/api/v1/masters/stages/${lead.id}`)
      .set(bearer(admin.token))
      .send({ name: 'New', defaultConfidencePct: 10, slaDays: null, colourToken: 'neutral' });
    expect(leadPct.status).toBe(422);
  });
});

describe('settings', () => {
  test('type and range checks; batches are all-or-nothing; changes audited', async () => {
    const url = '/api/v1/settings';
    const list = (await api().get(url).set(bearer(admin.token))).body.data;
    expect(list.find((s) => s.key === 'offer.approval.discount_pct')).toMatchObject({
      value: '15',
      valueType: 'DECIMAL',
    });

    const range = await api()
      .patch(url)
      .set(bearer(admin.token))
      .send({ items: [{ key: 'deal.stale_days', value: '3' }] });
    expect(range.status).toBe(422);
    expect(range.body.error.details[0]).toMatchObject({
      field: 'deal.stale_days',
      message: 'Enter a value from 7 to 365.',
    });

    const atomic = await api()
      .patch(url)
      .set(bearer(admin.token))
      .send({
        items: [
          { key: 'deal.stale_days', value: '45' },
          { key: 'weekly_status.due_time', value: '25:00' },
        ],
      });
    expect(atomic.status).toBe(422);
    const after = (await api().get(url).set(bearer(admin.token))).body.data;
    expect(after.find((s) => s.key === 'deal.stale_days').value).toBe('60');

    const ok = await api()
      .patch(url)
      .set(bearer(admin.token))
      .send({
        items: [
          { key: 'deal.stale_days', value: '45' },
          { key: 'weekly_status.due_day', value: 'thursday' },
        ],
      });
    expect(ok.status).toBe(200);
    expect(ok.body.data.find((s) => s.key === 'weekly_status.due_day')).toMatchObject({
      value: 'THURSDAY',
      updatedByName: 'Test Admin',
    });

    const audit = (
      await api()
        .get('/api/v1/audit-logs?entityType=SETTING&entityId=deal.stale_days')
        .set(bearer(admin.token))
    ).body.data;
    expect(audit[0].changes).toEqual({ value: { from: '60', to: '45' } });
  });
});

describe('email templates', () => {
  test('HTML is sanitised and placeholders are checked; sign-in emails cannot be switched off', async () => {
    const url = '/api/v1/email-templates/PASSWORD_CHANGED';
    const current = (await api().get(url).set(bearer(admin.token))).body.data;

    const unknown = await api()
      .patch(url)
      .set(bearer(admin.token))
      .send({ rowVersion: current.rowVersion, bodyHtml: '<p>Hi {{fullName}}, {{password}}</p>' });
    expect(unknown.status).toBe(422);
    expect(unknown.body.error.details[0].field).toBe('bodyHtml');

    const off = await api()
      .patch(url)
      .set(bearer(admin.token))
      .send({ rowVersion: current.rowVersion, isActive: false });
    expect(off.status).toBe(422);

    const ok = await api().patch(url).set(bearer(admin.token)).send({
      rowVersion: current.rowVersion,
      bodyHtml:
        '<p onclick="steal()">Hello {{fullName}}</p><script>alert(1)</script><a href="javascript:alert(1)">x</a>',
    });
    expect(ok.status).toBe(200);
    expect(ok.body.data.bodyHtml).toBe('<p>Hello {{fullName}}</p><a>x</a>');
    expect(ok.body.data.rowVersion).toBe(current.rowVersion + 1);

    const stale = await api()
      .patch(url)
      .set(bearer(admin.token))
      .send({ rowVersion: current.rowVersion, subject: 'x' });
    expect(stale.status).toBe(409);
  });

  test('test send goes to my own address with escaped values', async () => {
    const res = await api()
      .post('/api/v1/email-templates/USER_INVITATION/test')
      .set(bearer(admin.token));
    expect(res.status).toBe(204);
    const mail = await lastMail('admin@test.local', 'USER_INVITATION');
    expect(mail.subject).toBe('You are invited to Sales CRM');
    expect(mail.html).toContain('Test Admin');
  });
});

describe('audit viewer', () => {
  test('security events and data changes are listed newest first, with paging', async () => {
    const all = await api()
      .get('/api/v1/security-events?eventCode=LOGIN_SUCCESS&pageSize=100')
      .set(bearer(admin.token));
    expect(all.status).toBe(200);
    expect(all.body.meta.total).toBeGreaterThanOrEqual(2);
    const times = all.body.data.map((e) => new Date(e.occurredAt).getTime());
    expect(times).toEqual([...times].sort((a, b) => b - a));

    const page2 = await api()
      .get('/api/v1/security-events?eventCode=LOGIN_SUCCESS&pageSize=1&page=2')
      .set(bearer(admin.token));
    expect(page2.body.data).toHaveLength(1);
    expect(page2.body.data[0].id).toBe(all.body.data[1].id);
    expect(page2.body.meta).toMatchObject({ page: 2, pageSize: 1, total: all.body.meta.total });

    const created = await api()
      .get('/api/v1/audit-logs?entityType=USER&action=CREATE')
      .set(bearer(admin.token));
    expect(created.body.data[0].changes.status).toEqual({ from: null, to: 'INVITED' });
  });

  test('export returns an xlsx and is itself logged', async () => {
    const res = await api()
      .get('/api/v1/audit-logs/export?entityType=USER')
      .set(bearer(admin.token))
      .buffer(true)
      .parse((r, cb) => {
        const chunks = [];
        r.on('data', (c) => chunks.push(c));
        r.on('end', () => cb(null, Buffer.concat(chunks)));
      });
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('spreadsheetml');
    expect(res.headers['content-disposition']).toContain('audit-log.xlsx');

    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(res.body);
    const sheet = wb.getWorksheet('Audit log');
    expect(sheet.getRow(1).getCell(1).value).toBe('When (UTC)');
    expect(sheet.rowCount).toBeGreaterThan(1);

    const conn = await dba();
    const [rows] = await conn.query(
      "SELECT COUNT(*) AS n FROM record_access_log WHERE access_type = 'EXPORT' AND entity_type = 'AUDIT_LOG'",
    );
    expect(rows[0].n).toBe(1);
  });
});
