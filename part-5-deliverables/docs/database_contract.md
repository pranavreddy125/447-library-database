# Database contract for Packages B, C, D and E

## Stable names

The schema is `library`. Qualify names (`library.loan`) so session search paths do
not affect queries. Columns are lower-case snake_case versions of Part 4 names;
`author_creator` represents Author/Creator. IDs are generated positive INTEGERs.

| Table | Columns |
| --- | --- |
| membership_type | membership_type_id, name, borrowing_limit, daily_late_fee_rate |
| client | client_id, first_name, last_name, phone_number, membership_type_id, account_status |
| library_item | item_id, title, item_type, availability_status, borrowing_restricted, author_creator, isbn, publication_year, genre, issue_number, publication_date |
| loan | loan_id, item_id, client_id, checkout_timestamp, due_date, return_timestamp |
| late_fee | fee_id, loan_id, amount_owed, amount_paid |
| reservation | reservation_id, client_id, item_id, reservation_date, reservation_status |
| notification | notification_id, client_id, loan_id, reservation_id, notification_type, message, creation_timestamp |

Types, lengths, nullability and domains are in `sql/01_schema.sql` and match Part 4.
`isbn` is optional, not unique, and normalized to 10/13 characters (digits, with
uppercase X permitted in the last position of a 10-character ISBN). Length/form
validation does not attempt an ISBN checksum. Magazines use issue/date fields;
books/digital media use creator/year/genre fields. Non-applicable fields are null.

## Operations

| Function (in library schema) | Result |
| --- | --- |
| checkout_item(client_id, item_id, checkout_timestamp DEFAULT now(), due_date DEFAULT NULL) | New loan ID; null due date selects checkout's Chicago calendar date + 14 days |
| return_item(loan_id, return_timestamp DEFAULT now()) | Assessed amount owed, before payments; closes loan and advances holds |
| reserve_item(client_id, item_id, reservation_date DEFAULT Chicago today) | New pending reservation ID |
| cancel_reservation(reservation_id) | Cancels an open hold and advances the queue when necessary |
| assess_late_fee(loan_id, as_of DEFAULT Chicago today) | Assessed amount owed; inserts/updates at most one fee record |
| pay_late_fee(fee_id, amount) | Remaining balance after payment |
| generate_notifications(as_of DEFAULT Chicago today) | Number of newly created notice records |

Actual named parameters have a `p_` prefix, e.g. `p_due_date => DATE '2026-12-15'`.
All functions are called with `SELECT`, inside the caller's transaction. Standard
`INSERT`, `UPDATE`, and `DELETE` statements manage memberships, clients and items;
triggers enforce related rules. Expected constraint/rule errors reject the
statement. In an explicit transaction, roll back to a savepoint or roll back the
transaction before continuing after an expected error.

## Policy defaults for this implementation

These fill gaps in the earlier requirements and can be revised before final
acceptance. They are project implementation decisions, not course-imposed rules.

- Library calendar: `America/Chicago`, explicitly applied to timestamp/date rules.
- Loan length: 14 calendar days by default; callers may supply an eligible due date.
- Due-soon window: today through three days ahead. The due date itself is not late.
- Fees: `max(0, end_date - due_date) * daily_late_fee_rate`, two-decimal NUMERIC.
  End date is the recorded Chicago return date, or the assessment date for an
  active loan. Return stops accrual. A late return with a zero rate records a zero
  charge to preserve that finalized rate outcome; an on-time return needs no fee row. Payments must
  be positive, in whole cents, and cannot exceed the balance. No refunds/credits.
- A client's membership cannot change while they have an active loan; a category's
  rate cannot change while it applies to active loans. Lowering a limit below an
  existing active count is rejected. Existing closed-loan fee amounts are stored;
  `assess_late_fee` returns those finalized amounts after later policy changes.
- Repeated active-loan assessments replace the assessed total, preserving payments.
  Use nondecreasing assessment dates. Backdating a return/assessment that would
  reduce the charge below payments is rejected by the balance constraint.
- Reservations are for loaned, unrestricted items held by a different borrower.
  Only one open hold per client/item. Queue order is reservation_date then ID.
  Return promotes the first pending hold; the item becomes reserved for that
  client. Their successful checkout fulfills it. Cancellation promotes the next.
  Holds do not expire automatically. Finish/cancelled holds cannot be reopened.
- Cancel open reservations before making their client inactive/restricted or
  making the item borrowing-restricted. Restricted clients can still return loans.
- Availability is derived from active loans/available holds. Do not set it by
  hand to a contradictory value. Direct writes must preserve this relationship.
- Loan identity, checkout and due dates are fixed after insertion; record its first
  return once. Extensions and reopening closed loans are outside this scope.
- Notice records do not send email/text. Reservation-ready notices are created
  automatically on promotion. Run `generate_notifications` for due-soon/overdue
  notices. At most one loan notice per type/day, one ready notice per reservation.
- Foreign keys retain referenced history (no cascaded deletes). Cancel/return
  active records instead of deleting them. Remove an item only if unreferenced.

## Seed loading

Install schema and operations first. Load membership types → clients → items →
loans → reservations and other dependent records. Items start `available`;
inserting active loans updates them. New reservations start `pending` while the
item is on loan; recording its return promotes the first hold and creates a notice.
Returned historical loans may be inserted with valid checkout/due/return dates;
their return trigger assesses fees. Do not insert duplicate fee/notice records
for values already created by triggers. Set account/item restrictions after
eligible historical records have been loaded; avoid open holds on restricted rows.

Use generated IDs with `INSERT ... RETURNING` and keep identifier maps in the
generator. If a seed explicitly supplies IDs, advance each identity sequence above
its maximum inserted ID before later default-ID inserts. Example for clients:

```sql
SELECT setval(pg_get_serial_sequence('library.client','client_id'),
              COALESCE((SELECT max(client_id) FROM library.client),1),
              EXISTS (SELECT 1 FROM library.client));
```

Apply this to all explicitly loaded identity columns. Arbitrary manual sequence
resetting is not part of the normal checkout/return workflow.

## Concurrency and teammate boundaries

Library writes acquire one transaction-level advisory lock before row work.
This deliberately serializes short write transactions for the course dataset,
including direct SQL. It prevents both duplicate item checkout and a member
exceeding a limit through simultaneous checkouts of different items. Reads are
not serialized. Keep transactions short and commit/rollback promptly. This is
not a design for high-throughput production circulation.

- Package B: query these tables and export results; do not duplicate circulation rules.
- Package C: assemble the final report from actual DDL/output; record these defaults.
- Package D: generate/validate the full sample data using this load order and domains.
- Package E: own the team's complete build/test runner and independent acceptance suite.
- Package A: own schema/operation fixes and final hosted deployment/integration.
