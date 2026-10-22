'use strict';

/** Unit tests (no database): policy, error mapping, rendering, export safety, config guard. */
const { execFileSync } = require('child_process');
const path = require('path');
const { checkPasswordPolicy } = require('../../src/auth/passwordPolicy');
const { fromDbError, AppError } = require('../../src/shared/errors');
const { render } = require('../../src/integrations/mailer');
const { safeCell } = require('../../src/integrations/excel');

describe('password policy (OD-08)', () => {
  test.each([
    ['Correct-Horse-42', true],
    ['abcDEF1234', true],
    ['a long passphrase here', true],
    ['short1A!', false],
    ['alllowercase1', false],
    ['password123', false],
    ['Welcome@123', false],
  ])('%s -> acceptable: %s', (pw, ok) => {
    expect(checkPasswordPolicy(pw).length === 0).toBe(ok);
  });

  test('rejects the name or the email name', () => {
    expect(checkPasswordPolicy('Shailesh-2026-x', { fullName: 'Shailesh Patil' })).not.toHaveLength(
      0,
    );
    expect(
      checkPasswordPolicy('Xyz-sarika-2026', { email: 'sarika@cnergee.com' }),
    ).not.toHaveLength(0);
    expect(
      checkPasswordPolicy('Unrelated-Pass-9', {
        email: 'sarika@cnergee.com',
        fullName: 'Sarika K',
      }),
    ).toHaveLength(0);
  });

  test('rejects more than 128 characters', () => {
    expect(checkPasswordPolicy(`Aa1-${'x'.repeat(130)}`)).toContain('Use at most 128 characters.');
  });
});

describe('database error mapping (8.7, D-12)', () => {
  test('procedure business errors keep their code, field and message', () => {
    const e = fromDbError({
      sqlState: '45000',
      sqlMessage: 'DUPLICATE|email|A user with this email already exists.',
    });
    expect(e).toBeInstanceOf(AppError);
    expect(e).toMatchObject({
      status: 409,
      code: 'DUPLICATE',
      message: 'A user with this email already exists.',
      details: [{ field: 'email' }],
    });
  });

  test('an unknown procedure code becomes a 422 business rule violation', () => {
    expect(fromDbError({ sqlState: '45000', sqlMessage: 'SOMETHING_NEW||Text' })).toMatchObject({
      status: 422,
      code: 'BUSINESS_RULE_VIOLATION',
    });
  });

  test.each([
    [{ errno: 1062 }, 409, 'DUPLICATE'],
    [{ errno: 1451 }, 409, 'CONFLICT'],
    [{ errno: 1452 }, 422, 'VALIDATION_FAILED'],
    [{ errno: 3819 }, 422, 'VALIDATION_FAILED'],
    [{ errno: 1213 }, 503, 'SERVICE_UNAVAILABLE'],
    [{ code: 'ECONNREFUSED' }, 503, 'SERVICE_UNAVAILABLE'],
  ])('%j -> %i %s', (err, status, code) => {
    expect(fromDbError(err)).toMatchObject({ status, code });
  });

  test('anything else is not a known database condition', () => {
    expect(fromDbError(new Error('boom'))).toBeNull();
  });
});

describe('email rendering', () => {
  test('HTML values are escaped; subjects lose line breaks', () => {
    expect(render('<p>Hi {{ fullName }}</p>', { fullName: '<b>Eve</b> & co' }, true)).toBe(
      '<p>Hi &lt;b&gt;Eve&lt;/b&gt; &amp; co</p>',
    );
    expect(render('Hello {{name}}', { name: 'A\r\nBcc: x@y.z' }, false)).toBe('Hello A Bcc: x@y.z');
    expect(render('{{missing}}!', {}, true)).toBe('!');
  });
});

describe('Excel export safety (17.5)', () => {
  test.each([
    ['=HYPERLINK("http://x")', `'=HYPERLINK("http://x")`],
    ['+1+1', "'+1+1"],
    ['-2', "'-2"],
    ['@SUM(A1)', "'@SUM(A1)"],
    ['plain', 'plain'],
    [null, ''],
  ])('%p -> %p', (input, out) => {
    expect(safeCell(input)).toBe(out);
  });

  test('objects are written as JSON text', () => {
    expect(safeCell({ a: 1 })).toBe('{"a":1}');
  });
});

describe('configuration guard (17.11, 22.3)', () => {
  test('production refuses development values', () => {
    const script = "require('./src/config')";
    let message = '';
    try {
      execFileSync(process.execPath, ['-e', script], {
        cwd: path.join(__dirname, '..', '..'),
        env: {
          ...process.env,
          DOTENV_PATH: path.join(__dirname, '..', '..', '.env.test'),
          NODE_ENV: 'production',
          SWAGGER_ENABLED: 'true',
          REFRESH_COOKIE_SECURE: 'false',
          MAIL_TRANSPORT: 'file',
        },
        stdio: 'pipe',
      });
    } catch (err) {
      message = err.stderr.toString();
    }
    expect(message).toContain('REFRESH_COOKIE_SECURE must be true');
    expect(message).toContain('MAIL_TRANSPORT must be smtp');
    expect(message).toContain('SWAGGER_ENABLED must be false');
    expect(message).toContain('UI_BASE_URL must use https');
  });

  test('a short signing secret is refused', () => {
    let message = '';
    try {
      execFileSync(process.execPath, ['-e', "require('./src/config')"], {
        cwd: path.join(__dirname, '..', '..'),
        env: {
          ...process.env,
          DOTENV_PATH: path.join(__dirname, '..', '..', '.env.test'),
          CRM_ACCESS_TOKEN_SECRET_CURRENT: 'too-short',
        },
        stdio: 'pipe',
      });
    } catch (err) {
      message = err.stderr.toString();
    }
    expect(message).toContain('CRM_ACCESS_TOKEN_SECRET_CURRENT: must be at least 64 characters');
  });
});
