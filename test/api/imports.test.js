'use strict';

/**
 * Partner import (V036, 12.17): template, upload checked into a preview, commit creates the
 * valid rows (audited IMPORTED), a batch is committed once.
 */
const ExcelJS = require('exceljs');
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');
const { COLUMNS } = require('../../src/modules/imports/imports.partners');

let admin, pm;

beforeAll(async () => {
  admin = await adminSession();
  pm = await createActiveUser(admin.token, { email: 'imp.pm@test.local', roles: ['PARTNER_MGR'] });
});

afterAll(closeAll);

/** @param {Record<string, string>[]} rows */
async function sheet(rows) {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Partners');
  ws.addRow(COLUMNS.map((c) => c.header));
  for (const r of rows) ws.addRow(COLUMNS.map((c) => r[c.key] ?? ''));
  return Buffer.from(await wb.xlsx.writeBuffer());
}

// Skipped while data import is disabled (src/routes.js).
describe.skip('partner import', () => {
  test('template download; a partner manager cannot import', async () => {
    const t = await api().get('/api/v1/imports/templates/partners').set(bearer(admin.token));
    expect(t.status).toBe(200);
    expect(t.headers['content-type']).toMatch(/spreadsheetml/);
    const no = await api().get('/api/v1/imports/templates/partners').set(bearer(pm.token));
    expect(no.status).toBe(403);
  });

  test('upload → preview with messages → commit creates the valid row once', async () => {
    const file = await sheet([
      {
        legalName: 'Import One Pvt Ltd',
        types: 'MSP',
        ownerEmail: 'imp.pm@test.local',
        country: 'India',
      },
      { legalName: 'Import Two', types: 'NOPE', ownerEmail: 'imp.pm@test.local' },
    ]);
    const up = await api()
      .post('/api/v1/imports')
      .set(bearer(admin.token))
      .field('entity', 'PARTNER')
      .attach('file', file, 'partners.xlsx');
    expect(up.status).toBe(201);
    expect(up.body.data).toMatchObject({ status: 'PREVIEW', totalRows: 2, errorCount: 1 });
    expect(up.body.data.rows.map((r) => r.status)).toEqual(['VALID', 'INVALID']);
    const id = up.body.data.id;

    const done = await api().post(`/api/v1/imports/${id}/commit`).set(bearer(admin.token));
    expect(done.status).toBe(200);
    expect(done.body.data).toMatchObject({ status: 'COMMITTED', createdCount: 1, errorCount: 1 });
    const partnerId = done.body.data.rows[0].createdEntityId;
    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log WHERE entity_type = 'partner' AND entity_id = ? AND action = 'IMPORTED'`,
      [partnerId],
    );
    expect(log.n).toBe(1);
    expect((await api().post(`/api/v1/imports/${id}/commit`).set(bearer(admin.token))).status).toBe(
      422,
    );
  });

  test('the same file again: the partner is now a duplicate', async () => {
    const file = await sheet([
      { legalName: 'Import One Pvt Ltd', types: 'MSP', ownerEmail: 'imp.pm@test.local' },
    ]);
    const up = await api()
      .post('/api/v1/imports')
      .set(bearer(admin.token))
      .field('entity', 'PARTNER')
      .attach('file', file, 'partners.xlsx');
    expect(up.body.data.rows[0]).toMatchObject({ status: 'INVALID' });
    expect(up.body.data.rows[0].errors[0]).toMatch(/^Already in the CRM/);
  });

  test('not an xlsx → 415', async () => {
    const up = await api()
      .post('/api/v1/imports')
      .set(bearer(admin.token))
      .field('entity', 'PARTNER')
      .attach('file', Buffer.from('a,b\n1,2'), 'partners.xlsx');
    expect(up.status).toBe(415);
  });
});
