'use strict';

/** Platform behaviour: health, envelope, headers, request id, route protection (8.7, 8.8, 17.5, 21.1). */
const { api, closeAll } = require('../helpers');
const { registry } = require('../../src/shared/routeTable');

afterAll(closeAll);

describe('health', () => {
  test('GET /health is public and carries no data', async () => {
    const res = await api().get('/api/v1/health');
    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('UP');
  });

  test('GET /health/ready reports the database from the internal network', async () => {
    const res = await api().get('/api/v1/health/ready');
    expect(res.status).toBe(200);
    expect(res.body.data.checks.database.status).toBe('UP');
  });
});

describe('envelope and headers', () => {
  test('unknown endpoint -> 404 envelope with the request id', async () => {
    const res = await api().get('/api/v1/nope').set('X-Request-Id', 'test-request-0001');
    expect(res.status).toBe(404);
    expect(res.body).toEqual({
      success: false,
      error: { code: 'NOT_FOUND', message: expect.any(String) },
      requestId: 'test-request-0001',
    });
    expect(res.headers['x-request-id']).toBe('test-request-0001');
  });

  test('malformed JSON -> 400 BAD_REQUEST', async () => {
    const res = await api()
      .post('/api/v1/auth/login')
      .set('Content-Type', 'application/json')
      .send('{"email": ');
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('BAD_REQUEST');
  });

  test('security headers from helmet are present', async () => {
    const res = await api().get('/api/v1/health');
    expect(res.headers['x-frame-options']).toBe('DENY');
    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['content-security-policy']).toContain("frame-ancestors 'none'");
    expect(res.headers['strict-transport-security']).toBeDefined();
    expect(res.headers['x-powered-by']).toBeUndefined();
  });

  test('protected endpoint without a token -> 401 UNAUTHENTICATED', async () => {
    const res = await api().get('/api/v1/users');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('UNAUTHENTICATED');
  });

  test('OpenAPI document is generated from the route table', async () => {
    const res = await api().get('/api-docs/openapi.json');
    expect(res.status).toBe(200);
    expect(res.body.paths['/api/v1/users'].get['x-permissions']).toEqual(['user.view']);
  });
});

describe('route protection (21.1: every route declares its access)', () => {
  /** Routes any signed-in user may call without a specific permission. */
  const AUTHENTICATED_ONLY = new Set([
    'POST /api/v1/auth/logout',
    'POST /api/v1/auth/logout-all',
    'GET /api/v1/auth/me',
    'POST /api/v1/auth/password/change',
    'GET /api/v1/auth/sessions',
    'DELETE /api/v1/auth/sessions/:id',
    'GET /api/v1/users/lookup',
    // configuration every form renders, like the master reads
    'GET /api/v1/custom-fields',
  ]);
  const PUBLIC = new Set([
    'POST /api/v1/auth/login',
    'POST /api/v1/auth/refresh',
    'POST /api/v1/auth/password/forgot',
    'POST /api/v1/auth/password/reset/check',
    'POST /api/v1/auth/password/reset',
    'POST /api/v1/auth/invitations/check',
    'POST /api/v1/auth/invitations/accept',
  ]);

  test('the registry is populated', () => {
    expect(registry.length).toBeGreaterThan(40);
  });

  test.each(registry.map((r) => [`${r.method.toUpperCase()} ${r.fullPath}`, r]))('%s', (key, r) => {
    if (r.access === 'public') {
      expect(PUBLIC.has(key)).toBe(true);
    } else if (r.access === 'authenticated') {
      const masterRead = r.method === 'get' && r.fullPath.startsWith('/api/v1/masters');
      expect(AUTHENTICATED_ONLY.has(key) || masterRead).toBe(true);
    } else {
      expect(Array.isArray(r.access) && r.access.length > 0).toBe(true);
    }
  });
});
