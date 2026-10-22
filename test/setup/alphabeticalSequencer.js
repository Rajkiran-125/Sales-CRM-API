'use strict';

const Sequencer = require('@jest/test-sequencer').default;

/**
 * Sorts test files strictly by path so the run order is always alphabetical and
 * never reordered based on previous failure history. This keeps data dependencies
 * between test suites predictable (e.g. dashboard must run before leads-write).
 */
class AlphabeticalSequencer extends Sequencer {
  sort(tests) {
    return [...tests].sort((a, b) => a.path.localeCompare(b.path));
  }
}

module.exports = AlphabeticalSequencer;
