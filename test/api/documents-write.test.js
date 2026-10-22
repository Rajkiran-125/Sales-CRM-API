'use strict';

/**
 * Documents write side (V023): upload with settings limits and content check (17.9),
 * versions by title, download of visible records only, soft delete by the uploader.
 * Fixture: exec owns the account and deal; other = unrelated exec; head = ALL scope.
 */
const fs = require('fs');
const path = require('path');
const config = require('../../src/config');
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, other, head;
const ids = /** @type {Record<string, number>} */ ({});
const PDF = Buffer.from('%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n');

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'doc.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  other = await createActiveUser(admin.token, {
    email: 'doc.other@test.local',
    roles: ['SALES_EXEC'],
  });
  head = await createActiveUser(admin.token, {
    email: 'doc.head@test.local',
    roles: ['SALES_HEAD'],
  });
  const c = await dba();
  const ins = async (sql, args) => /** @type {any} */ ((await c.query(sql, args))[0]).insertId;
  ids.acc = await ins(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('DOC-ACC-1', 'Doc Corp', ?)`,
    [exec.id],
  );
  ids.opp = await ins(
    `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
       weighted_value, expected_close_date, owner_user_id)
     VALUES ('DOC-OPP-1', 'Doc Deal', ?, 'DIRECT', 'QUALIFIED', 1000000, 200000, '2099-01-01', ?)`,
    [ids.acc, exec.id],
  );
});

afterAll(closeAll);

/** @param {string} token @param {Record<string, string>} fields @param {Array<[Buffer, string]>} files */
function upload(token, fields, files) {
  let req = api().post('/api/v1/documents').set(bearer(token));
  for (const [k, v] of Object.entries(fields)) req = req.field(k, v);
  for (const [buf, name] of files) req = req.attach('files', buf, name);
  return req;
}

const oppFields = (over = {}) => ({
  entityType: 'OPP',
  entityId: String(ids.opp),
  documentTypeCode: 'PROPOSAL',
  sharedWith: 'CUSTOMER',
  sharedOn: '2026-10-14',
  tags: 'Final, proposal',
  ...over,
});

describe('POST /documents', () => {
  test('owner uploads a PDF to the deal → 201; metadata, tags and the file on disk', async () => {
    const res = await upload(exec.token, oppFields({ title: 'Commercial proposal' }), [
      [PDF, 'proposal.pdf'],
    ]);
    expect(res.status).toBe(201);
    expect(res.body.data).toEqual([
      expect.objectContaining({
        versionNo: 1,
        title: 'Commercial proposal',
        fileName: 'proposal.pdf',
      }),
    ]);
    ids.doc1 = res.body.data[0].id;

    const c = await dba();
    const [[d]] = await c.query(
      `SELECT d.opportunity_id AS o, d.account_id AS a, d.shared_by AS sb, f.storage_key AS k,
              f.mime_type AS m, f.scan_status AS s, f.size_bytes AS n
         FROM document d JOIN file_object f ON f.id = d.file_object_id WHERE d.id = ?`,
      [ids.doc1],
    );
    expect(d).toMatchObject({
      o: ids.opp,
      a: ids.acc,
      sb: exec.id,
      m: 'application/pdf',
      s: 'SKIPPED',
    });
    expect(Number(d.n)).toBe(PDF.length);
    expect(fs.existsSync(path.join(config.files.dir, d.k.slice(0, 2), d.k))).toBe(true);
    const [tags] = await c.query(
      'SELECT tag FROM document_tag WHERE document_id = ? ORDER BY tag',
      [ids.doc1],
    );
    expect(tags.map((t) => t.tag)).toEqual(['final', 'proposal']);
  });

  test('same title on the same record → version 2', async () => {
    const res = await upload(exec.token, oppFields({ title: 'Commercial proposal' }), [
      [PDF, 'proposal-v2.pdf'],
    ]);
    expect(res.status).toBe(201);
    expect(res.body.data[0].versionNo).toBe(2);
  });

  test('two files at once: titles come from the file names', async () => {
    const res = await upload(exec.token, oppFields({ documentTypeCode: 'DATASHEET' }), [
      [PDF, 'sheet-a.pdf'],
      // csv is only in the admin-selectable list, not the default allow-list
      [Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]), 'prices.png'],
    ]);
    expect(res.status).toBe(201);
    expect(res.body.data.map((d) => d.title)).toEqual(['sheet-a', 'prices']);
  });

  test('a text file named .pdf → 415 and nothing stored', async () => {
    const c = await dba();
    const [[before]] = await c.query('SELECT COUNT(*) AS n FROM file_object');
    const res = await upload(exec.token, oppFields(), [
      [PDF, 'ok.pdf'],
      [Buffer.from('not a pdf'), 'fake.pdf'],
    ]);
    expect(res.status).toBe(415);
    const [[after]] = await c.query('SELECT COUNT(*) AS n FROM file_object');
    expect(after.n).toBe(before.n);
  });

  test('an extension outside the allow-list → 415', async () => {
    const res = await upload(exec.token, oppFields(), [[Buffer.from('MZ'), 'tool.exe']]);
    expect(res.status).toBe(415);
  });

  test('no file → 422; unknown document type → 422', async () => {
    expect((await upload(exec.token, oppFields(), [])).status).toBe(422);
    const bad = await upload(exec.token, oppFields({ documentTypeCode: 'NOPE' }), [[PDF, 'x.pdf']]);
    expect(bad.status).toBe(422);
  });

  test('shared with a partner needs the partner → 422', async () => {
    const res = await upload(exec.token, oppFields({ sharedWith: 'PARTNER' }), [[PDF, 'x.pdf']]);
    expect(res.status).toBe(422);
  });

  test('a record the user cannot see → 404', async () => {
    const res = await upload(other.token, oppFields(), [[PDF, 'x.pdf']]);
    expect(res.status).toBe(404);
  });

  test('upload to the account; the search lists it', async () => {
    const res = await upload(
      exec.token,
      {
        entityType: 'ACCOUNT',
        entityId: String(ids.acc),
        documentTypeCode: 'NDA',
        title: 'Mutual NDA',
      },
      [[PDF, 'nda.pdf']],
    );
    expect(res.status).toBe(201);
    const list = await api()
      .get(`/api/v1/documents?accountId=${ids.acc}&entityType=ACCOUNT`)
      .set(bearer(exec.token));
    expect(list.body.data.map((d) => d.title)).toContain('Mutual NDA');
  });
});

describe('GET /documents/:id/download', () => {
  test('owner downloads the bytes as an attachment; logged as DOWNLOAD', async () => {
    const res = await api()
      .get(`/api/v1/documents/${ids.doc1}/download`)
      .set(bearer(exec.token))
      .buffer(true)
      .parse((r, cb) => {
        const chunks = [];
        r.on('data', (ch) => chunks.push(ch));
        r.on('end', () => cb(null, Buffer.concat(chunks)));
      });
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/^application\/pdf/);
    expect(res.headers['content-disposition']).toBe("attachment; filename*=UTF-8''proposal.pdf");
    expect(Buffer.compare(res.body, PDF)).toBe(0);
    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM record_access_log
        WHERE entity_type = 'DOCUMENT' AND entity_id = ? AND access_type = 'DOWNLOAD'`,
      [ids.doc1],
    );
    expect(log.n).toBe(1);
  });

  test('a user who cannot see the deal → 404', async () => {
    const res = await api().get(`/api/v1/documents/${ids.doc1}/download`).set(bearer(other.token));
    expect(res.status).toBe(404);
  });
});

describe('PATCH /documents/:id (V027)', () => {
  test('replaces the tags and keeps the notes when notes are left out; audited', async () => {
    const res = await api()
      .patch(`/api/v1/documents/${ids.doc1}`)
      .set(bearer(exec.token))
      .send({ tags: ['Signed', 'final', 'signed'] });
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({ id: ids.doc1, tags: ['final', 'signed'], notes: null });

    const notes = await api()
      .patch(`/api/v1/documents/${ids.doc1}`)
      .set(bearer(exec.token))
      .send({ notes: ' Customer copy ' });
    expect(notes.body.data).toEqual({
      id: ids.doc1,
      tags: ['final', 'signed'],
      notes: 'Customer copy',
    });

    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log
        WHERE entity_type = 'document' AND entity_id = ? AND action = 'DOCUMENT_UPDATE'`,
      [ids.doc1],
    );
    expect(log.n).toBe(2);
  });

  test('empty body → 422; a user who cannot see the deal → 404', async () => {
    const empty = await api()
      .patch(`/api/v1/documents/${ids.doc1}`)
      .set(bearer(exec.token))
      .send({});
    expect(empty.status).toBe(422);
    const hidden = await api()
      .patch(`/api/v1/documents/${ids.doc1}`)
      .set(bearer(other.token))
      .send({ tags: [] });
    expect(hidden.status).toBe(404);
  });
});

describe('DELETE /documents/:id', () => {
  test('an ALL-scope user may delete; then the document is gone', async () => {
    const del = await api().delete(`/api/v1/documents/${ids.doc1}`).set(bearer(head.token));
    expect(del.status).toBe(204);
    const res = await api().get(`/api/v1/documents/${ids.doc1}/download`).set(bearer(exec.token));
    expect(res.status).toBe(404);
  });

  test('a visible document of someone else cannot be deleted by a non-admin → 403', async () => {
    const up = await upload(head.token, oppFields({ title: 'Head upload' }), [[PDF, 'h.pdf']]);
    expect(up.status).toBe(201);
    const del = await api()
      .delete(`/api/v1/documents/${up.body.data[0].id}`)
      .set(bearer(exec.token));
    expect(del.status).toBe(403);
  });
});
