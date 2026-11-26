# Part 5 physical database

PostgreSQL implementation of the seven relations in Part 4. Run the SQL directly
in Supabase's SQL Editor or with a PostgreSQL client. No embedded SQL, application
framework, or Supabase client library is needed for this database implementation.

## Files and execution order

1. `sql/01_schema.sql` creates the `library` schema, tables, constraints and indexes.
2. `sql/02_operations.sql` installs functions and triggers that enforce library rules.
3. `sql/03_demo.sql` optionally demonstrates a complete scenario and rolls it back.
4. Load Package D's full seed data after the operation triggers have been installed.
5. Run Packages B/E's reports and acceptance checks against the same version.

The demo and verification fixtures are small development cases, not the required
20 books, 20 digital media items, 20 magazines and 50 clients. Package D owns that
full population. Package A supplies the schema and operations contract below.

## Run in Supabase

1. Open the course project and its SQL Editor. Use the database owner context.
2. In a **fresh database without a `library` schema**, paste the complete contents
   of `01_schema.sql` into a new query and run it.
3. Run the complete `02_operations.sql` in a second query.
4. Inspect the tables with the query below, then run the optional demo.
5. Load the final seed and save the final DDL, table outputs and test evidence.

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'library' AND table_type = 'BASE TABLE'
ORDER BY table_name;

SELECT * FROM library.library_item ORDER BY item_id;
```

The schema file intentionally fails on an existing schema instead of deleting
data or silently accepting an incompatible structure. Each installation file is
transactional. The operations file can be rerun to replace its functions/triggers.
Do not rerun the schema file as a reset procedure against a populated database.

## Run with a PostgreSQL client

Use a private connection string in `DATABASE_URL` (never commit it). Copy the
appropriate direct/session-pooler connection from the project's Connect dialog.

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/01_schema.sql
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/02_operations.sql
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/03_demo.sql
```

Commands above run from `part-5-deliverables/`. If the network only supports IPv4,
the Supabase session-pooler connection is an alternative to the direct endpoint.

## SQL examples

Create/update members and catalog items with ordinary `INSERT` and `UPDATE`
statements using the columns in `docs/database_contract.md`. Foreign keys, checks,
and rule triggers apply to direct writes as well as function calls.

```sql
-- Use real client/item identifiers returned by your inserts.
SELECT library.checkout_item(1, 1);
SELECT library.reserve_item(2, 1);
SELECT library.return_item(1);
SELECT library.assess_late_fee(1);
SELECT library.pay_late_fee(1, 0.25);
SELECT library.generate_notifications();
```

These calls illustrate the interfaces; they require the matching existing records
and appropriate state. `03_demo.sql` creates its own records and is runnable on a
fresh installation without assuming any generated identifiers.

## Local Package A verification

Requires Python 3 and a running Docker installation. The verifier starts and
removes its **own disposable PostgreSQL container**, with no published port or
hosted database access. It installs the real SQL files and checks both direct
SQL and the function interfaces, including concurrent checkout attempts.

```bash
python3 verification/verify_package_a.py --output verification/package_a_results.json
```

Optional: `--image postgres:16-alpine` verifies the same scripts on PostgreSQL 16.
The small fixtures live only in the disposable database. This is Package A's
verification evidence; Package E owns the team's integrated acceptance runner.

## Access and deployment status

`library` is a separate schema and is not exposed through Supabase's Data API by
this installation. All seven tables have RLS enabled; no public API grants or
client access policies are created. Functions use invoker privileges, fixed
search paths, and no public execute grants. The SQL Editor/database owner can
work with the course data. Future staff/client application access requires an
explicit role/policy design; the current database does not create an end-user UI.

The connected Supabase account returned no projects during implementation.
Local PostgreSQL verification is separate from hosted deployment. A course
project must be available before these scripts can be applied and verified there.

## References

- [Part 4 logical schema](../part-4-deliverables/PART_4_RELATIONAL_SCHEMA.md)
- [Supabase database functions and SQL Editor](https://supabase.com/docs/guides/database/functions)
- [PostgreSQL constraints](https://www.postgresql.org/docs/current/ddl-constraints.html)
