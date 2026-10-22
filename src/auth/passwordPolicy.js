// @ts-check
'use strict';

/**
 * Password policy (OD-08 default): at least 10 characters with 3 of 4 character classes,
 * or a passphrase of 14+ characters; at most 128; must not contain the email name or the
 * user's name; must not be a common password. Reuse of the current or recent passwords is
 * checked by the auth service against the hashes returned by sp_auth_password_hashes.
 */

const COMMON = new Set(
  [
    'password',
    'password1',
    'password12',
    'password123',
    'password1234',
    'passw0rd',
    'p@ssw0rd',
    'p@ssword',
    '12345678',
    '123456789',
    '1234567890',
    '12345678910',
    'qwerty123',
    'qwertyuiop',
    'qwerty1234',
    '1q2w3e4r5t',
    '1qaz2wsx3edc',
    'iloveyou',
    'welcome',
    'welcome1',
    'welcome123',
    'welcome@123',
    'admin123',
    'admin@123',
    'administrator',
    'letmein',
    'letmein123',
    'abc12345',
    'abcd1234',
    'abcdefgh',
    'monkey123',
    'dragon123',
    'football',
    'baseball',
    'sunshine',
    'princess',
    'superman',
    'trustno1',
    'changeme',
    'changeme123',
    'india@123',
    'india123',
    'cnergee',
    'cnergee123',
    'cnergee@123',
    'salescrm',
    'salescrm123',
    'sales@123',
    'crm@1234',
    'zaq12wsx',
    'asdfghjkl',
    'asdf1234',
    'test1234',
    'test@123',
    'default123',
    'secret123',
  ].map((p) => p.toLowerCase()),
);

/**
 * @param {string} password
 * @param {{ email?: string | null, fullName?: string | null }} [user]
 * @returns {string[]} problems (empty when the password is acceptable)
 */
function checkPasswordPolicy(password, user = {}) {
  const problems = [];
  const pw = String(password || '');
  const lower = pw.toLowerCase();

  if (pw.length > 128) problems.push('Use at most 128 characters.');

  const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter((r) => r.test(pw)).length;
  const strongShort = pw.length >= 10 && classes >= 3;
  const passphrase = pw.length >= 14;
  if (!strongShort && !passphrase) {
    problems.push(
      'Use at least 10 characters with 3 of: lower-case, upper-case, digits, symbols - or a passphrase of 14 or more characters.',
    );
  }

  if (COMMON.has(lower) || COMMON.has(lower.replace(/[^a-z0-9@]/g, ''))) {
    problems.push('This password is too common.');
  }

  const parts = [];
  if (user.email) parts.push(user.email.split('@')[0]);
  if (user.fullName) parts.push(...user.fullName.split(/\s+/));
  const personal = parts.map((p) => p.toLowerCase().trim()).filter((p) => p.length >= 3);
  if (personal.some((p) => lower.includes(p))) {
    problems.push('Do not use your name or email in the password.');
  }

  return problems;
}

module.exports = { checkPasswordPolicy };
