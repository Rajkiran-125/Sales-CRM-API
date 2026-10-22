'use strict';

/** Scheduler timing (8.10): IST weeks and catch-up after downtime. */
const { isDue } = require('../../src/jobs/scheduler');
const { istDate, istMonday, istAt, addDays } = require('../../src/jobs/time');

describe('IST calendar', () => {
  test('Sunday 20:00 UTC is already Monday in IST', () => {
    const now = new Date('2026-10-18T20:00:00Z'); // Mon 19 Oct 01:30 IST
    expect(istDate(now)).toBe('2026-10-19');
    expect(istMonday(now)).toBe('2026-10-19');
  });

  test('the Monday of a Sunday (IST) is six days earlier', () => {
    expect(istMonday(new Date('2026-10-18T10:00:00Z'))).toBe('2026-10-12');
    expect(addDays('2026-10-12', -7)).toBe('2026-10-05');
  });

  test('istAt is the IST wall-clock time', () => {
    expect(istAt('2026-10-19', '09:00').toISOString()).toBe('2026-10-19T03:30:00.000Z');
  });
});

describe('isDue', () => {
  const at = new Date('2026-10-19T03:30:00Z');
  const h = (n) => new Date(at.getTime() + n * 3600000);

  test('not before the scheduled moment', () => {
    expect(isDue(h(-1), at, null, 24)).toBe(false);
  });

  test('due once: not again after a successful run started after it', () => {
    expect(isDue(h(1), at, null, 24)).toBe(true);
    expect(isDue(h(1), at, h(-168), 24)).toBe(true);
    expect(isDue(h(2), at, h(0.5), 24)).toBe(false);
  });

  test('a missed run is caught up only inside the window', () => {
    expect(isDue(h(11), at, null, 12)).toBe(true);
    expect(isDue(h(13), at, null, 12)).toBe(false);
  });
});
