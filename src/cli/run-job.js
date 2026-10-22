// @ts-check
'use strict';

/**
 * Run one scheduler job now, whatever its schedule (still under its job_lock, logged in
 * job_run_log). For checks and catch-up by an operator.
 *
 *   npm run job -- weekly-status-tasks | monday-report | stale-deals | close-date-slip
 */
const db = require('../db/pool');
const mailer = require('../integrations/mailer');
const { JOBS, runJob } = require('../jobs/scheduler');

async function main() {
  const job = JOBS.find((j) => j.name === process.argv[2]);
  if (!job) {
    console.error(`Usage: npm run job -- <${JOBS.map((j) => j.name).join(' | ')}>`);
    process.exitCode = 2;
    return;
  }
  try {
    const result = await runJob(job);
    console.log(`${job.name}: ${result.status}, ${result.processed} processed`);
    if (result.error) console.error(result.error);
    if (result.status !== 'SUCCESS') process.exitCode = 1;
  } finally {
    await mailer.flush();
    await db.close();
  }
}

main();
