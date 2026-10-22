// @ts-check
'use strict';

/** IST calendar helpers for the scheduler (OD-28: store UTC, business days in IST). */

const IST_MS = 330 * 60000;

/** The IST calendar date of an instant, as YYYY-MM-DD. @param {Date} now */
const istDate = (now) => new Date(now.getTime() + IST_MS).toISOString().slice(0, 10);

/** @param {string} date YYYY-MM-DD @param {number} days */
const addDays = (date, days) =>
  new Date(Date.parse(`${date}T00:00:00Z`) + days * 86400000).toISOString().slice(0, 10);

/** The Monday of the IST week containing `now`, as YYYY-MM-DD. @param {Date} now */
function istMonday(now) {
  const date = istDate(now);
  const weekday = (new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7; // Monday = 0
  return addDays(date, -weekday);
}

/** The instant of an IST date and HH:MM time. @param {string} date @param {string} hhmm */
const istAt = (date, hhmm) => new Date(`${date}T${hhmm.slice(0, 5)}:00+05:30`);

module.exports = { istDate, addDays, istMonday, istAt };
