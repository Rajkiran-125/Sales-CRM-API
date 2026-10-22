// @ts-check
'use strict';

/**
 * In-process scheduler (8.10): started only when SCHEDULER_ENABLED=true. Every minute each job
 * runs when its latest scheduled moment has passed and no successful run started after it
 * (so a restart catches up), within the job's catch-up window. A job_lock row stops double
 * runs across instances; every run is written to job_run_log.
 */
const os = require('os');
const { callProcedure, callProcedureOne } = require('../db/pool');
const logger = require('../config/logger');

/**
 * @typedef {{ mondayReportTime: string, weeklyStatusDueDay?: string }} JobSettings
 * @typedef {object} Job
 * @property {string} name
 * @property {number} catchUpHours  a missed run older than this is skipped until the next period
 * @property {(now: Date, settings: JobSettings) => Date} scheduledAt  latest scheduled moment of the current period
 * @property {(now: Date) => Promise<number>} run  returns the processed count
 */

/** @type {Job[]} */
const JOBS = [
  require('./weeklyStatusTasks.job'),
  require('./mondayReport.job'),
  require('./staleDeals.job'),
  require('./closeDateSlip.job'),
  require('./partnerPerformance.job'),
  ...require('./moreJobs').MORE_JOBS,
];

const HOLDER = `${os.hostname()}:${process.pid}`.slice(0, 100);
const LOCK_MINUTES = 30;

/**
 * Run one job now under its lock; never throws.
 * @param {Job} job
 * @param {Date} [now]
 * @returns {Promise<{ status: 'SUCCESS' | 'FAILED' | 'LOCKED', processed: number, error?: string }>}
 */
async function runJob(job, now = new Date()) {
  const lock = await callProcedureOne('sp_job_lock_acquire', [job.name, HOLDER, LOCK_MINUTES]);
  if (!Number(lock?.acquired)) return { status: 'LOCKED', processed: 0 };
  const runRow = await callProcedureOne('sp_job_run_start', [job.name]);
  try {
    const processed = await job.run(now);
    await callProcedure('sp_job_run_finish', [runRow?.id, 'SUCCESS', processed, null]);
    logger.info(`Job ${job.name}: ${processed} processed`);
    return { status: 'SUCCESS', processed };
  } catch (err) {
    const error = String(/** @type {Error} */ (err).message).slice(0, 2000);
    await callProcedure('sp_job_run_finish', [runRow?.id, 'FAILED', 0, error]);
    logger.error(`Job ${job.name} failed: ${error}`);
    return { status: 'FAILED', processed: 0, error };
  } finally {
    await callProcedure('sp_job_lock_release', [job.name, HOLDER]);
  }
}

/**
 * Should the job run now? Pure, for tests.
 * @param {Date} now
 * @param {Date} scheduledAt
 * @param {Date | null} lastSuccessAt
 * @param {number} catchUpHours
 */
function isDue(now, scheduledAt, lastSuccessAt, catchUpHours) {
  if (now < scheduledAt) return false;
  if (now.getTime() - scheduledAt.getTime() > catchUpHours * 3600000) return false;
  return !lastSuccessAt || lastSuccessAt < scheduledAt;
}

/** One scheduler pass over all jobs. @param {Date} [now] */
async function tick(now = new Date()) {
  const settings = /** @type {JobSettings} */ (await callProcedureOne('sp_job_settings', []));
  for (const job of JOBS) {
    try {
      const last = await callProcedureOne('sp_job_last_success', [job.name]);
      const lastAt = last?.lastSuccessAt ? new Date(last.lastSuccessAt) : null;
      if (isDue(now, job.scheduledAt(now, settings), lastAt, job.catchUpHours))
        await runJob(job, now);
    } catch (err) {
      logger.error(`Scheduler check for ${job.name} failed: ${/** @type {Error} */ (err).message}`);
    }
  }
}

/** @type {NodeJS.Timeout | null} */
let timer = null;
let running = Promise.resolve();

function start() {
  if (timer) return;
  logger.info(`Scheduler started (${JOBS.map((j) => j.name).join(', ')})`);
  const pass = () => {
    running = tick().catch((err) => {
      logger.error(`Scheduler tick failed: ${err.message}`);
    });
  };
  timer = setInterval(pass, 60000);
  timer.unref();
  pass();
}

/** Stop ticking and wait for a pass in progress (graceful shutdown). */
async function stop() {
  if (timer) clearInterval(timer);
  timer = null;
  await running;
}

module.exports = { JOBS, runJob, isDue, tick, start, stop };
