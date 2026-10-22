# CLAUDE.md: Sales CRM API

This file guides AI assistants and developers working in this repository.

## What this is

The Node.js REST API of the **Cnergee Sales CRM**: a standalone application (Angular UI → this API → its own MySQL database). The specification is the tech doc v2.1 (`01_Sales_CRM_Technical_Development_Document_Updated.md`) together with the User Manual (`02_…`). Read `docs/decision-log.md` first: it records where the build departs from the doc.

**The Orchestrator (UniGr8Ways `ugwebapplicationapi` / `unigr8ways_project_stack`) is a reference only (tech doc 4.5):**

- never call it
- never share its login, tokens, secrets, issuer, audience, cookie names or Redis
- never read its tables
- never import its files or configuration

Copying a pattern means re-writing it here.

## Architecture (decision D-02)

- **Business rules live in MySQL stored procedures** (`db/scripts/V###__*.sql`). Examples: gates, lockout, rotation, ownership, audit and history.
- Node.js does only what MySQL cannot do, or what belongs to HTTP:
  - routing and the permission check on every route
  - request-shape validation (zod)
  - Argon2id hashing, JWT signing, random tokens, the password policy
  - email, Excel and PDF adapters
- The DB application account should have **EXECUTE only** (D-11; the scripts create no account, D-22). Every data access is `CALL sp_x(?, …)` through `src/db/pool.js` `callProcedure()`. Never use string-built SQL or direct table access.
- Procedure errors use `SIGNAL SQLSTATE '45000'` with the message `CODE|field|message`. `src/shared/errors.js` maps them to the HTTP status of tech doc 8.7.
- Layers per module (`src/modules/<module>/`):
  - `*.routes.js`: a declarative route table where every route states its `access`
  - `*.controller.js`: HTTP only
  - `*.service.js`: crypto, merging partial updates, emails after commit
  - `*.repository.js`: thin wrappers around the procedures
  - `*.validation.js`: zod request schemas

## Commands

```bash
npm install
npm run dev            # nodemon src/server.js (port 4100, .env → unigr8ways_sales_crm)
npm test               # unit + API tests; the API tests rebuild sales_crm_test from db/scripts
npm run test:unit      # no database needed
npm run lint && npm run format:check && npm run typecheck
npm run check          # all of the above
npm run bootstrap:admin -- --email <email> --name "<name>"   # first CRM Admin, prints an invitation link
npm run generate:jwt-secret
```

- Node 24 (`.nvmrc`), Express 5 (async handlers forward rejections automatically).
- Swagger UI: `/api-docs` (OpenAPI generated from the route tables; never in production).
- Health: `GET /api/v1/health` (public), `GET /api/v1/health/ready` (internal network only).

## Rules

- **Every route declares its access** in its route table: `'public'`, `'authenticated'` or a list of permission codes. `test/api/platform.test.js` fails when a route has none, or when a new route is public or authenticated-only without being added to the reviewed allow-list.
- A new rule or endpoint ships with tests (tech doc 21). Business behaviour belongs in a new or changed `V###` script. **Never edit an applied script.** Add the next number instead (D-05; DBAs run the scripts by hand).
- Every `V###` script starts with `USE unigr8ways_sales_crm;` and never creates a database, account or grant (D-22). The test setup rewrites that line to `sales_crm_test`.
- `db/demo/` and `npm run seed:demo` are for demo databases only (D-26): never part of `db/scripts`, never run by the tests, never on a live database.
- Validate every input with a strict zod schema (unknown fields are rejected). Controllers read only `req.valid`.
- Never trust role, permission or scope data from the request. `req.user` comes from `loadUserContext`.
- Never log passwords, tokens, reset links or auth request bodies. The request logger logs the path without the query string.
- Configuration comes only from environment variables (`src/config/index.js` validates it and refuses production with development values). `.env*` files are git-ignored, except `.env.example`.
- `'use strict'` and `// @ts-check` in every file, JSDoc types, Prettier (`printWidth` 100, single quotes), ESLint.
- Every response uses the tech doc 8.8 envelope (`src/shared/response.js`). Errors go through `AppError`.
- Emails are sent after the procedure commits (`mailer.queueTemplate`), and a failure never fails the business action.
