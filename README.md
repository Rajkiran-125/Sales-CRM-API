# Sales CRM API

The Node.js REST API of the Cnergee Sales CRM: Express 5, MySQL 8.4 stored procedures, its own authentication and RBAC.

## Setup (development)

1. Node 24.21 or later (see `.nvmrc`), and MySQL 8.4.
2. Prepare the database: follow `db/README.md`. The schema `unigr8ways_sales_crm` and your MySQL account already exist. Run `db/scripts/V001…V042` by hand, in order (for example in DBeaver). The scripts create no database, account or grant.
3. `cp .env.example .env`, then fill in `DB_HOST`, `DB_PORT`, `DB_USER` and `DB_PASSWORD` of your existing MySQL account, and the JWT secret (`npm run generate:jwt-secret`).
4. `npm install`
5. Create the first CRM Admin: `npm run bootstrap:admin -- --email you@cnergee.com --name "Your Name"`. Open the printed link (through the UI) to set the password.
6. `npm run dev`. The API listens on `http://localhost:4100`. Swagger UI is at `http://localhost:4100/api-docs`.

Background jobs (weekly status tasks on Monday 06:00 IST, the Monday report at `report.monday.time`, stale deals and close-date slip daily at 06:00 IST) run only when `SCHEDULER_ENABLED=true`, on exactly one API instance. Run one by hand with `npm run job -- <weekly-status-tasks | monday-report | stale-deals | close-date-slip>`; every run is logged in `job_run_log`.

For a demo database only: `npm run seed:demo` loads a 20-person sales team (all seven roles, a reporting hierarchy, one invited, one locked and one deactivated user) and a few extra master entries, through the same procedures as the app. Every demo user signs in with `Demo-Team-2026!` (change it with `-- --password "<password>"`). It is safe to re-run and refuses to run in production. Then run `db/demo/demo_sales_data.sql` by hand to fill the dashboard with demo deals (see `db/README.md`).

Until SMTP is configured (OD-17), emails are written to `var/mail/` as `.json` and `.html` (invitations, resets, lock notices).

## Tests

`npm test` runs the unit tests and the API tests. The API tests rebuild `sales_crm_test` from `db/scripts`, and need the test-only migration credentials in `.env.test`.

## Endpoints (`/api/v1`)

| Area            | Endpoints                                                                                                                                                                                                                                                                    |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Auth            | `POST auth/login`, `auth/refresh`, `auth/logout`, `auth/logout-all`, `GET auth/me`, `POST auth/password/change`, `auth/password/forgot`, `auth/password/reset/check`, `auth/password/reset`, `auth/invitations/check`, `auth/invitations/accept`, `GET/DELETE auth/sessions` |
| Users           | `GET users`, `GET users/lookup`, `GET/PATCH users/:id`, `POST users`, `POST users/:id/status`, `…/unlock`, `…/password-reset`, `…/invitation`, `…/sessions/revoke`                                                                                                           |
| Roles           | `GET/POST roles`, `GET/PATCH roles/:id`, `GET permissions`                                                                                                                                                                                                                   |
| Audit           | `GET audit-logs` (+ `/export`), `GET security-events` (+ `/export`), `GET record-access-logs`                                                                                                                                                                                |
| Masters         | `GET masters`, `GET/POST masters/{type}`, `PATCH masters/{type}/:id`. Types: partner types, industries, products, solutions, reasons, competitors, procurement types / steps, document types, certification types, stages                                                    |
| Settings        | `GET/PATCH settings`                                                                                                                                                                                                                                                         |
| Email templates | `GET email-templates`, `GET/PATCH email-templates/:code`, `POST email-templates/:code/test`                                                                                                                                                                                  |
| Dashboard       | `GET dashboard` (every tile in one call; filters: fiscal year / quarter, source, product, industry, owner with team, partner), `GET dashboard/drill/{tile}` (the deals behind a tile, paged). Built ahead of Phase 1 (D-23)                                                  |
| Leads           | `GET leads`, `GET leads/lookup`, `GET leads/:id`, `POST leads`, `PATCH leads/:id`, `POST leads/:id/stage`, `POST leads/:id/convert`                                                                                                                                          |
| Opportunities   | `GET opportunities`, `GET opportunities/kanban`, `GET opportunities/:id`, `PATCH opportunities/:id`, `POST opportunities/:id/stage`, `POST opportunities/:id/validate`, `POST opportunities/:id/close`                                                                       |
| Accounts        | `GET accounts`, `GET accounts/:id` (360° view)                                                                                                                                                                                                                               |
| Forecast        | `GET forecast/weekly`, `GET forecast/monthly`, `GET forecast/hierarchy`                                                                                                                                                                                                      |
| Activities      | `GET activities`, `POST activities`, `PATCH activities/:id`, `DELETE activities/:id`                                                                                                                                                                                         |
| Tasks           | `GET tasks`, `GET tasks/my-day`, `POST tasks`, `PATCH tasks/:id`                                                                                                                                                                                                             |
| Weekly status   | `GET weekly-status/:opportunityId`, `PUT weekly-status/:opportunityId`, `DELETE weekly-status/:opportunityId/:week`                                                                                                                                                          |
| Contacts        | `POST contacts`, `PATCH contacts/:id`, `POST contacts/:id/deactivate`                                                                                                                                                                                                        |
| Offers          | `GET opportunities/:id/offers`, `GET offers/:id`, `POST opportunities/:id/offers`, `POST offers/:id/submit`, `POST offers/:id/approve`, `POST offers/:id/send`, `POST offers/:id/respond`, `POST offers/:id/revise`                                                          |
| Partners        | `GET partners`, `GET partners/:id`, `GET partners/:id/performance`, `GET partners/:id/scorecard`                                                                                                                                                                             |
| Tenders         | `GET tenders`, `GET tenders/:id`                                                                                                                                                                                                                                             |
| Orders          | `GET orders`, `GET orders/:id` (workspace: track, invoices, payments, BR-OR-05 partner-release check)                                                                                                                                                                        |
| Win / loss      | `GET win-loss/summary` (kpis, trend, reasons, lessons), `GET win-loss/deals`                                                                                                                                                                                                 |
| Documents       | `GET documents` (search by text, tag, entity type)                                                                                                                                                                                                                           |
| Reports         | `GET reports/REVENUE_GM` (by dimension: partner / source / product / industry / owner), `GET reports/PRODUCT_MIX`                                                                                                                                                            |
| Health          | `GET health`, `GET health/ready`                                                                                                                                                                                                                                             |

See `CLAUDE.md` for the conventions, and `docs/decision-log.md` for the decisions.
