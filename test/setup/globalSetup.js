'use strict';

/**
 * Rebuild sales_crm_test from the same numbered scripts a DBA runs by hand (db/scripts),
 * so every API test run also proves the scripts. Never touches unigr8ways_sales_crm: each
 * script's `USE <schema>;` line is rewritten to the test schema before it runs.
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

module.exports = async function globalSetup() {
  const root = path.join(__dirname, '..', '..');
  require('dotenv').config({ path: path.join(root, '.env.test'), quiet: true });

  const schema = process.env.DB_NAME;
  if (schema !== 'sales_crm_test')
    throw new Error(`Refusing to rebuild "${schema}": only sales_crm_test`);

  const cli = process.env.TEST_MYSQL_CLI;
  const base = [
    '-h',
    process.env.DB_HOST,
    '-P',
    String(process.env.DB_PORT || 3306),
    '-u',
    process.env.TEST_DB_MIGRATOR_USER,
  ];
  const env = { ...process.env, MYSQL_PWD: process.env.TEST_DB_MIGRATOR_PASSWORD };

  execFileSync(
    cli,
    [
      ...base,
      '-e',
      `DROP DATABASE IF EXISTS ${schema}; CREATE DATABASE ${schema} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;`,
    ],
    { env, stdio: 'pipe' },
  );

  const dir = path.join(root, 'db', 'scripts');
  const scripts = fs
    .readdirSync(dir)
    .filter((f) => /^V\d{3}__.+\.sql$/.test(f))
    .sort();
  for (const file of scripts) {
    try {
      execFileSync(cli, [...base, schema], {
        env,
        input: fs
          .readFileSync(path.join(dir, file), 'utf8')
          .replace(/^USE\s+\S+\s*;/gim, `USE ${schema};`),
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch (err) {
      throw new Error(`${file} failed: ${err.stderr ? err.stderr.toString() : err.message}`, {
        cause: err,
      });
    }
  }

  fs.rmSync(path.join(root, process.env.MAIL_FILE_DIR || 'var/test-mail'), {
    recursive: true,
    force: true,
  });
  fs.rmSync(path.join(root, process.env.FILE_DIR || 'var/test-files'), {
    recursive: true,
    force: true,
  });
};
