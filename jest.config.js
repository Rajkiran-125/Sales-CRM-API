'use strict';

/** Two test projects (21.1): unit (no database) and api (rebuilds sales_crm_test first). */
module.exports = {
  testSequencer: '<rootDir>/test/setup/alphabeticalSequencer.js',
  projects: [
    {
      displayName: 'unit',
      testEnvironment: 'node',
      testMatch: ['<rootDir>/test/unit/**/*.test.js'],
      setupFiles: ['<rootDir>/test/setup/env.js'],
    },
    {
      displayName: 'api',
      testEnvironment: 'node',
      testMatch: ['<rootDir>/test/api/**/*.test.js'],
      setupFiles: ['<rootDir>/test/setup/env.js'],
      globalSetup: '<rootDir>/test/setup/globalSetup.js',
    },
  ],
  testTimeout: 30000,
};
