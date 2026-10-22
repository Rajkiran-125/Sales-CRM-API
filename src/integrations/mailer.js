// @ts-check
'use strict';

/**
 * Mailer adapter (8.11). Templates come from the email_template table; values are
 * HTML-escaped into the body and stripped of line breaks in the subject. Every email is
 * recorded in email_log. Sending happens after the business transaction and never makes
 * it fail: errors are logged and the email is marked FAILED (20.5).
 *
 * MAIL_TRANSPORT=file (development until OD-17 is decided) writes each email to
 * MAIL_FILE_DIR as .json and .html; production requires smtp (config check).
 */
const fs = require('fs/promises');
const path = require('path');
const nodemailer = require('nodemailer');
const config = require('../config');
const logger = require('../config/logger');
const { callProcedure, callProcedureOne } = require('../db/pool');

/** @typedef {import('nodemailer/lib/mailer').Attachment} Attachment */

const RETRY_DELAYS_MS = config.isTest ? [0, 0, 0] : [0, 2000, 10000];

const transport =
  config.mail.transport === 'smtp'
    ? nodemailer.createTransport({
        host: config.mail.smtp.host,
        port: config.mail.smtp.port,
        secure: config.mail.smtp.secure,
        auth: config.mail.smtp.user
          ? { user: config.mail.smtp.user, pass: config.mail.smtp.password }
          : undefined,
      })
    : nodemailer.createTransport({ jsonTransport: true });

/** @type {Set<Promise<void>>} */
const pending = new Set();

/** @param {string} s */
function escapeHtml(s) {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * @param {string} template
 * @param {Record<string, string | number>} values
 * @param {boolean} html
 */
function render(template, values, html) {
  return template.replace(/\{\{\s*([A-Za-z][A-Za-z0-9]*)\s*\}\}/g, (_m, name) => {
    const raw = values[name] === undefined || values[name] === null ? '' : String(values[name]);
    return html ? escapeHtml(raw) : raw.replace(/[\r\n]+/g, ' ');
  });
}

/** @param {string} html */
function htmlToText(html) {
  return html
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n\n')
    .replace(/<a [^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/gi, '$2 ($1)')
    .replace(/<[^>]+>/g, '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .trim();
}

/** @param {number} ms */
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * @param {{ to: string, subject: string, html: string, text: string, code: string, attachments?: Attachment[] }} msg
 */
async function deliver(msg) {
  const info = await transport.sendMail({
    from: config.mail.from,
    to: msg.to,
    subject: msg.subject,
    html: msg.html,
    text: msg.text,
    attachments: msg.attachments,
  });
  if (config.mail.transport === 'file') {
    await fs.mkdir(config.mail.fileDir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const safeTo = msg.to.replace(/[^A-Za-z0-9@._-]/g, '_');
    const base = path.join(config.mail.fileDir, `${stamp}_${msg.code}_${safeTo}`);
    await fs.writeFile(`${base}.json`, String(/** @type {any} */ (info).message), 'utf8');
    await fs.writeFile(`${base}.html`, msg.html, 'utf8');
  }
}

/**
 * Render and send a template email. Returns once the attempts are finished; never throws.
 * @param {string} code    email_template.code
 * @param {string} to
 * @param {Record<string, string | number>} values  placeholder values (appName is added)
 * @param {{ entityType?: string, entityId?: number, attachments?: Attachment[] }} [ref]
 */
async function sendTemplate(code, to, values, ref = {}) {
  let attempts = 0;
  try {
    const template = await callProcedureOne('sp_template_get_for_send', [code]);
    if (!template) {
      logger.error(`Email template ${code} is missing or inactive`);
      return;
    }
    const vars = { appName: config.appName, ...values };
    const subject = render(template.subject, vars, false);
    const html = render(template.bodyHtml, vars, true);
    const logRow = await callProcedureOne('sp_email_log_create', [
      code,
      to,
      subject,
      ref.entityType ?? null,
      ref.entityId ?? null,
    ]);
    const logId = logRow ? Number(logRow.id) : null;

    let lastError = null;
    for (const delay of RETRY_DELAYS_MS) {
      if (delay) await sleep(delay);
      attempts += 1;
      try {
        await deliver({
          to,
          subject,
          html,
          text: htmlToText(html),
          code,
          attachments: ref.attachments,
        });
        lastError = null;
        break;
      } catch (err) {
        lastError = err;
        logger.warn(
          `Email ${code} attempt ${attempts} failed: ${/** @type {Error} */ (err).message}`,
        );
      }
    }

    if (logId !== null) {
      await callProcedure('sp_email_log_update', [
        logId,
        lastError ? 'FAILED' : 'SENT',
        lastError ? String(/** @type {Error} */ (lastError).message).slice(0, 1000) : null,
        attempts,
      ]);
    }
  } catch (err) {
    logger.error(`Email ${code} could not be processed: ${/** @type {Error} */ (err).message}`);
  }
}

/**
 * Fire-and-forget send (after the business transaction); tracked so tests and graceful
 * shutdown can wait for it.
 * @param {Parameters<typeof sendTemplate>} args
 */
function queueTemplate(...args) {
  const p = sendTemplate(...args).finally(() => pending.delete(p));
  pending.add(p);
}

/** Wait for every queued email. */
async function flush() {
  await Promise.all([...pending]);
}

module.exports = { sendTemplate, queueTemplate, flush, render, escapeHtml };
