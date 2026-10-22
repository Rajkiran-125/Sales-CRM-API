# Sales CRM database scripts

The database is changed **only** by the numbered scripts in `scripts/`. They are run by hand, in order, under the existing MySQL account that owns the schema.
Each script records itself in the `schema_version` table.

The scripts work **only inside `unigr8ways_sales_crm`**. Each one starts with `USE unigr8ways_sales_crm;` and stops with "Unknown database" when that schema is missing.
They never create a database, an account or a grant. The schema and the account are created beforehand, outside these scripts.

| Script | Contents | Re-runnable |
|---|---|---|
| `V001__schema.sql` | All 79 tables of the version 1 data model (tech doc section 15) | **No** (run once, on the empty schema) |
| `V002__seed_reference_data.sql` | Permission catalogue, 7 system roles with the permission matrix, stages, masters, settings, email templates | Yes (`INSERT IGNORE`, never overwrites admin edits) |
| `V003__sp_core.sql` | Shared helpers: errors, audit, security events, settings, number sequences, reporting tree, data scope | Yes |
| `V004__sp_auth.sql` | Login, lockout, refresh-token rotation, logout, sessions, password change / reset / invitation | Yes |
| `V005__sp_admin.sql` | Users, roles, permissions, audit-log readers, first-admin bootstrap | Yes |
| `V006__sp_masters.sql` | Masters, stages, settings, email templates | Yes |
| `V007__sp_dashboard.sql` | Management dashboard v1: every tile and the drill-down, read-only, inside each user's data scope | Yes |
| `V008__sp_sales_views.sql` | Read-side for sales: leads, opportunities, accounts, forecast (weekly / monthly / hierarchy), tasks (my day and list) | Yes |
| `V009__sp_partner_views.sql` | Read-side for partners and tenders: partner list, workspace, performance scorecard, tender list and detail | Yes |
| `V010__sp_order_views.sql` | Read-side for orders and analysis: order list, order workspace (track / invoices / payments / BR-OR-05), win/loss summary and closed deals, document search, and two catalogue reports (revenue + GM, product mix) | Yes |
| `V011__sp_lead_write.sql` | Lead create and update | Yes |
| `V012__sp_lead_write2.sql` | Lead move-stage and convert-to-opportunity | Yes |
| `V013__sp_opportunity_write.sql` | Opportunity update, move-stage, validate and close | Yes |
| `V014__sp_activity_write.sql` | Activity create, update and delete (Sprint 1, Phase 1) | Yes |
| `V015__sp_weekly_status_write.sql` | Weekly deal-status upsert and delete (Sprint 2, Phase 1) | Yes |
| `V016__sp_task_write.sql` | Manual task create and update (Sprint 3, Phase 1) | Yes |
| `V017__sp_dmu_write.sql` | Contact create / update / deactivate, opportunity DMU upsert and remove (Sprint 4, Phase 1) | Yes |
| `V018__sp_offer_write.sql` | Offer lifecycle: create → submit → approve → send → accept / reject / revise (Sprint 5, Phase 1) | Yes |
| `V019__sp_order_write.sql` | Order created on WON; order events, invoices, payments, finance fields (Sprint 6, Phase 1) | Yes |
| `V020__sp_account_write.sql` | Account create / update with duplicate check by name, GST, website; `sp_account_get` adds the edit fields (accounts write, Phase 1) | Yes |
| `V021__sp_lead_dmu_write.sql` | Lead DMU add / edit / remove (qualification fact 4); `sp_lead_convert` re-issued to copy the lead DMU onto the new deal (Phase 1) | Yes |
| `V022__sp_deal_partner_write.sql` | Partners on deals (one primary, contact of that partner), competitors, partner commercial versions; `sp_opportunity_get` adds the edit ids (Phase 1) | Yes |
| `V023__sp_document_write.sql` | Document upload metadata, download lookup, soft delete; limits from settings (17.9). Files live in the API `FILE_DIR` (Phase 1) | Yes |
| `V024__sp_lead_convert_account.sql` | `sp_lead_convert` re-issued: a "new account" lead is linked to an active account of that exact name, else the account is created (PROSPECT) at conversion (12.6) | Yes |
| `V025__sp_scheduler_jobs.sql` | Scheduler: job lock and run log, weekly status tasks, Monday report rows, stale deals, close-date slip; two email templates; `sp_weekly_status_upsert` re-issued to close that week's task (Phase 1) | Yes |
| `V026__sp_opportunity_gates_poc.sql` | Stage gates (16.3): gate check, one-step move-stage with override by permission and reason; POC get / save; WON only from CONTRACT_SIGNED; partial deal PATCH via `sp_opportunity_edit_values` (Phase 1) | Yes |
| `V027__sp_document_update.sql` | Edit the tags and notes of a document (`PATCH /documents/{id}`), audited (Phase 1) | Yes |
| `V028__sp_account_merge.sql` | Merge a duplicate account into a survivor: its records move, it is retired (`merged_into_account_id`), audited (Phase 1) | Yes |
| `V029__sp_offer_update.sql` | Edit the figures of a draft offer (`PATCH /offers/{id}`), approval need recomputed, audited (Phase 1) | Yes |
| `V030__sp_partner_write.sql` | Partner Master write: duplicate search with the owner, create with the minimum fields, per-section save, completeness (Phase 2) | Yes |
| `V031__sp_partner_engagement.sql` | Partner engagement log with the next-engagement task, 6-month account map (Phase 2) | Yes |
| `V032__sp_custom_fields.sql` | Custom fields: definitions, typed values per record, visibility (Phase 2) | Yes |
| `V033__sp_partner_performance.sql` | Partner score with the OD-42 weights (settings), quarter snapshots (open / frozen), recompute (Phase 2) | Yes |
| `V034__seed_quarterly_report.sql` | Document type QUARTERLY_REPORT for the Partner Quarterly Report PDF (Phase 2) | Yes |
| `V035__sp_winloss_competitor.sql` | Win / loss competitor filter on the summary and closed deals (Phase 2) | Yes |
| `V036__sp_import.sql` | Data import batches and rows (partners): preview, commit, IMPORTED audit (Phase 2) | Yes |
| `V037__sp_tender_write.sql` | Tenders write: create / edit, default checklist and readiness, status transitions (Phase 3) | Yes |
| `V038__sp_forecast_write.sql` | Monthly closure commits and the manager nudge (Phase 3) | Yes |
| `V039__sp_more_jobs.sql` | Remaining scheduler jobs: weekly status reminder, monthly close, wake-up, invoice due, engagement reminder, stage ageing digest, housekeeping; four email templates (Phase 3) | Yes |
| `V040__sp_dashboard_v2.sql` | Dashboard cycle times; targets list and save (Phase 3) | Yes |
| `V041__gate_offer_response.sql` | Proposal gate: an offer response counts without a remark | Yes |
| `V042__partner_onboarding_fields.sql` | Partner onboarding: email / phone / currency at create, duplicate confirmation, required address and industry, agreement and GTM plan documents, list values for the statuses, partner codes at customers; new columns employee strength, parent partner (hierarchy) and regions | Yes |

New scripts add the next `V###` number; small `ALTER` scripts follow the same convention. Each script starts with `USE unigr8ways_sales_crm;`.

## Running the scripts in DBeaver

Prerequisites (already in place):
- the schema `unigr8ways_sales_crm`
- your existing MySQL account, with full rights on that schema (tables, indexes, foreign keys, `CREATE ROUTINE`, `ALTER ROUTINE`, `EXECUTE`, `CREATE TEMPORARY TABLES`: the dashboard procedures use temporary tables)

For each file, `V001` to `V042` in order:

1. Open the file in a SQL editor on your MySQL connection.
2. Run the whole file with **Execute SQL Script** (`Alt+X`), not "Execute statement" (`Ctrl+Enter`). The `DELIMITER $$` lines are understood by DBeaver.
3. If an error dialog appears, choose **Stop** and fix the cause before going on.

You do not need to pick the default schema first: the `USE` line switches to `unigr8ways_sales_crm`.

With the `mysql` command-line client, it works the same way (no schema argument needed):

```bat
mysql -h <host> -P <port> -u <your_user> -p < V001__schema.sql
```

Then check:

```sql
SELECT version, applied_at, applied_by FROM unigr8ways_sales_crm.schema_version;  -- V001 … V042
SELECT COUNT(*) FROM information_schema.tables
 WHERE table_schema = 'unigr8ways_sales_crm' AND table_type = 'BASE TABLE';      -- 79
SELECT COUNT(*) FROM information_schema.routines
 WHERE routine_schema = 'unigr8ways_sales_crm';                                  -- 238
```

Finally, create the first CRM Admin from the API folder with `npm run bootstrap:admin -- --email <email> --name "<full name>"`. It prints a one-time invitation link (tech doc 11.5). No default password exists.

## Demo data (demo databases only)

The four demo SQL files fill the whole application for a demonstration. **Never run them on a live database.** Run them in this order:

1. Run `V001`–`V042` and create the first CRM Admin (above).
2. From the API folder, run `npm run seed:demo`: the 20-person demo team (`@cnergee.test` emails, password `Demo-Team-2026!`).
3. Run `demo/demo_sales_data.sql`: 15 accounts, 6 partners, 64 deals with weekly status, commitment, win/loss records, 10 leads and targets. Dates are relative to the day it runs. A second run stops with "Demo sales data is already loaded".
4. Run `demo/demo_sales_details.sql`: activities, tasks and weekly-status history for each deal.
5. Run `demo/demo_partners_tenders.sql`: partner-commercial records and tenders.
6. Run `demo/demo_orders_documents.sql`: sales orders, invoices, payments and documents.

Steps 3–6 use direct inserts (not the procedures), so the rows do not appear in the audit log (decision D-26).

## The account

- The account that runs the procedure scripts becomes their `DEFINER`, and the procedures run with its rights (`SQL SECURITY DEFINER`). If that account is renamed or dropped, every procedure stops working. Re-run `V003`–`V006` under the new account.
- The API connects with an account from `.env` (`DB_USER` / `DB_PASSWORD`). It can be the same account. The API only ever calls procedures (`CALL sp_x(?, …)`), but MySQL does not enforce that unless the account has `EXECUTE` only (decision D-22).

## Conventions used in the scripts

- `sp_<module>_<action>`: public procedures, called by the API as `CALL sp_x(?, ?, …)` with bound parameters.
- `spi_<name>`: internal helpers. Only public procedures start and commit transactions.
- Business errors are raised with `SIGNAL SQLSTATE '45000'`, and the message is `ERROR_CODE|field|message`. The API maps `ERROR_CODE` to the HTTP status.
- Write procedures take `p_actor_user_id, p_request_id, p_ip` first. They write `audit_log` and `security_event_log` themselves.
- Result-set columns use camelCase aliases (the API JSON convention).
- Timestamps are `UTC_TIMESTAMP(3)`. IST (UTC+05:30) is used only for business dates and numbers.
- No stored functions. With binary logging on, creating a function needs SUPER, so all helpers are procedures.

## Automated tests

The API's integration tests rebuild `sales_crm_test` from these same scripts before every run (`npm run test:db`), on the server and with the account set in `.env.test`.
They rewrite each script's `USE` line to `sales_crm_test`, so they never touch `unigr8ways_sales_crm`.
