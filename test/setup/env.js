'use strict';

/** Every test process loads .env.test (sales_crm_test, test mail folder, relaxed rate limits). */
const path = require('path');

process.env.DOTENV_PATH = path.join(__dirname, '..', '..', '.env.test');
process.env.NODE_ENV = 'test';
