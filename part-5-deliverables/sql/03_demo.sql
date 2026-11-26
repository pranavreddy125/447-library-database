-- Sample circulation transaction
BEGIN;

CREATE TEMP TABLE demo_ids (
    borrower INTEGER,
    waiting_client INTEGER,
    item INTEGER,
    loan INTEGER,
    reservation INTEGER
) ON COMMIT DROP;

WITH new_membership AS (
    INSERT INTO library.membership_type (name, borrowing_limit, daily_late_fee_rate)
    VALUES ('Demo membership', 2, 0.25)
    RETURNING membership_type_id
),
new_clients AS (
    INSERT INTO library.client (first_name, last_name, phone_number, membership_type_id)
    SELECT 'Alex', 'Demo', '555-0101', membership_type_id FROM new_membership
    UNION ALL
    SELECT 'Sam', 'Demo', '555-0102', membership_type_id FROM new_membership
    RETURNING client_id, first_name
),
new_item AS (
    INSERT INTO library.library_item (title, item_type, author_creator, publication_year, genre)
    VALUES ('Demo book', 'book', 'Demo Author', 2025, 'Fiction')
    RETURNING item_id
)
INSERT INTO demo_ids (borrower, waiting_client, item)
SELECT borrower.client_id, waiting.client_id, new_item.item_id
FROM new_clients AS borrower, new_clients AS waiting, new_item
WHERE borrower.first_name = 'Alex' AND waiting.first_name = 'Sam';

UPDATE demo_ids
SET loan = library.checkout_item(borrower, item, '2025-01-01 12:00-06', DATE '2025-01-15');

UPDATE demo_ids
SET reservation = library.reserve_item(waiting_client, item, DATE '2025-01-02');

SELECT library.return_item(loan, '2025-01-18 12:00-06')
FROM demo_ids;

-- Expected late fee: 0.75
SELECT i.title, i.availability_status, r.reservation_status,
       f.amount_owed, f.amount_paid
FROM demo_ids d JOIN library.library_item i ON i.item_id=d.item
JOIN library.reservation r ON r.reservation_id=d.reservation
JOIN library.late_fee f ON f.loan_id=d.loan;

-- notice for the waiting client
SELECT n.client_id, n.notification_type, n.message
FROM demo_ids d JOIN library.notification n ON n.reservation_id=d.reservation;

-- The waiting client picks up the item.
SELECT library.checkout_item(waiting_client,item,'2025-01-18 13:00-06') AS next_loan
FROM demo_ids;
SELECT i.availability_status, r.reservation_status
FROM demo_ids d JOIN library.library_item i ON i.item_id=d.item
JOIN library.reservation r ON r.reservation_id=d.reservation;
ROLLBACK;
